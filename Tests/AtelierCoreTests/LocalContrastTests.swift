import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

final class LocalContrastTests: XCTestCase {
    func testKernelsBuild() {
        XCTAssertTrue(LocalContrast.kernelsAvailable)
    }

    /// Faint stripes (texture) beside a strong edge: Clarity and Texture change the stripes'
    /// contrast but leave the strong edge without halos.
    func testChangesDetailWithoutHalos() throws {
        let neutral = try measure(.neutral)
        for parameter in [DevelopSettings.Parameter.clarity, .texture] {
            var more = DevelopSettings()
            more[parameter] = 100
            var less = DevelopSettings()
            less[parameter] = -100
            let boosted = try measure(more), smoothed = try measure(less)
            XCTAssertGreaterThan(boosted.stripes, neutral.stripes * 1.3, "\(parameter) +100 adds contrast")
            XCTAssertLessThan(smoothed.stripes, neutral.stripes * 0.7, "\(parameter) -100 smooths")
            XCTAssertEqual(boosted.nearEdge, neutral.nearEdge, accuracy: 0.03, "\(parameter): no halo by the edge")
            XCTAssertEqual(smoothed.nearEdge, neutral.nearEdge, accuracy: 0.03, "\(parameter): the edge stays sharp")
        }
    }

    func testHighlightsAndShadowsTargetTheirTones() throws {
        func render(_ gray: Double, highlights: Double = 0, shadows: Double = 0) throws -> Double {
            var settings = DevelopSettings()
            settings.highlights = highlights
            settings.shadows = shadows
            let input = CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            let output = DevelopRenderer.applyAdjustments(settings, to: input, scale: 0.1)
            let image = try XCTUnwrap(DevelopRenderer.shared.cgImage(output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Double(pixel[1]) / 255
        }
        // The tone-region bumps target perceptual shadows/highlights, not midtones.
        let dark = 0.15, bright = 0.85
        XCTAssertGreaterThan(try render(dark, shadows: 100), try render(dark) + 0.1, "shadows lift dark tones")
        XCTAssertEqual(try render(bright, shadows: 100), try render(bright), accuracy: 0.03, "and barely touch bright ones")
        XCTAssertLessThan(try render(bright, highlights: -100), try render(bright) - 0.08, "highlights pull bright tones down")
        XCTAssertEqual(try render(dark, highlights: -100), try render(dark), accuracy: 0.035, "and barely touch dark ones")
        XCTAssertGreaterThan(try render(bright, highlights: 100), try render(bright) + 0.05, "+highlights brightens them")
        XCTAssertEqual(try render(0, shadows: 100), 0, accuracy: 0.01, "black stays black")
        XCTAssertEqual(try render(1, highlights: -100), 1, accuracy: 0.01, "white stays white")
    }

    // MARK: Helpers

    /// Left: low-contrast stripes 4 px wide between encoded grays 0.19 and 0.21. Right: a flat dark area, then a
    /// bright one past x = 96.
    private func measure(_ settings: DevelopSettings) throws -> (stripes: Double, nearEdge: Double) {
        var input = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        for x in stride(from: 0, to: 48, by: 8) {
            input = CIImage(color: CIColor(red: 0.19, green: 0.19, blue: 0.19)).cropped(to: CGRect(x: x, y: 0, width: 4, height: 64))
                .composited(over: CIImage(color: CIColor(red: 0.21, green: 0.21, blue: 0.21))
                    .cropped(to: CGRect(x: x + 4, y: 0, width: 4, height: 64)))
                .composited(over: input)
        }
        input = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 96, y: 0, width: 32, height: 64))
            .composited(over: input)
        // At quarter size, Clarity's window is 17.5 px and Texture's 3.75 px.
        let output = DevelopRenderer.applyAdjustments(settings, to: input, scale: 0.25)
        let image = try XCTUnwrap(DevelopRenderer.shared.cgImage(output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func value(_ x: Int) -> Double { Double(data[(32 * image.width + x) * 4 + 1]) / 255 }
        let stripes = (16..<32).map(value)
        return (stripes.max()! - stripes.min()!, value(93))
    }
}
