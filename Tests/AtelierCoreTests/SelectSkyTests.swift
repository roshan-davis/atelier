import Foundation
import XCTest
@testable import AtelierCore

/// Select Sky (AT-068): the part of the photo at infinity open to its top with no edges, plus
/// clouds it surrounds and sky seen through gaps, from the depth model and the photo's colors.
/// Without `disparity`, these fields give depth as `values` (1 at infinity).
final class SelectSkyTests: XCTestCase {
    /// 8 × 12, rows from the top: a pink sunset sky (depth 1), a near dark tower in columns 3
    /// and 4 with one sky-colored gap at row 3 (0.99, the model blurs it a little toward the
    /// tower), a dark skyline in rows 6 and 7 almost at infinity (0.95), near ground.
    /// Rosh's Eiffel Tower photo had both problems: the skyline was taken, the gaps weren't.
    private func towerScene() -> DepthMap.Field {
        var values: [Float] = [], colors: [UInt8] = []
        for row in 0..<12 {
            for column in 0..<8 {
                let pink: [UInt8] = [UInt8(230 - row * 4), UInt8(150 + row * 6), UInt8(170 + row * 3), 255]
                if row <= 5 {
                    if column == 3 || column == 4 {
                        if row == 3 {
                            values.append(0.99)
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

    func testWithoutColorsWhatIsAtInfinityAndOpenToTheTopIsKept() {
        let field = DepthMap.Field(width: 2, height: 2, values: [1, 0.95, 1, 0.2])
        XCTAssertEqual(field.sky, [1, 0, 1, 0])
    }

    /// The model's own output decides what is at infinity: the sky is 0 there. A photo whose
    /// farthest part is a stadium crowd (disparity well above 0) has no sky, however smooth.
    func testOnlyZeroDisparityIsSky() {
        let gray: [UInt8] = [120, 110, 115, 255]
        let colors = Array([[UInt8]](repeating: gray, count: 8).joined())
        let stadium = DepthMap.Field(width: 2, height: 4, values: [Float](repeating: 0.5, count: 8), colors: colors,
                                     disparity: [1, 1, 1, 1, 6, 6, 10, 10])
        XCTAssertTrue(stadium.sky.allSatisfy { $0 == 0 }, "the crowd is the farthest thing but not at infinity")
        let outdoors = DepthMap.Field(width: 2, height: 4, values: [Float](repeating: 0.5, count: 8), colors: colors,
                                      disparity: [0, 0, 0, 0, 6, 6, 10, 10])
        XCTAssertEqual(Array(outdoors.sky[0..<4]), [1, 1, 1, 1])
        XCTAssertEqual(outdoors.nearness()[0], 0)
        XCTAssertEqual(outdoors.nearness()[7], 1, accuracy: 0.001)
    }

    /// A scene from rows of (depth, RGB) cells.
    private func scene(_ rows: [[(Float, [UInt8])]]) -> DepthMap.Field {
        var values: [Float] = [], colors: [UInt8] = []
        for row in rows {
            for (depth, rgb) in row {
                values.append(depth)
                colors += rgb + [255]
            }
        }
        return DepthMap.Field(width: rows[0].count, height: rows.count, values: values, colors: colors)
    }

    /// 32 × 20: a sunset that turns from pink to blue across its right half, a crisp white cloud, a near
    /// tower with sky gaps, then a dark skyline as far as the sky itself, far trees, near ground.
    /// Rosh's second Eiffel Tower test missed the blue edge and took a band of the far city.
    func testSunsetFollowsTheGradientAndStopsAtTheSkyline() {
        var rows: [[(Float, [UInt8])]] = []
        for row in 0..<20 {
            rows.append((0..<32).map { column -> (Float, [UInt8]) in
                let t = Double(max(0, column - 16)) / 15
                let pink: [Double] = [230 - row * 3, 150 + row * 5, 170 + row * 2].map { Double($0) }
                let blue: [Double] = [110, 150, 205]
                let sky: [UInt8] = (0..<3).map { UInt8((pink[$0] * (1 - t) + blue[$0] * t).rounded()) }
                if row <= 11 {
                    if column == 6 || column == 7 {
                        return row == 5 || row == 8 ? (0.99, sky) : (0.6, [40, 35, 30])
                    }
                    if (3...4).contains(row), (2...4).contains(column) { return (1, [235, 225, 230]) }
                    return (1, sky)
                }
                if row <= 13 { return (column % 5 == 0 ? 1 : 0.995, [70, 60, 65]) }
                if row == 14 { return (0.95, [60, 70, 50]) }
                return (0.3, [120, 115, 110])
            })
        }
        let sky = scene(rows).sky
        func at(_ row: Int, _ column: Int) -> Float { sky[row * 32 + column] }
        XCTAssertEqual(at(8, 31), 1, accuracy: 0.01, "the blue at the right edge is sky")
        XCTAssertEqual(at(11, 0), 1, accuracy: 0.01, "so is the low sunset sky")
        XCTAssertEqual(at(3, 3), 1, accuracy: 0.01, "and a cloud the sky surrounds")
        XCTAssertGreaterThan(at(5, 6), 0.8, "sky through the tower")
        XCTAssertEqual(at(2, 6), 0, "not the tower")
        for column in 0..<32 {
            XCTAssertEqual(at(12, column), 0, "the skyline, though it's as far as the sky")
            XCTAssertEqual(at(14, column), 0, "the far trees")
            XCTAssertEqual(at(17, column), 0, "the ground")
        }
    }

    /// A dusk sky with sensor noise of ±12 levels in every channel over a dark skyline as far as
    /// the sky. Rosh's Eiffel Tower photo, Nov 15, 2026: noise made neighbors differ by more than a
    /// visible step, so the open sky stopped after its first row.
    func testNoisySkyIsStillFollowed() {
        let rows: [[(Float, [UInt8])]] = (0..<20).map { row in
            (0..<24).map { column -> (Float, [UInt8]) in
                let i = row * 24 + column
                func noise(_ k: Int) -> Int { (((i * 7 + k * 13) * 2_654_435_761) >> 9) % 25 - 12 }
                if row <= 11 { return (1, [UInt8(60 + noise(0)), UInt8(70 + noise(1)), UInt8(110 + noise(2))]) }
                if row <= 13 { return (0.99, [20, 18, 22]) }
                return (0.3, [50, 50, 55])
            }
        }
        let sky = scene(rows).sky
        XCTAssertTrue(sky[0..<(12 * 24)].allSatisfy { $0 > 0.99 }, "the whole noisy sky")
        XCTAssertTrue(sky[(12 * 24)...].allSatisfy { $0 == 0 }, "not the skyline or the ground")
    }

    /// A dark blue night sky over a city with lit windows: no rule depends on the sky being bright.
    func testNightSkyStopsAtTheDarkCity() {
        let rows: [[(Float, [UInt8])]] = (0..<14).map { row in
            (0..<16).map { column -> (Float, [UInt8]) in
                if row <= 7 { return (1, [15, 18, 40]) }
                if row <= 9 { return (0.99, column % 3 == 0 ? [230, 190, 90] : [25, 20, 25]) }
                return (0.3, [40, 40, 45])
            }
        }
        let sky = scene(rows).sky
        XCTAssertTrue(sky[0..<(8 * 16)].allSatisfy { $0 > 0.99 })
        XCTAssertTrue(sky[(8 * 16)...].allSatisfy { $0 == 0 }, "neither the dark buildings nor the lights")
    }

    /// A blue day sky and a white building rising into it, which the model puts at infinity too
    /// (the worst case): bright, but not the sky's color.
    func testDaySkyLeavesAFarWhiteBuilding() {
        let rows: [[(Float, [UInt8])]] = (0..<14).map { row in
            (0..<16).map { column -> (Float, [UInt8]) in
                if row <= 8, (3...8).contains(row), (5...9).contains(column) { return (1, [240, 240, 235]) }
                if row <= 8 { return (1, [UInt8(90 + row * 8), UInt8(140 + row * 6), 220]) }
                if row == 9 { return (0.97, [60, 90, 50]) }
                return (0.4, [150, 140, 120])
            }
        }
        let sky = scene(rows).sky
        func at(_ row: Int, _ column: Int) -> Float { sky[row * 16 + column] }
        XCTAssertEqual(at(5, 2), 1, accuracy: 0.01)
        XCTAssertEqual(at(3, 7), 0, "the building's top")
        XCTAssertEqual(at(8, 5), 0)
        XCTAssertEqual(at(9, 0), 0, "the far trees")
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
