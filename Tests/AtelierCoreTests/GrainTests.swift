import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

final class GrainTests: XCTestCase {
    func testKernelBuilds() {
        XCTAssertTrue(FilmGrain.kernelAvailable)
    }

    func testRoughnessDefaultsToFifty() throws {
        let old = try DevelopSettings.decoded(from: #"{"schemaVersion":1,"grain":40}"#)
        XCTAssertEqual(old.grainRoughness, 50)
        XCTAssertEqual(DevelopSettings.Panel.effects.parameters,
                       [.vignette, .vignetteMidpoint, .grain, .grainSize, .grainRoughness])
    }

    func testGrainIsStrongestInMidtonesAndKeepsBlackBlack() throws {
        var settings = DevelopSettings()
        settings.grain = 60
        let mid = try spread(of: render(settings, linearGray: 0.2))
        let shadow = try spread(of: render(settings, linearGray: 0.003))
        let white = try spread(of: render(settings, linearGray: 1))
        XCTAssertGreaterThan(mid.deviation, 0.02, "midtones are grainy")
        XCTAssertLessThan(shadow.deviation, mid.deviation)
        XCTAssertLessThan(white.deviation, mid.deviation * 0.25, "white stays clean")
        let black = try spread(of: render(settings, linearGray: 0))
        XCTAssertEqual(black.maximum, 0, "black stays black")
        XCTAssertEqual(mid.mean, try spread(of: render(.neutral, linearGray: 0.2)).mean, accuracy: 0.01,
                       "grain doesn't brighten or darken the photo")
    }

    func testGrainIsTheSameOnEveryRender() throws {
        var settings = DevelopSettings()
        settings.grain = 50
        settings.grainRoughness = 80
        XCTAssertEqual(try pixels(render(settings, linearGray: 0.2)), try pixels(render(settings, linearGray: 0.2)))
    }

    func testRoughnessAndSizeChangeThePattern() throws {
        var smooth = DevelopSettings()
        smooth.grain = 50
        smooth.grainRoughness = 0
        var rough = smooth
        rough.grainRoughness = 100
        var large = smooth
        large.grainSize = 90
        let base = try pixels(render(smooth, linearGray: 0.2))
        XCTAssertNotEqual(base, try pixels(render(rough, linearGray: 0.2)))
        XCTAssertNotEqual(base, try pixels(render(large, linearGray: 0.2)))
    }

    /// A smaller render's grain is as strong as the full-size render shrunk to that size, so
    /// the live proxy matches the export.
    func testSmallerRenderMatchesADownsizedFullRender() throws {
        var settings = DevelopSettings()
        settings.grain = 80
        let full = try render(settings, linearGray: 0.2, size: 256)
        let shrunk = try XCTUnwrap(downsize(full, to: 64))
        let small = try render(settings, linearGray: 0.2, size: 64, scale: 0.25)
        let target = try spread(of: shrunk).deviation
        XCTAssertEqual(try spread(of: small).deviation, target, accuracy: target * 0.35)
    }

    // MARK: Helpers

    private func render(_ settings: DevelopSettings, linearGray: Double, size: Int = 64,
                        scale: Double = 1) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let input = CIImage(color: CIColor(red: linearGray, green: linearGray, blue: linearGray)).cropped(to: extent)
        let output = DevelopRenderer.applyAdjustments(settings, to: input, scale: scale)
        return try XCTUnwrap(DevelopRenderer.shared.cgImage(output, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
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

    private func spread(of image: CGImage) throws -> (mean: Double, deviation: Double, maximum: Double) {
        let data = try pixels(image)
        let values = stride(from: 0, to: data.count, by: 4).map { Double(data[$0 + 1]) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return (mean, variance.squareRoot(), values.max() ?? 0)
    }

    private func downsize(_ image: CGImage, to size: Int) -> CGImage? {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context?.makeImage()
    }
}
