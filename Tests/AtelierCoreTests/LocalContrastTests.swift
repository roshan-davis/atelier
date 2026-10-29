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

    // MARK: Helpers

    /// Left: stripes 4 px wide between linear 0.16 and 0.24. Right: a flat dark area, then a
    /// bright one past x = 96.
    private func measure(_ settings: DevelopSettings) throws -> (stripes: Double, nearEdge: Double) {
        var input = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        for x in stride(from: 0, to: 48, by: 8) {
            input = CIImage(color: CIColor(red: 0.16, green: 0.16, blue: 0.16)).cropped(to: CGRect(x: x, y: 0, width: 4, height: 64))
                .composited(over: CIImage(color: CIColor(red: 0.24, green: 0.24, blue: 0.24))
                    .cropped(to: CGRect(x: x + 4, y: 0, width: 4, height: 64)))
                .composited(over: input)
        }
        input = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 96, y: 0, width: 32, height: 64))
            .composited(over: input)
        // At a tenth of full size, Clarity's window is 7 px and Texture's 1.5 px.
        let output = DevelopRenderer.applyAdjustments(settings, to: input, scale: 0.1)
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
