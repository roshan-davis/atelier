import CoreGraphics
import XCTest
@testable import AtelierCore

final class GradeTests: XCTestCase {
    private func chroma(_ c: RGB) -> Double {
        let lab = Oklab.fromEncoded(c)
        return (lab.y * lab.y + lab.z * lab.z).squareRoot()
    }

    /// Every hue at the same Saturation moves mid gray by the same perceptual amount.
    func testHuesAreEquallyStrong() {
        for hue in stride(from: 0.0, to: 360, by: 30) {
            var settings = DevelopSettings()
            settings[.gradeGlobalHue] = hue
            settings[.gradeGlobalSat] = 100
            let tinted = ColorGrade(settings).apply((0.5, 0.5, 0.5))
            XCTAssertEqual(chroma(tinted), ColorGrade.chroma, accuracy: 0.01, "hue \(hue): \(tinted)")
            let lab = Oklab.fromEncoded(tinted)
            XCTAssertEqual(ColorGrade.hue(towards: SIMD2(lab.y, lab.z)), hue, accuracy: 2, "hue \(hue) tints toward itself")
        }
    }

    func testHueDirectionsRoundTrip() {
        for hue in [1.0, 45, 120, 200, 233, 240, 300, 358] {
            XCTAssertEqual(ColorGrade.hue(towards: ColorGrade.direction(hue: hue)), hue, accuracy: 1)
        }
    }

    /// Luminance rolls off toward white and black instead of clipping, and pure black takes no
    /// tint until Luminance lifts it.
    func testLuminanceNeverClips() {
        var settings = DevelopSettings()
        settings[.gradeHighlightsLum] = 100
        let white = ColorGrade(settings).apply((1, 1, 1))
        XCTAssertEqual(white.0, 1, accuracy: 1e-3)
        settings[.gradeHighlightsLum] = -100
        let lowered = ColorGrade(settings).apply((1, 1, 1))
        XCTAssertLessThan(lowered.0, 0.95, "darkening highlights lowers white")

        var shadows = DevelopSettings()
        shadows[.gradeShadowsHue] = 30
        shadows[.gradeShadowsSat] = 100
        XCTAssertLessThan(chroma(ColorGrade(shadows).apply((0, 0, 0))), 0.01, "black stays black")
        shadows[.gradeShadowsLum] = 100
        let lifted = ColorGrade(shadows).apply((0, 0, 0))
        XCTAssertGreaterThan(lifted.0, 0.1, "lightening shadows lifts black")
        XCTAssertGreaterThan(lifted.0, lifted.2, "and tints it")
    }

    /// A vivid color pushed by a strong tint stays inside sRGB and keeps a sensible result.
    func testTintsStayInGamut() {
        var settings = DevelopSettings()
        settings[.gradeGlobalHue] = 180
        settings[.gradeGlobalSat] = 100
        let out = ColorGrade(settings).apply((0.9, 0.05, 0.05))
        for channel in [out.0, out.1, out.2] {
            XCTAssertGreaterThanOrEqual(channel, 0)
            XCTAssertLessThanOrEqual(channel, 1)
        }
    }

    func testSwitchTurnsGradingOff() {
        var settings = DevelopSettings()
        settings[.gradeShadowsSat] = 50
        XCTAssertTrue(ColorGrade(settings).isActive)
        settings[.gradeDisabled] = 1
        XCTAssertFalse(ColorGrade(settings).isActive)
        XCTAssertEqual(DevelopSettings.Parameter.gradeDisabled.panel, .colorGrading)
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
    }

    /// The color picker sets the midtones wheel so a warm midtone turns gray.
    func testNeutralizingCancelsACast() throws {
        let settings = DevelopSettings()
        let warm = SIMD3(0.56, 0.5, 0.42)
        let pick = try XCTUnwrap(ColorGrade.neutralizing(warm, settings: settings, region: nil))
        XCTAssertEqual(pick.region, .midtones)
        var graded = settings
        graded[pick.region.hue] = pick.hue
        graded[pick.region.saturation] = pick.saturation
        let before = chroma((warm.x, warm.y, warm.z))
        let after = chroma(ColorGrade(graded).apply((warm.x, warm.y, warm.z)))
        XCTAssertLessThan(after, before * 0.3, "cast \(before) → \(after)")
        XCTAssertNil(ColorGrade.neutralizing(SIMD3(0.95, 0.9, 0.85), settings: settings, region: .shadows),
                     "a bright spot is not in the shadows")
    }

    func testRegionMapColorsTheRanges() {
        let grade = ColorGrade(DevelopSettings())
        let dark = grade.regionMap((0.05, 0.05, 0.05)), bright = grade.regionMap((0.95, 0.95, 0.95))
        XCTAssertGreaterThan(dark.2, dark.0, "shadows show blue")
        XCTAssertGreaterThan(bright.0, bright.2, "highlights show yellow")
    }

    func testScopePlacesColorsByHue() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let scope = try XCTUnwrap(ColorScope(image: XCTUnwrap(context.makeImage())))
        let sample = try XCTUnwrap(scope.samples.first)
        XCTAssertEqual(scope.samples.count, 256)
        XCTAssertEqual(sample.hue, 225, accuracy: 30, "blue sits near the wheel's blue")
        XCTAssertGreaterThan(sample.radius, 0.3)
    }
}
