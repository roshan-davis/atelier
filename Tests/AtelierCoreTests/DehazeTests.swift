import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

final class DehazeTests: XCTestCase {
    func testKernelsBuild() {
        XCTAssertTrue(Dehaze.kernelsAvailable)
    }

    /// Three bands: a dark, clear green; the same green behind haze; bright haze (sky).
    func testRemovesHazeWithoutCrushingBlacksOrClippingTheSky() throws {
        let neutral = try render(amount: 0)
        let clearer = try render(amount: 0.5)
        let strongest = try render(amount: 1)
        let hazier = try render(amount: -0.5)

        XCTAssertLessThan(clearer.hazy, neutral.hazy - 0.03, "haze over the green is removed")
        XCTAssertLessThan(strongest.hazy, clearer.hazy, "more Dehaze removes more")
        XCTAssertGreaterThan(strongest.hazy, 0.05, "the hazy green doesn't go black")
        XCTAssertEqual(strongest.clear, neutral.clear, accuracy: 0.04, "a dark, clear area barely changes")
        XCTAssertEqual(strongest.sky, neutral.sky, accuracy: 0.03, "the sky doesn't clip or darken much")
        XCTAssertGreaterThan(hazier.hazy, neutral.hazy + 0.03, "negative Dehaze adds haze")
    }

    func testSmallerRenderMatchesFullSize() throws {
        let full = try render(amount: 0.6, width: 1536)
        let small = try render(amount: 0.6, width: 384)
        XCTAssertEqual(full.hazy, small.hazy, accuracy: 0.03)
    }

    // MARK: Helpers

    /// Green (sRGB-encoded) at the middle of each band after Dehaze at `amount`.
    private func render(amount: Double, width: Int = 384) throws -> (clear: Double, hazy: Double, sky: Double) {
        let band = CGFloat(width) / 3
        let height = band
        func patch(_ r: Double, _ g: Double, _ b: Double, _ index: CGFloat) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b))
                .cropped(to: CGRect(x: band * index, y: 0, width: band, height: height))
        }
        let input = patch(0.01, 0.05, 0.01, 0)
            .composited(over: patch(0.31, 0.33, 0.31, 1))
            .composited(over: patch(0.85, 0.85, 0.88, 2))
        let output = DevelopRenderer.dehaze(input, amount: amount)
        let image = try XCTUnwrap(DevelopRenderer.shared.cgImage(output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let data = try pixels(image)
        func green(_ index: Double) -> Double {
            let x = Int(Double(band) * (index + 0.5)), y = Int(height / 2)
            return Double(data[(y * image.width + x) * 4 + 1]) / 255
        }
        return (green(0), green(1), green(2))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
