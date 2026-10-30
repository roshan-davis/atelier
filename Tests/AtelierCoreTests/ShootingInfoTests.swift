import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AtelierCore

/// The line under the histogram (ISO, focal length, aperture, shutter speed) and the clipping
/// triangles and overlay.
final class ShootingInfoTests: XCTestCase {
    func testFormatsLikeLightroom() {
        XCTAssertEqual(ShootingInfo.formatISO(400), "ISO 400")
        XCTAssertEqual(ShootingInfo.formatFocalLength(50), "50 mm")
        XCTAssertEqual(ShootingInfo.formatFocalLength(24.5), "24.5 mm")
        XCTAssertEqual(ShootingInfo.formatAperture(2.8), "ƒ/2.8")
        XCTAssertEqual(ShootingInfo.formatAperture(8), "ƒ/8")
        XCTAssertEqual(ShootingInfo.formatAperture(1.7999999), "ƒ/1.8")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(0.004), "1/250 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(1.0 / 8000), "1/8000 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(1.0 / 3), "1/3 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(0.5), "1/2 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(0.6), "0.6 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(1), "1 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(2.5), "2.5 sec")
        XCTAssertEqual(ShootingInfo.formatShutterSpeed(30), "30 sec")
        XCTAssertEqual(ShootingInfo.formatExposureCompensation(0.6666), "+0.7 EV")
        XCTAssertEqual(ShootingInfo.formatExposureCompensation(-1), "−1 EV")
        XCTAssertEqual(ShootingInfo.formatExposureCompensation(0), "0 EV")
    }

    func testReadsEXIFProperties() {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [800],
                kCGImagePropertyExifFocalLength: 40.0,
                kCGImagePropertyExifFNumber: 2.0,
                kCGImagePropertyExifExposureTime: 0.0025,
                kCGImagePropertyExifExposureBiasValue: -0.3333,
                kCGImagePropertyExifLensModel: "NIKKOR Z 40mm f/2 ",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                kCGImagePropertyTIFFModel: "NIKON Z f",
            ] as [CFString: Any],
        ]
        let info = ShootingInfo(properties: properties)
        XCTAssertEqual(info.parts, ["ISO 800", "40 mm", "ƒ/2", "1/400 sec"])
        XCTAssertEqual(info.details, "NIKON Z f\nNIKKOR Z 40mm f/2\nExposure compensation −0.3 EV")
        XCTAssertFalse(info.isEmpty)
    }

    func testFileWithoutEXIFIsEmpty() {
        let info = ShootingInfo(properties: [:])
        XCTAssertTrue(info.isEmpty)
        XCTAssertEqual(info.parts, [])
    }

    func testApertureFromAPEXValue() {
        let info = ShootingInfo(properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifApertureValue: 3.0] as [CFString: Any]])
        XCTAssertEqual(info.parts, ["ƒ/2.8"])
    }

    func testCameraNameDropsRepeatedMake() {
        XCTAssertEqual(ShootingInfo.cameraName(make: "NIKON CORPORATION", model: "NIKON Z 6"), "NIKON Z 6")
        XCTAssertEqual(ShootingInfo.cameraName(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertEqual(ShootingInfo.cameraName(make: "SONY", model: "ILCE-7M4"), "SONY ILCE-7M4")
        XCTAssertEqual(ShootingInfo.cameraName(make: "Apple", model: nil), "Apple")
        XCTAssertNil(ShootingInfo.cameraName(make: nil, model: nil))
    }

    func testReadsFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shooting-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(Self.image([(128, 128, 128)]))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifISOSpeedRatings: [100], kCGImagePropertyExifFNumber: 5.6,
            kCGImagePropertyExifExposureTime: 1.0 / 125, kCGImagePropertyExifFocalLength: 85.0,
        ] as [CFString: Any]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(ShootingInfo(url: url).parts, ["ISO 100", "85 mm", "ƒ/5.6", "1/125 sec"])
    }

    func testHistogramCountsClippingPerChannel() throws {
        // One pixel each: red clipped high, pure white, pure black, mid gray.
        let image = try XCTUnwrap(Self.image([(255, 100, 100), (255, 255, 255), (0, 0, 0), (128, 128, 128)]))
        let histogram = try XCTUnwrap(Histogram(image: image))
        XCTAssertEqual(histogram.highlightChannels, [0.5, 0.25, 0.25])
        XCTAssertEqual(histogram.shadowChannels, [0.25, 0.25, 0.25])
        XCTAssertEqual(histogram.highlightClipping, 0.5)
        XCTAssertEqual(histogram.shadowClipping, 0.25)
    }

    func testClippingOverlayPaintsOnlyClippedPixels() throws {
        let image = try XCTUnwrap(Self.image([(255, 100, 100), (128, 128, 128), (0, 50, 50), (200, 200, 200)]))
        let both = try XCTUnwrap(ClippingOverlay.apply(to: image, shadows: true, highlights: true))
        let pixels = Self.pixels(both)
        XCTAssertEqual(pixels[0], [255, 0, 0])
        XCTAssertEqual(pixels[1], [128, 128, 128])
        XCTAssertEqual(pixels[2][2], 255)
        XCTAssertEqual(pixels[2][0], 0)
        XCTAssertEqual(pixels[3], [200, 200, 200])
        // Highlights only: the black pixel keeps its color.
        let highlights = try XCTUnwrap(ClippingOverlay.apply(to: image, shadows: false, highlights: true))
        XCTAssertEqual(Self.pixels(highlights)[2], [0, 50, 50])
    }

    /// A one-row sRGB image.
    private static func image(_ colors: [(UInt8, UInt8, UInt8)]) -> CGImage? {
        var bytes: [UInt8] = colors.flatMap { [$0.0, $0.1, $0.2, 255] }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: colors.count, height: 1, bitsPerComponent: 8, bytesPerRow: colors.count * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func pixels(_ image: CGImage) -> [[Int]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (0..<(image.width * image.height)).map { i in [Int(bytes[i * 4]), Int(bytes[i * 4 + 1]), Int(bytes[i * 4 + 2])] }
    }
}
