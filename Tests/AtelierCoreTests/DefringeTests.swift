import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

final class DefringeTests: XCTestCase {
    func testKernelsBuild() {
        XCTAssertTrue(Defringe.kernelsAvailable)
        XCTAssertTrue(LateralCA.kernelAvailable)
    }

    // MARK: Settings

    func testDefaultsAndStorageMatchLightroom() throws {
        let settings = DevelopSettings()
        XCTAssertEqual(settings[.lensDefringePurpleAmount], 0)
        XCTAssertEqual(settings[.lensDefringePurpleHueLow], 30)
        XCTAssertEqual(settings[.lensDefringePurpleHueHigh], 70)
        XCTAssertEqual(settings[.lensDefringeGreenHueLow], 40)
        XCTAssertEqual(settings[.lensDefringeGreenHueHigh], 60)
        XCTAssertEqual(DevelopSettings.Parameter.lensDefringeGreenAmount.range, 0...20)
        XCTAssertTrue(settings.isNeutral)
        XCTAssertEqual(DevelopSettings.Panel.lensCorrections.parameters,
                       [.lensDistortion,
                        .lensDefringePurpleAmount, .lensDefringePurpleHueLow, .lensDefringePurpleHueHigh,
                        .lensDefringeGreenAmount, .lensDefringeGreenHueLow, .lensDefringeGreenHueHigh,
                        .lensVignette, .lensVignetteMidpoint])

        var edited = settings
        edited.removeChromaticAberration = true
        edited[.lensDefringePurpleAmount] = 6
        edited.setHueRange(.purple, low: 20, high: 50)
        XCTAssertFalse(edited.isNeutral)
        let decoded = try DevelopSettings.decoded(from: edited.encoded())
        XCTAssertEqual(decoded, edited)
        XCTAssertTrue(try DevelopSettings.decoded(from: #"{"schemaVersion":3}"#).removeChromaticAberration == false)
    }

    func testColorCorrectionsDontChangeTheShapeKey() {
        var settings = DevelopSettings()
        settings.removeChromaticAberration = true
        settings[.lensDefringeGreenAmount] = 8
        XCTAssertEqual(settings.lensGeometryKey, DevelopSettings().lensGeometryKey)
        XCTAssertFalse(settings.hasLensGeometry)
    }

    func testHueRangeKeepsTenApart() {
        var settings = DevelopSettings()
        settings.setHueRange(.green, low: 55, high: 58, moving: .lensDefringeGreenHueHigh)
        XCTAssertEqual(settings[.lensDefringeGreenHueLow], 48)
        XCTAssertEqual(settings[.lensDefringeGreenHueHigh], 58)
        settings.setHueRange(.green, low: 97, high: 99, moving: .lensDefringeGreenHueLow)
        XCTAssertEqual(settings[.lensDefringeGreenHueLow], 90)
        XCTAssertEqual(settings[.lensDefringeGreenHueHigh], 100)
    }

    func testHueSlidersCoverPurpleAndGreenButNotSkyOrFoliage() {
        XCTAssertEqual(DevelopSettings.FringeColor.purple.degrees(30), 261, accuracy: 1e-9)
        XCTAssertEqual(DevelopSettings.FringeColor.green.degrees(50), 120, accuracy: 1e-9)
        XCTAssertEqual(DevelopSettings.FringeColor.purple.sliderValue(degrees: 285) ?? -1, 50, accuracy: 1e-9)
        XCTAssertNil(DevelopSettings.FringeColor.green.sliderValue(degrees: 285))
        func hue(_ r: Double, _ g: Double, _ b: Double) -> Double { Defringe.hueSaturation(SIMD3(r, g, b)).hue }
        let purple = DevelopSettings.FringeColor.purple, green = DevelopSettings.FringeColor.green
        let defaultPurple = purple.degrees(30)...purple.degrees(70), defaultGreen = green.degrees(40)...green.degrees(60)
        XCTAssertTrue(defaultPurple.contains(hue(0.6, 0.3, 0.9)), "violet fringe")
        XCTAssertTrue(defaultGreen.contains(hue(0.3, 0.7, 0.3)), "green fringe")
        XCTAssertFalse(defaultPurple.contains(hue(0.4, 0.6, 0.9)), "blue sky")
        XCTAssertFalse(defaultGreen.contains(hue(0.5, 0.6, 0.2)), "yellow-green foliage")
    }

    // MARK: Fringe Color Selector

    func testPickSetsTheRangeAroundAPurpleFringe() throws {
        // A violet in display values, back to linear Rec. 2020 for the sample.
        let violet = workingColor(srgb: SIMD3(0.55, 0.3, 0.85))
        let gray = workingColor(srgb: SIMD3(0.5, 0.5, 0.5))
        let pick = try XCTUnwrap(Defringe.pick([gray, violet, gray], settings: DevelopSettings()))
        XCTAssertEqual(pick.color, .purple)
        XCTAssertEqual(pick.amount, 5)
        XCTAssertEqual(pick.hueHigh - pick.hueLow, 20)
        let hue = Defringe.hueSaturation(Defringe.display(violet)).hue
        let value = try XCTUnwrap(DevelopSettings.FringeColor.purple.sliderValue(degrees: hue))
        XCTAssertEqual((pick.hueLow + pick.hueHigh) / 2, value, accuracy: 1)

        var settings = DevelopSettings()
        settings[.lensDefringeGreenAmount] = 12
        let green = try XCTUnwrap(Defringe.pick([workingColor(srgb: SIMD3(0.3, 0.75, 0.35))], settings: settings))
        XCTAssertEqual(green.color, .green)
        XCTAssertEqual(green.amount, 12, "a set Amount is kept")
    }

    func testPickRefusesNeutralAndOtherColors() {
        XCTAssertNil(Defringe.pick([workingColor(srgb: SIMD3(0.5, 0.5, 0.5))], settings: DevelopSettings()))
        XCTAssertNil(Defringe.pick([workingColor(srgb: SIMD3(0.9, 0.4, 0.1))], settings: DevelopSettings()), "orange")
        XCTAssertNil(Defringe.pick([], settings: DevelopSettings()))
    }

    // MARK: Rendering

    /// A dark-to-white edge with a violet fringe along it, and a violet patch away from any
    /// strong edge. Defringe turns the fringe gray and leaves the patch's middle alone.
    func testDefringeRemovesTheFringeButNotPurpleObjects() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        func srgb(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: DevelopRenderer.sRGB)!)
        }
        let dark = srgb(0.1, 0.1, 0.1).cropped(to: extent)
        let white = srgb(0.95, 0.95, 0.95).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let fringe = srgb(0.55, 0.3, 0.85).cropped(to: CGRect(x: 97, y: 0, width: 3, height: 100))
        let patch = srgb(0.4, 0.25, 0.55).cropped(to: CGRect(x: 10, y: 30, width: 50, height: 50))
        let image = fringe.composited(over: white.composited(over: patch.composited(over: dark)))

