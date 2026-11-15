import Foundation
import XCTest
@testable import AtelierCore

/// Select Sky (AT-068): the farthest part of the photo that reaches its top, from the depth model.
final class SelectSkyTests: XCTestCase {
    /// 8 × 12, rows from the top: a pink sunset sky (depth 1), a near dark tower in columns 3
    /// and 4 with one sky-colored gap at row 3 (depth 0.85, the tower's own depth as the model
    /// gives it), a dark skyline in rows 6 and 7 almost as far as the sky (0.95), near ground.
    /// Rosh's Eiffel Tower photo had both problems: the skyline was taken, the gaps weren't.
    private func towerScene() -> DepthMap.Field {
        var values: [Float] = [], colors: [UInt8] = []
        for row in 0..<12 {
            for column in 0..<8 {
                let pink: [UInt8] = [UInt8(230 - row * 4), UInt8(150 + row * 6), UInt8(170 + row * 3), 255]
                if row <= 5 {
                    if column == 3 || column == 4 {
                        if row == 3 {
                            values.append(0.85)
                            colors += pink
                        } else {
                            values.append(0.6)
                            colors += [40, 35, 30, 255]
                        }
                    } else {
                        values.append(1)
                        colors += pink
                    }
                } else if row <= 7 {
                    values.append(0.95)
                    colors += [70, 60, 65, 255]
                } else {
                    values.append(0.3)
                    colors += [120, 115, 110, 255]
                }
            }
        }
        return DepthMap.Field(width: 8, height: 12, values: values, colors: colors)
    }

    func testSkyLeavesTheSkylineAndFindsSkyThroughTheTower() {
        let sky = towerScene().sky
        func at(_ row: Int, _ column: Int) -> Float { sky[row * 8 + column] }
        XCTAssertEqual(at(0, 0), 1, accuracy: 0.01)
        XCTAssertEqual(at(5, 7), 1, accuracy: 0.01, "the sunset's lower, yellower sky too")
        XCTAssertEqual(at(1, 3), 0, "the tower isn't sky")
        XCTAssertGreaterThan(at(3, 3), 0.8, "sky seen through the tower is")
        XCTAssertEqual(at(6, 0), 0, "the far skyline isn't sky")
        XCTAssertEqual(at(7, 5), 0)
        XCTAssertEqual(at(10, 2), 0, "nor the ground")
    }

    func testNoFarTopMeansNoSky() {
        let indoors = DepthMap.Field(width: 3, height: 2, values: [0.5, 0.6, 0.5, 0.2, 1.0, 0.2])
        XCTAssertTrue(indoors.sky.allSatisfy { $0 == 0 })
    }

    func testWithoutColorsTheCertainSkyIsKept() {
        let field = DepthMap.Field(width: 2, height: 2, values: [1, 0.95, 1, 0.2])
        XCTAssertEqual(field.sky, [1, 0, 1, 0])
    }

    func testSkyPartSavesWithDefaultsAndDecodesBare() throws {
        let part = DevelopSettings.MaskComponent(.sky(DevelopSettings.SkySelection(feather: 30, refine: 20, grow: -10)))
        XCTAssertEqual(part.kind, .sky)
        XCTAssertEqual(part.kind.title, "Select Sky")
        XCTAssertFalse(DevelopSettings.MaskComponent.Kind.sky.isDrawn)
        var settings = DevelopSettings()
        settings.masks = [DevelopSettings.Mask(name: "Mask 1", components: [part])]
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        let bare = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"sky"}]}]}"#)
        XCTAssertEqual(bare.masks.first?.components.first?.shape, .sky(DevelopSettings.SkySelection()))
        XCTAssertEqual(DevelopSettings.SkySelection().refine, 60)
    }
}
