import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// The Develop session's step-1 cache and the clipping overlay painted during the render.
final class RenderCacheTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testCorrectedKeyFollowsOnlyStepOneSettings() {
        let base = DevelopSettings()
        let key = DevelopSession.CorrectedKey(base, view: .photo)
        var later = base
        later.contrast = 40
        later.vibrance = 20
        later.grain = 30
        XCTAssertEqual(DevelopSession.CorrectedKey(later, view: .photo), key, "later panels reuse step 1")

        var changes: [(String, (inout DevelopSettings) -> Void)] = [
            ("exposure", { $0.exposure = 0.5 }),
            ("temperature", { $0.temperature = 4800 }),
            ("tint", { $0.tint = 10 }),
            ("profile", { $0.profile = .appleNeutral }),
            ("lens profile", { $0.lensProfileCorrections.toggle() }),
            ("remove CA", { $0.removeChromaticAberration = true }),
            ("distortion", { $0[.lensDistortion] = 20 }),
            ("lens vignetting", { $0[.lensVignette] = 30 }),
            ("transform", { $0[.transformVertical] = 10 }),
            ("AI Denoise", { $0[.aiDenoise] = 50 }),
        ]
        for parameter in DevelopSettings.Parameter.allCases where parameter.isDefringe {
            changes.append((parameter.rawValue, { $0[parameter] = parameter.defaultValue + 5 }))
        }
        for (name, change) in changes {
            var settings = base
            change(&settings)
            XCTAssertNotEqual(DevelopSession.CorrectedKey(settings, view: .photo), key, name)
        }
        XCTAssertNotEqual(DevelopSession.CorrectedKey(base, view: .amount(.purple)), key, "Defringe views")
        XCTAssertNotEqual(DevelopSession.CorrectedKey(base, view: .photo, denoised: true), key,
                          "AI Denoise's noise picture coming in")
    }

    /// An interactive session renders the same as a fresh one after any sequence of edits, so a
    /// cached step 1 never shows stale settings.
    func testInteractiveSessionMatchesFreshRenders() throws {
        let file = workDir.appendingPathComponent("gray.jpg")
        try Self.makeJPEG(at: file, colors: [0.35, 0.35])
        let interactive = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64, interactive: true))
        var steps: [DevelopSettings] = []
        var settings = DevelopSettings()
        steps.append(settings)
        settings.contrast = 60
        steps.append(settings)
        settings.exposure = 1
        steps.append(settings)
        settings.contrast = -30
        steps.append(settings)
        settings.exposure = 0
        steps.append(settings)
        steps.append(DevelopSettings())
        for (index, step) in steps.enumerated() {
            let fresh = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
            let expected = try Self.centerPixel(XCTUnwrap(fresh.render(step)))
            let actual = try Self.centerPixel(XCTUnwrap(interactive.render(step)))
            // The cached step is stored at the working format's half precision; allow one 8-bit step.
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), 1,
                                         "step \(index): \(actual) vs \(expected)")
            }
        }
    }

    func testRenderForDisplayPaintsClippingButKeepsThePlainCopy() throws {
        let file = workDir.appendingPathComponent("clipped.jpg")
        // Left half pure white, right half mid gray.
        try Self.makeJPEG(at: file, colors: [1, 0.5])
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
        let plainOnly = try XCTUnwrap(session.renderForDisplay(.neutral))
        XCTAssertTrue(plainOnly.image === plainOnly.plain, "no overlay: one render")

        let rendered = try XCTUnwrap(session.renderForDisplay(.neutral, highlightClipping: true))
        let shown = Self.pixel(rendered.image, x: 4, y: rendered.image.height / 2)
        XCTAssertGreaterThan(shown[0], 200)
        XCTAssertLessThan(shown[1], 60, "clipped white turns red")
        let gray = Self.pixel(rendered.image, x: rendered.image.width - 4, y: rendered.image.height / 2)
        XCTAssertLessThan(abs(Int(gray[0]) - Int(gray[1])), 12, "gray stays gray")
        let plain = Self.pixel(rendered.plain, x: 1, y: rendered.plain.height / 2)
        XCTAssertGreaterThan(plain[1], 200, "the histogram's copy has no overlay")
    }

    // MARK: Helpers

    /// A 64 x 32 JPEG split into vertical bands of the given gray levels.
    private static func makeJPEG(at url: URL, colors: [CGFloat]) throws {
        let width = 64, height = 32
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let band = CGFloat(width) / CGFloat(colors.count)
        for (index, level) in colors.enumerated() {
            context.setFillColor(red: level, green: level, blue: level, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * band, y: 0, width: band, height: CGFloat(height)))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func centerPixel(_ image: CGImage) -> [UInt8] {
        pixel(image, x: image.width / 2, y: image.height / 2)
    }

    /// RGB at `x`, `y` (from the top left), drawn into sRGB.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let i = (y * width + x) * 4
        return [data[i], data[i + 1], data[i + 2]]
    }
}
