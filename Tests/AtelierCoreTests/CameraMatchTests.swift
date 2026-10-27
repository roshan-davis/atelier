import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class CameraMatchTests: XCTestCase {
    /// Packed RGBA8 with every pixel's channels from `tone`, over a ramp of `count` pixels.
    private func ramp(_ count: Int, tint: (Double) -> (Double, Double, Double)) -> [UInt8] {
        (0..<count).flatMap { i -> [UInt8] in
            let (r, g, b) = tint(Double(i) / Double(count - 1))
            return [r, g, b, 1].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        }
    }

    func testSameImageGivesIdentity() {
        let pixels = ramp(4096) { x in (x, x * 0.9, x * 0.8) }
        let match = CameraMatch.fit(source: pixels, target: pixels)
        for x in stride(from: 0.1, through: 0.9, by: 0.1) {
            XCTAssertEqual(match.value(at: x), x, accuracy: 0.03)
        }
        XCTAssertEqual(match.saturation, 1, accuracy: 0.03)
    }

    func testBrighterTargetLiftsTheCurve() {
        let source = ramp(4096) { x in (x, x, x) }
        let target = ramp(4096) { x in let y = pow(x, 0.7); return (y, y, y) }
        let match = CameraMatch.fit(source: source, target: target)
        for x in [0.2, 0.4, 0.6] {
            XCTAssertEqual(match.value(at: x), pow(x, 0.7), accuracy: 0.05, "at \(x)")
        }
        XCTAssertEqual(match.value(at: 1), 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(match.value(at: 0), 0.02)
        // Rising everywhere.
        XCTAssertEqual(match.curve, match.curve.sorted())
    }

    func testShiftIsLimited() {
        let source = ramp(4096) { x in let y = x * 0.1; return (y, y, y) }
        let target = ramp(4096) { x in (x, x, x) }
        let match = CameraMatch.fit(source: source, target: target)
        for (i, y) in match.curve.enumerated() {
            let x = Double(i) / Double(match.curve.count - 1)
            XCTAssertLessThanOrEqual(Double(y) - x, CameraMatch.maxShift + 0.001)
        }
    }

    func testMoreColorfulTargetRaisesSaturation() {
        let source = ramp(4096) { x in (x, x * 0.85, x * 0.7) }
        let target = ramp(4096) { x in (x, x * 0.7, x * 0.45) }
        let match = CameraMatch.fit(source: source, target: target)
        XCTAssertGreaterThan(match.saturation, 1.1)
        XCTAssertLessThanOrEqual(match.saturation, 1.35)
    }

    func testGrayKeepsSaturation() {
        let source = ramp(4096) { x in (x, x, x) }
        let target = ramp(4096) { x in let y = x * 0.8 + 0.1; return (y, y, y) }
        XCTAssertEqual(CameraMatch.fit(source: source, target: target).saturation, 1)
    }

    func testLetterboxedPreviewIsCroppedToThePhotosShape() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: DevelopRenderer.sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let reference = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: DevelopRenderer.sRGB,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let cropped = try XCTUnwrap(CameraMatch.cropped(try XCTUnwrap(context.makeImage()), toAspectOf: reference))
        XCTAssertEqual(cropped.width, 160)
        XCTAssertEqual(cropped.height, 107, accuracy: 1)
    }

    /// Real camera files, when CI has downloaded some into ATELIER_SAMPLE_RAWS. Compares the
    /// camera's embedded preview with Apple's neutral render and the camera-matched render,
    /// and writes the three side by side to ATELIER_SAMPLE_OUT.
    func testSampleRAWsMatchTheirPreviews() throws {
        guard let folder = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_RAWS"] else {
            throw XCTSkip("No sample RAW files")
        }
        let output = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_OUT"].map { URL(fileURLWithPath: $0) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                includingPropertiesForKeys: nil)
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .rawImage) == true }
        if files.isEmpty { throw XCTSkip("No sample RAW files downloaded") }
        let renderer = DevelopRenderer()
        for url in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let preview = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
            ] as CFDictionary))
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
            raw.scaleFactor = Float(900 / max(raw.nativeSize.width, raw.nativeSize.height))
            let apple = try XCTUnwrap(renderer.context.createCGImage(raw.outputImage!, from: raw.outputImage!.extent.integral,
                                                                    format: .RGBA8, colorSpace: DevelopRenderer.sRGB))
            let session = try XCTUnwrap(renderer.session(for: url, maxPixelSize: 900))
            let matched = try XCTUnwrap(session.render(.neutral))
            let p = meanLuma(preview), a = meanLuma(apple), m = meanLuma(matched)
            print("CAMERA MATCH \(url.lastPathComponent): preview \(p) apple \(a) matched \(m) saturation \(session.cameraMatch.saturation) curve(0.25)=\(session.cameraMatch.value(at: 0.25)) curve(0.5)=\(session.cameraMatch.value(at: 0.5))")
            XCTAssertFalse(session.cameraMatch.isIdentity, url.lastPathComponent)
            XCTAssertLessThan(abs(m - p), max(0.03, abs(a - p) / 2), url.lastPathComponent)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try writeSideBySide([preview, apple, matched],
                                    to: output.appendingPathComponent("camera-match-\(url.deletingPathExtension().lastPathComponent).png"))
            }
        }
    }

    private func meanLuma(_ image: CGImage) -> Double {
        guard let pixels = CameraMatch.pixels(image) else { return .nan }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return sum / Double(pixels.count / 4) / 255
    }

    private func writeSideBySide(_ images: [CGImage], to url: URL) throws {
        let height = 600
        let widths = images.map { $0.width * height / $0.height }
        let context = try XCTUnwrap(CGContext(data: nil, width: widths.reduce(0, +) + 20 * (images.count - 1),
                                              height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: DevelopRenderer.sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: height))
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width + 20
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
