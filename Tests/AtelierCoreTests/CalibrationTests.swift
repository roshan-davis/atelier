import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// The Calibration panel (AT-069): the primaries' matrix, Shadows Tint and where they sit in the
/// pipeline.
final class CalibrationTests: XCTestCase {
    private typealias Parameter = DevelopSettings.Parameter

    func testSlidersBelongToTheCalibrationPanelAndDefaultToZero() {
        let calibration = DevelopSettings.Panel.calibration.parameters
        XCTAssertEqual(Set(calibration), [.calibrationShadowsTint, .calibrationRedHue, .calibrationRedSat,
                                          .calibrationGreenHue, .calibrationGreenSat, .calibrationBlueHue,
                                          .calibrationBlueSat])
        for parameter in calibration {
            XCTAssertEqual(DevelopSettings()[parameter], 0)
            XCTAssertEqual(parameter.range, -100...100)
        }
        XCTAssertEqual(DevelopSettings.Panel.allCases.last, .calibration, "Calibration is the last panel, as in Lightroom")
        XCTAssertTrue(Calibration.isNeutral(.neutral))
        XCTAssertNil(Calibration.matrix(.neutral))
    }

    func testOldSettingsDecodeNeutralAndNewOnesRoundTrip() throws {
        let old = try DevelopSettings.decoded(from: #"{"exposure":0.5}"#)
        XCTAssertTrue(Calibration.isNeutral(old))
        var settings = DevelopSettings()
        settings[.calibrationRedHue] = 25
        settings[.calibrationBlueSat] = 40
        settings[.calibrationShadowsTint] = -10
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
    }

    func testWhiteAndGraysStayPut() {
        var settings = DevelopSettings()
        settings[.calibrationRedHue] = 60
        settings[.calibrationGreenSat] = -50
        settings[.calibrationBlueHue] = -80
        settings[.calibrationBlueSat] = 100
        for level in [0.05, 0.18, 1.0] {
            let out = Calibration.apply(SIMD3(level, level, level), settings: settings)
            XCTAssertEqual(out.x, level, accuracy: 1e-6)
            XCTAssertEqual(out.y, level, accuracy: 1e-6)
            XCTAssertEqual(out.z, level, accuracy: 1e-6)
        }
    }

    func testRedHueTurnsRedTowardOrangeAndBlueHueTowardPurple() {
        var settings = DevelopSettings()
        settings[.calibrationRedHue] = 100
        let red = Calibration.apply(SIMD3(1, 0, 0), settings: settings)
        XCTAssertGreaterThan(red.y, 0.2, "red picks up green, so it moves toward orange")
        XCTAssertGreaterThan(red.x, red.y)

        settings = DevelopSettings()
        settings[.calibrationBlueHue] = 100
        let blue = Calibration.apply(SIMD3(0, 0, 1), settings: settings)
        XCTAssertGreaterThan(blue.x, blue.y, "blue picks up red, so it moves toward purple")

        settings = DevelopSettings()
        settings[.calibrationRedHue] = -100
        let pinker = Calibration.apply(SIMD3(1, 0, 0), settings: settings)
        XCTAssertGreaterThan(pinker.z, pinker.y, "left moves red toward magenta")
    }

    func testSaturationPushesAPrimaryAwayFromGray() {
        let teal = SIMD3<Double>(0.1, 0.3, 0.5)
        func spread(_ c: SIMD3<Double>) -> Double { c.max() - c.min() }
        var more = DevelopSettings()
        more[.calibrationBlueSat] = 80
        var less = DevelopSettings()
        less[.calibrationBlueSat] = -80
        XCTAssertGreaterThan(spread(Calibration.apply(teal, settings: more)), spread(teal))
        XCTAssertLessThan(spread(Calibration.apply(teal, settings: less)), spread(teal))
    }

    func testShadowsTintWorksInShadowsKeepsBrightnessAndLeavesHighlights() {
        var magenta = DevelopSettings()
        magenta[.calibrationShadowsTint] = 100
        let shadow = SIMD3<Double>(0.02, 0.02, 0.02)
        let tinted = Calibration.apply(shadow, settings: magenta)
        XCTAssertLessThan(tinted.y, tinted.x, "right adds magenta: less green than red")
        let luma = { (c: SIMD3<Double>) -> Double in 0.2627 * c.x + 0.6780 * c.y + 0.0593 * c.z }
        XCTAssertEqual(luma(tinted), luma(shadow), accuracy: 1e-9)

        var green = DevelopSettings()
        green[.calibrationShadowsTint] = -100
        let greener = Calibration.apply(shadow, settings: green)
        XCTAssertGreaterThan(greener.y, greener.x)

        let highlight = SIMD3<Double>(0.6, 0.6, 0.6)
        let untouched = Calibration.apply(highlight, settings: magenta)
        XCTAssertEqual(untouched.x, untouched.y, accuracy: 1e-9)
        XCTAssertEqual(Calibration.shadowWeight(0), 1, accuracy: 1e-9)
        XCTAssertEqual(Calibration.shadowWeight(0.4), 0, accuracy: 1e-9)
    }

    func testKernelMatchesTheMath() throws {
        try XCTSkipUnless(Calibration.kernelAvailable, "The Calibration Metal kernel didn't build here")
        var settings = DevelopSettings()
        settings[.calibrationRedHue] = 50
        settings[.calibrationBlueSat] = 60
        settings[.calibrationShadowsTint] = 40
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space, .outputPremultiplied: false])
        for color in [SIMD3<Double>(0.5, 0.1, 0.05), SIMD3(0.03, 0.02, 0.04), SIMD3(0.1, 0.2, 0.7)] {
            let ciColor = try XCTUnwrap(CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                                alpha: 1, colorSpace: space))
            let image = CIImage(color: ciColor).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            let output = Calibration.apply(image, settings: settings)
            var pixel = [Float](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: space)
            let expected = Calibration.apply(color, settings: settings)
            XCTAssertEqual(Double(pixel[0]), expected.x, accuracy: 0.002)
            XCTAssertEqual(Double(pixel[1]), expected.y, accuracy: 0.002)
            XCTAssertEqual(Double(pixel[2]), expected.z, accuracy: 0.002)
        }
    }

    func testNeutralLeavesTheImageObjectAlone() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertTrue(Calibration.apply(image, settings: .neutral) === image)
    }

    func testCalibrationPresetPartCarriesOnlyCalibration() {
        var look = DevelopSettings()
        look[.calibrationGreenHue] = 30
        look.exposure = 1
        let preset = DevelopPreset(name: "Primaries", parts: [.calibration], settings: look)
        let applied = preset.applied(to: .neutral)
        XCTAssertEqual(applied[.calibrationGreenHue], 30)
        XCTAssertEqual(applied.exposure, 0)
        XCTAssertEqual(DevelopPreset.Part.calibration.title, "Calibration")
    }
}