        var settings = DevelopSettings()
        settings[.lensDefringePurpleAmount] = 10
        let output = Defringe.apply(image, settings: settings, scale: 1)
        let before = try pixel(image, x: 98, y: 50), after = try pixel(output, x: 98, y: 50)
        XCTAssertGreaterThan(Defringe.hueSaturation(before).saturation, 0.4)
        XCTAssertLessThan(Defringe.hueSaturation(after).saturation, 0.05, "fringe turned neutral")
        XCTAssertEqual(luminance(after), luminance(before), accuracy: 0.01, "fringe keeps its brightness")

        let patchBefore = try pixel(image, x: 35, y: 55), patchAfter = try pixel(output, x: 35, y: 55)
        XCTAssertLessThan(difference(patchAfter, patchBefore), 0.005, "purple away from edges stays")

        let off = Defringe.apply(image, settings: DevelopSettings(), scale: 1)
        XCTAssertLessThan(difference(try pixel(off, x: 98, y: 50), before), 0.005, "Amount 0 changes nothing")
    }

    // MARK: Lateral chromatic aberration

    func testEstimateFindsTheRedAndBlueScales() {
        let width = 600, height = 400
        // A soft checkerboard; red drawn 0.21% larger than green, blue 0.13% smaller.
        func channel(_ scale: Double, gain: Float, offset: Float) -> [Float] {
            var out = [Float](repeating: 0, count: width * height)
            let cx = Double(width) / 2, cy = Double(height) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let u = cx + (Double(x) + 0.5 - cx) / (1 + scale), v = cy + (Double(y) + 0.5 - cy) / (1 + scale)
                    let s = sin(u / 40 * .pi) * sin(v / 40 * .pi)
                    out[y * width + x] = Float(0.15 + 0.7 / (1 + exp(-s * 12))) * gain + offset
                }
            }
            return out
        }
        let found = LateralCA.estimate(red: channel(0.0021, gain: 0.8, offset: 0),
                                       green: channel(0, gain: 1, offset: 0),
                                       blue: channel(-0.0013, gain: 0.6, offset: 0.1), width: width, height: height)
        XCTAssertEqual(found.red, 0.0021, accuracy: 0.0002)
        XCTAssertEqual(found.blue, -0.0013, accuracy: 0.0002)

        let flat = [Float](repeating: 0.5, count: width * height)
        XCTAssertTrue(LateralCA.estimate(red: flat, green: flat, blue: flat, width: width, height: height).isNone,
                      "no edges, no correction")
    }

    func testCorrectionLinesTheChannelsUp() throws {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 360, y: 0, width: 40, height: 300))
        let image = white.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent))
        // Red drawn 1% smaller: its edge sits 1.6 px nearer the center than green's.
        let shifted = LateralCA(red: 0.01, blue: 0).apply(to: image)
        let fixed = LateralCA(red: -0.01, blue: 0).apply(to: shifted)
        let x = 359  // just left of the edge
        XCTAssertGreaterThan(Double(try pixel(shifted, x: x, y: 150).x), 0.2, "red bleeds across the edge")
        XCTAssertLessThan(Double(try pixel(fixed, x: x, y: 150).x), 0.1, "and is pulled back")
        XCTAssertEqual(try pixel(fixed, x: x, y: 150).y, try pixel(image, x: x, y: 150).y, accuracy: 1e-3, "green untouched")
    }

    // MARK: Helpers

    /// Linear Rec. 2020 for a display (sRGB, gamma 2.2) color, the inverse of `Defringe.display`.
    private func workingColor(srgb: SIMD3<Double>) -> SIMD3<Double> {
        let l = SIMD3(pow(srgb.x, 2.2), pow(srgb.y, 2.2), pow(srgb.z, 2.2))
        return SIMD3(0.6274 * l.x + 0.3293 * l.y + 0.0433 * l.z,
                     0.0691 * l.x + 0.9195 * l.y + 0.0114 * l.z,
                     0.0164 * l.x + 0.0880 * l.y + 0.8956 * l.z)
    }

    /// The display-like color of one pixel (x from the left, y from the bottom).
    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> SIMD3<Double> {
        var data = [Float](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            DevelopRenderer.shared.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                                                  bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                                  format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        }
        return Defringe.display(SIMD3(Double(data[0]), Double(data[1]), Double(data[2])))
    }

    /// Linear luminance of a display-like color.
    private func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * pow(c.x, 2.2) + 0.7152 * pow(c.y, 2.2) + 0.0722 * pow(c.z, 2.2)
    }

    private func difference(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
    }
}
