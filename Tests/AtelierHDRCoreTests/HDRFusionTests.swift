import XCTest
@testable import AtelierHDRCore

/// Fusion (Method menu, Nov 12, 2026): three exposures of the photo blended region by region,
/// and the Source panel's Exposures strip that shows them.
final class HDRFusionTests: XCTestCase {
    /// Left half deep shadow (about 4 EV under middle gray), right half a sky 2.6 EV over white,
    /// both textured.
    private func scene(width: Int = 120, height: Int = 80) throws -> HDRImage {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let texture: Float = 1 + 0.3 * sinf(Float(x) * 0.9) * cosf(Float(y) * 0.7)
                let l: Float = (x < width / 2 ? 0.01 : 6) * texture
                let i = (y * width + x) * 3
                rgb[i] = l; rgb[i + 1] = l; rgb[i + 2] = l
            }
        }
        return try HDRImage(width: width, height: height, rgb: rgb)
    }

    private func mean(_ image: HDRImage, columns: Range<Int>) -> Float {
        var sum: Float = 0, count: Float = 0
        for y in 0..<image.height {
            for x in columns { sum += image.rgb[(y * image.width + x) * 3 + 1]; count += 1 }
        }
        return sum / count
    }

    private func spread(_ image: HDRImage, columns: Range<Int>) -> Float {
        let average = mean(image, columns: columns)
        var sum: Float = 0, count: Float = 0
        for y in 0..<image.height {
            for x in columns {
                let d = image.rgb[(y * image.width + x) * 3 + 1] - average
                sum += d * d; count += 1
            }
        }
        return sqrtf(sum / count)
    }

    func testWiderSpacingLiftsShadowsAndHoldsBackTheSky() throws {
        let image = try scene()
        var results: [HDRImage] = []
        for spacing: Float in [1, 2, 3] {
            var settings = HDRSettings(); settings.method = .fusion; settings.fusionSpacing = spacing
            results.append(try HDRToneMapper.render(image, settings: settings))
        }
        let dark = 0..<50, bright = 70..<120
        XCTAssertLessThan(mean(results[0], columns: dark), mean(results[1], columns: dark))
        XCTAssertLessThan(mean(results[1], columns: dark), mean(results[2], columns: dark))
        XCTAssertGreaterThan(mean(results[0], columns: bright), mean(results[2], columns: bright))
        // The sky keeps its texture rather than clipping flat.
        for result in results { XCTAssertGreaterThan(spread(result, columns: bright), 0.03) }
        // Fusion opens the shadows further than Natural at the same Range.
        let natural = try HDRToneMapper.render(image, settings: HDRSettings())
        XCTAssertGreaterThan(mean(results[1], columns: dark), mean(natural, columns: dark) * 1.5)
    }

    /// Clicking a picture in the Exposures strip leaves that exposure out of the blend.
    func testLeavingAnExposureOutChangesItsEnd() throws {
        let image = try scene()
        var all = HDRSettings(); all.method = .fusion
        var noBright = all; noBright.fusionUsesBrighter = false
        var noDark = all; noDark.fusionUsesDarker = false
        let both = try HDRToneMapper.render(image, settings: all)
        let withoutBright = try HDRToneMapper.render(image, settings: noBright)
        let withoutDark = try HDRToneMapper.render(image, settings: noDark)
        let dark = 0..<50, bright = 70..<120
        // Without the brighter exposure the shadows open less; without the darker one the sky is brighter.
        XCTAssertLessThan(mean(withoutBright, columns: dark), mean(both, columns: dark))
        XCTAssertGreaterThan(mean(withoutDark, columns: bright), mean(both, columns: bright))
        // Old projects and presets use all three.
        let old = try JSONDecoder().decode(HDRSettings.self, from: Data(#"{"method":"fusion"}"#.utf8))
        XCTAssertTrue(old.fusionUsesDarker && old.fusionUsesBrighter)
    }

    func testTheBlendStaysBelowWhite() {
        for l: Float in [0, 0.001, 0.18, 1, 8, 1000] {
            for large: Float in [-12, -2.5, 0, 3, 10] {
                let value = HDRToneMapper.fusion(l: l, large: large, spacing: 2, amount: 0.65)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
        XCTAssertEqual(HDRToneMapper.plate(0.18), 0.194, accuracy: 0.001)
    }

    func testSpacingDecodesWithItsDefaultAndIsChecked() throws {
        let old = try JSONDecoder().decode(HDRSettings.self, from: Data(#"{"compression":0.5}"#.utf8))
        XCTAssertEqual(old.fusionSpacing, 2)
        XCTAssertEqual(old.method, .direct)
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self,
                                                      from: Data(#"{"fusionSpacing":0.5}"#.utf8)))
        var settings = HDRSettings(); settings.method = .fusion; settings.fusionSpacing = 2.5
        let again = try JSONDecoder().decode(HDRSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
    }

    func testExposurePlatesAreSmallAndInExposureOrder() throws {
        let plates = try HDRToneMapper.exposurePlates(try scene(width: 600, height: 400), exposure: 0,
                                                      spacing: 2, longEdge: 240)
        XCTAssertEqual(plates.count, 3)
        for plate in plates {
            XCTAssertLessThanOrEqual(max(plate.width, plate.height), 240)
            XCTAssertTrue(plate.rgb.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        XCTAssertLessThan(plates[0].rgb.reduce(0, +), plates[1].rgb.reduce(0, +))
        XCTAssertLessThan(plates[1].rgb.reduce(0, +), plates[2].rgb.reduce(0, +))
        // A photo thinner than one block still works.
        let thin = try HDRImage(width: 2000, height: 3, rgb: Array(repeating: 0.2, count: 18000))
        XCTAssertEqual(try HDRToneMapper.exposurePlates(thin, exposure: 0, spacing: 1, longEdge: 240).count, 3)
    }
}
