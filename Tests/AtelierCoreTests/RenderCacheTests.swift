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

    /// AT-046: the kept decode follows only what the decode reads, so Lens Corrections and
    /// Transform ticks start from it instead of the RAW file.
    func testDecodeKeyIgnoresLensCorrectionsAndTransform() {
        let base = DevelopSettings()
        let key = DevelopSession.DecodeKey(base)
        var lens: [(String, (inout DevelopSettings) -> Void)] = [
            ("remove CA", { $0.removeChromaticAberration = true }),
            ("distortion", { $0[.lensDistortion] = 20 }),
            ("lens vignetting", { $0[.lensVignette] = 30 }),
            ("transform", { $0[.transformVertical] = 10 }),
            ("later panel", { $0.contrast = 40 }),
        ]
        for parameter in DevelopSettings.Parameter.allCases where parameter.isDefringe {
            lens.append((parameter.rawValue, { $0[parameter] = parameter.defaultValue + 5 }))
        }
        for (name, change) in lens {
            var settings = base
            change(&settings)
            XCTAssertEqual(DevelopSession.DecodeKey(settings), key, name)
        }
        let decode: [(String, (inout DevelopSettings) -> Void)] = [
            ("exposure", { $0.exposure = 0.5 }),
            ("temperature", { $0.temperature = 4800 }),
            ("tint", { $0.tint = 10 }),
            ("profile", { $0.profile = .appleNeutral }),
            ("lens profile", { $0.lensProfileCorrections.toggle() }),
        ]
        for (name, change) in decode {
            var settings = base
            change(&settings)
            XCTAssertNotEqual(DevelopSession.DecodeKey(settings), key, name)
        }
    }

    /// AT-046: Lens Corrections and Transform edits on the kept decode render the same as a fresh
    /// session, over the whole photo (vignetting and the warp change the edges), through
    /// sequences that go back and forth between kept decodes.
    func testInteractiveLensEditsMatchFreshRenders() throws {
        let file = workDir.appendingPathComponent("bands.jpg")
        try Self.makeJPEG(at: file, colors: [0.2, 0.5, 0.8, 0.4])
        let interactive = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64, interactive: true))
        var steps: [DevelopSettings] = []
        var settings = DevelopSettings()
        steps.append(settings)
        settings[.lensVignette] = 40
        steps.append(settings)
        settings[.lensVignette] = 60
        steps.append(settings)
        settings[.lensDistortion] = 30
        steps.append(settings)
        settings[.lensDefringePurpleAmount] = 8
        steps.append(settings)
        settings.removeChromaticAberration = true
        steps.append(settings)
        settings.exposure = 0.7
        steps.append(settings)
        settings[.lensDistortion] = -20
        steps.append(settings)
        settings[.transformVertical] = 15
        steps.append(settings)
        settings.exposure = 0
        steps.append(settings)
        settings.contrast = 40
        steps.append(settings)
        steps.append(DevelopSettings())
        for (index, step) in steps.enumerated() {
            let fresh = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
            let expected = try XCTUnwrap(fresh.render(step))
            let actual = try XCTUnwrap(interactive.render(step))
            XCTAssertEqual(actual.width, expected.width, "step \(index)")
            XCTAssertEqual(actual.height, expected.height, "step \(index)")
            // Two kept intermediates at the working format's half precision; a stale cache would
            // be off by far more than two 8-bit steps.
            var worst = 0
            for y in stride(from: 0, to: expected.height, by: 3) {
                for x in stride(from: 0, to: expected.width, by: 3) {
                    let a = Self.pixel(actual, x: x, y: y), e = Self.pixel(expected, x: x, y: y)
                    for channel in 0..<3 { worst = max(worst, abs(Int(a[channel]) - Int(e[channel]))) }
                }
            }
            XCTAssertLessThanOrEqual(worst, 2, "step \(index)")
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
