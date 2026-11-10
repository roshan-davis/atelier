import CoreGraphics
import XCTest
@testable import AtelierCore

final class HistogramPictureTests: XCTestCase {
    /// A histogram whose red, green and blue are all `bins`.
    private func gray(_ bins: [Double]) throws -> Histogram {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var histogram = try XCTUnwrap(Histogram(image: XCTUnwrap(context.makeImage())))
        histogram.red = bins
        histogram.green = bins
        histogram.blue = bins
        return histogram
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    func testSizeAndTransparentAboveTheGraph() throws {
        let histogram = try gray([Double](repeating: 0.5, count: Histogram.binCount))
        let image = try XCTUnwrap(HistogramPicture.make(histogram, width: 64, height: 40))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 40)
        let data = try pixels(image)
        // Top row (first in memory) is above a half-height graph; the bottom row is filled.
        XCTAssertEqual(data[32 * 4 + 3], 0)
        XCTAssertGreaterThan(data[(39 * 64 + 32) * 4 + 3], 200)
    }

    func testAllThreeChannelsMixToGray() throws {
        let histogram = try gray([Double](repeating: 1, count: Histogram.binCount))
        let data = try pixels(XCTUnwrap(HistogramPicture.make(histogram, width: 16, height: 16)))
        let offset = (15 * 16 + 8) * 4
        let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
        XCTAssertGreaterThan(r, 150)
        XCTAssertLessThanOrEqual(abs(r - g), 6)
        XCTAssertLessThanOrEqual(abs(r - b), 6)
    }

    func testSmoothingKeepsTheEndBins() {
        let bins = [1.0, 0, 0, 1, 0, 0, 1]
        let smoothed = HistogramPicture.smoothed(bins)
        XCTAssertEqual(smoothed.first, 1)
        XCTAssertEqual(smoothed.last, 1)
        XCTAssertEqual(smoothed[3], 0.5, accuracy: 1e-9)
    }

    func testValueMeetsEachBin() {
        let bins = [0.0, 1, 0.25]
        XCTAssertEqual(HistogramPicture.value(of: bins, at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(HistogramPicture.value(of: bins, at: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(HistogramPicture.value(of: bins, at: 1), 0.25, accuracy: 1e-9)
    }
}
