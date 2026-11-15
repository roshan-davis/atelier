import Foundation
import XCTest
@testable import AtelierCore

/// Select Sky (AT-068): the farthest part of the photo that reaches its top, from the depth model.
final class SelectSkyTests: XCTestCase {
    func testSkyIsTheFarPartReachingTheTop() {
        // 4 × 4, rows from the top: far sky on top, a near tree reaching up on the left, a far
        // wall at the bottom right that doesn't connect to the top.
        let values: [Float] = [
            0.3, 1.0, 1.0, 1.0,
            0.3, 1.0, 0.95, 0.2,
            0.3, 0.2, 0.2, 0.2,
            0.3, 0.2, 1.0, 1.0,
        ]
        let sky = DepthMap.Field(width: 4, height: 4, values: values).sky
        XCTAssertEqual(sky[1], 1)
        XCTAssertEqual(sky[3], 1)
        XCTAssertEqual(sky[0], 0, "the near tree isn't sky")
        XCTAssertGreaterThan(sky[6], 0.5, "far enough, joined to the top")
        XCTAssertLessThan(sky[6], 1, "fades in below the farthest")
        XCTAssertEqual(sky[14], 0, "a far wall cut off from the top isn't sky")
        XCTAssertEqual(sky[15], 0)
    }

    func testNoFarTopMeansNoSky() {
        let indoors = DepthMap.Field(width: 3, height: 2, values: [0.5, 0.6, 0.5, 0.2, 1.0, 0.2])
        XCTAssertTrue(indoors.sky.allSatisfy { $0 == 0 })
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
