import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import AtelierCore

/// The mask sliders added for AT-068: Hue, Moiré and Defringe.
final class MaskSlidersTests: XCTestCase {
    private typealias Mask = DevelopSettings.Mask
    private typealias Parameter = DevelopSettings.LocalParameter

    func testNewSlidersSitWhereLightroomHasThemAndOldMasksDecodeAtZero() throws {
        let all = Parameter.allCases
        XCTAssertEqual(all.firstIndex(of: .hue)! + 1, all.firstIndex(of: .saturation)!)
        XCTAssertEqual(Array(all.suffix(4)), [.sharpness, .noise, .moire, .defringe])
        XCTAssertEqual(Parameter.moire.label, "Moiré")
        XCTAssertEqual(Parameter.hue.range, -180...180)
        XCTAssertEqual(Parameter.defringe.range, 0...100)
        XCTAssertEqual(Parameter.hue.group, Parameter.saturation.group)

        let old = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","values":{"exposure":0.5}}]}"#)
        XCTAssertEqual(old.masks.first?[.hue], 0)
        XCTAssertEqual(old.masks.first?[.moire], 0)

        var settings = DevelopSettings()
        var mask = Mask(name: "Mask 1")
        mask[.hue] = -40
        mask[.moire] = 60
        mask[.defringe] = 250
        settings.masks = [mask]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?[.defringe], 100, "clamped to its range")
    }

    func testHueTurnKeepsGraysAndMovesRedTowardYellow() {
        let gray = MaskSliders.turnHue(SIMD3(0.3, 0.3, 0.3), degrees: 90)
        XCTAssertEqual(gray.x, 0.3, accuracy: 1e-5)
        XCTAssertEqual(gray.y, 0.3, accuracy: 1e-5)
        XCTAssertEqual(gray.z, 0.3, accuracy: 1e-5)

        let red = SIMD3<Double>(0.35, 0.03, 0.02)
        let same = MaskSliders.turnHue(red, degrees: 0)
        XCTAssertEqual(same.x, red.x, accuracy: 1e-6)
        XCTAssertEqual(same.y, red.y, accuracy: 1e-6)
        let warmer = MaskSliders.turnHue(red, degrees: 60)
        XCTAssertGreaterThan(warmer.y, red.y, "right moves red toward yellow")
        let pinker = MaskSliders.turnHue(red, degrees: -60)
        XCTAssertGreaterThan(pinker.z, red.z, "left moves red toward magenta")
        // Oklab lightness is kept.
        XCTAssertEqual(ColorRangeSpace.oklab(fromWorking: warmer).x, ColorRangeSpace.oklab(fromWorking: red).x, accuracy: 1e-6)
    }

    func testMaskHueRendersAsTheMath() throws {
        try XCTSkipUnless(MaskSliders.hueKernelAvailable, "The mask Hue kernel didn't build here")
        let red = SIMD3<Double>(0.35, 0.03, 0.02)
        var mask = Mask(name: "Mask 1")
        let base = try read(DevelopRenderer.applyLocal(mask, to: try patch(red), scale: 1))
        mask[.hue] = 60
        let pixel = try read(DevelopRenderer.applyLocal(mask, to: try patch(red), scale: 1))
        // Hue comes after the mask's other sliders, so it turns what they leave.
        let expected = MaskSliders.turnHue(base, degrees: 60)
        XCTAssertEqual(pixel.x, expected.x, accuracy: 0.003)
        XCTAssertEqual(pixel.y, expected.y, accuracy: 0.003)
        XCTAssertEqual(pixel.z, expected.z, accuracy: 0.003)
    }

    func testMoireEvensOutColoredStripesButKeepsTheirBrightness() throws {
        // Red and green stripes 4 pixels wide, the same brightness: color moiré.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = try XCTUnwrap(CIColor(red: 0.4, green: 0.12, blue: 0.1, alpha: 1, colorSpace: space))
        stripes.color1 = try XCTUnwrap(CIColor(red: 0.08, green: 0.25, blue: 0.1, alpha: 1, colorSpace: space))
        stripes.width = 4
        let image = try XCTUnwrap(stripes.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let cleaned = MaskSliders.moire(image, amount: 100, scale: 1)
        func spread(_ image: CIImage) throws -> Double {
            let a = try read(image, x: 30), b = try read(image, x: 34)
            return abs((a.x - a.y) - (b.x - b.y))
        }
        XCTAssertLessThan(try spread(cleaned), try spread(image) * 0.5)
        XCTAssertTrue(MaskSliders.moire(image, amount: 0, scale: 1) === image)
        XCTAssertTrue(MaskSliders.defringe(image, amount: 0, scale: 1) === image)
    }

    // MARK: Helpers

    private func patch(_ color: SIMD3<Double>) throws -> CIImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let ciColor = try XCTUnwrap(CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                            alpha: 1, colorSpace: space))
        return CIImage(color: ciColor).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    private func read(_ image: CIImage, x: Int = 8) throws -> SIMD3<Double> {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space, .outputPremultiplied: false])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: 8, width: 1, height: 1),
                       format: .RGBAf, colorSpace: space)
        return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }
}
