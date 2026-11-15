import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Color Range masks (AT-068): saving, the weight math, picking and the rendered mask.
final class ColorRangeMaskTests: XCTestCase {
    private typealias Mask = DevelopSettings.Mask
    private typealias Component = DevelopSettings.MaskComponent
    private typealias ColorRange = DevelopSettings.ColorRange
    private typealias ColorSample = DevelopSettings.ColorSample

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierColorRange-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testColorRangeSurvivesSavingAndAnEmptyOneDecodes() throws {
        var settings = DevelopSettings()
        let sample = ColorSample(box: .init(x: 0.1, y: 0.2, width: 0.05, height: 0.05), lab: SIMD3(0.6, 0.1, 0.05), spread: 0.02)
        var mask = Mask(name: "Mask 1", components: [Component(.color(ColorRange(samples: [sample], refine: 70)))])
        mask[.saturation] = -40
        settings.masks = [mask]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?.components.first?.kind, .color)
        XCTAssertEqual(decoded.masks.first?.components.first?.pin?.x ?? 0, 0.125, accuracy: 1e-9)

        let bare = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"color"}]}]}"#)
        XCTAssertEqual(bare.masks.first?.components.first?.shape, .color(ColorRange()))
    }

    func testWeightIsFullAtThePickAndRefineReachesFurther() {
        let red = ColorRangeSpace.oklab(fromWorking: SIMD3(0.6, 0.05, 0.04))
        let orange = ColorRangeSpace.oklab(fromWorking: SIMD3(0.6, 0.2, 0.04))
        let blue = ColorRangeSpace.oklab(fromWorking: SIMD3(0.05, 0.1, 0.6))
        let narrow = ColorRange(samples: [ColorSample(box: .init(x: 0, y: 0, width: 0, height: 0), lab: red)], refine: 0)
        var wide = narrow
        wide.refine = 100
        XCTAssertEqual(narrow.weight(of: red), 1, accuracy: 1e-9)
        XCTAssertEqual(narrow.weight(of: blue), 0, accuracy: 1e-9)
        XCTAssertEqual(wide.weight(of: blue), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(wide.weight(of: orange), narrow.weight(of: orange))
        // The same red half a stop darker is still picked at the default Refine: lightness counts half.
        let shadedRed = ColorRangeSpace.oklab(fromWorking: SIMD3(0.42, 0.035, 0.028))
        XCTAssertGreaterThan(ColorRange(samples: narrow.samples, refine: 50).weight(of: shadedRed), 0.8)
        // No picks, no mask.
        XCTAssertEqual(ColorRange().weight(of: red), 0)
    }

    func testOklabOfWhiteIsNeutralAndSwatchesRoundTrip() {
        let white = ColorRangeSpace.oklab(fromWorking: SIMD3(1, 1, 1))
        XCTAssertEqual(white.x, 1, accuracy: 0.001)
        XCTAssertEqual(white.y, 0, accuracy: 0.001)
        XCTAssertEqual(white.z, 0, accuracy: 0.001)
        let gray = ColorSample(box: .init(x: 0, y: 0, width: 0, height: 0),
                               lab: ColorRangeSpace.oklab(fromWorking: SIMD3(0.2140, 0.2140, 0.2140)))
        // Linear 0.214 is sRGB 0.5.
        XCTAssertEqual(gray.displaySRGB.x, 0.5, accuracy: 0.005)
        XCTAssertEqual(gray.displaySRGB.z, 0.5, accuracy: 0.005)
    }

    func testPickingRedDarkensOnlyTheRedHalf() throws {
        try XCTSkipUnless(DevelopRenderer.colorRangeKernelAvailable, "The Color Range Metal kernel didn't build here")
        let file = workDir.appendingPathComponent("red-blue.jpg")
        try makeTwoColorJPEG(at: file)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
        // A click on the red half, and a drag over it.
        let click = try XCTUnwrap(session.colorSample(in: .init(x: 0.25, y: 0.5, width: 0, height: 0), settings: .neutral))
        XCTAssertEqual(click.spread, 0)
        let drag = try XCTUnwrap(session.colorSample(in: .init(x: 0.05, y: 0.1, width: 0.35, height: 0.8), settings: .neutral))
        XCTAssertLessThan(ColorSample.distance(click.lab, drag.lab), 0.03)
        XCTAssertGreaterThan(click.a, 0.1, "red has a positive Oklab a")

        var settings = DevelopSettings()
        var mask = Mask(name: "Mask 1", components: [Component(.color(ColorRange(samples: [click])))])
        mask[.exposure] = -2
        settings.masks = [mask]
        let neutral = try XCTUnwrap(session.render(.neutral))
        let render = try XCTUnwrap(session.render(settings))
        XCTAssertLessThan(try luma(render, x: 16, y: 32), try luma(neutral, x: 16, y: 32) - 0.08)
        XCTAssertEqual(try luma(render, x: 48, y: 32), try luma(neutral, x: 48, y: 32), accuracy: 0.02)

        // Found before tone and color: a global slider doesn't move the mask.
        var brighter = settings
        brighter.exposure = 0.7
        var brighterNeutral = DevelopSettings()
        brighterNeutral.exposure = 0.7
        let lifted = try XCTUnwrap(session.render(brighter))
        let liftedNeutral = try XCTUnwrap(session.render(brighterNeutral))
        XCTAssertLessThan(try luma(lifted, x: 16, y: 32), try luma(liftedNeutral, x: 16, y: 32) - 0.08)
        XCTAssertEqual(try luma(lifted, x: 48, y: 32), try luma(liftedNeutral, x: 48, y: 32), accuracy: 0.02)

        // Inverted, it lands on the blue half instead.
        settings.masks[0].components[0].inverted = true
        let inverted = try XCTUnwrap(session.render(settings))
        XCTAssertEqual(try luma(inverted, x: 16, y: 32), try luma(neutral, x: 16, y: 32), accuracy: 0.02)
        XCTAssertLessThan(try luma(inverted, x: 48, y: 32), try luma(neutral, x: 48, y: 32) - 0.03)
    }

    // MARK: Helpers

    private func luma(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                  bytesPerRow: 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    /// 64 × 64: red on the left half, blue on the right.
    private func makeTwoColorJPEG(at url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.15, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
