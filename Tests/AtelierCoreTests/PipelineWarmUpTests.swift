import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

/// AT-039 D3a: the warm-up renders and the live sessions' stage cache.
final class PipelineWarmUpTests: XCTestCase {
    func testVariantsTurnOnOnlyIdleTools() {
        var settings = DevelopSettings()
        settings.clarity = 35
        settings.masks = [DevelopSettings.Mask(name: "Radial")]
        let variants = DevelopRenderer.warmUpVariants(settings)
        XCTAssertGreaterThan(variants.count, 10)
        XCTAssertTrue(variants.allSatisfy(\.masks.isEmpty), "masks need the photo itself")
        XCTAssertTrue(variants.allSatisfy { $0.clarity == 35 }, "a tool already on keeps its value")
        XCTAssertTrue(variants.contains { $0.highlights != 0 })
        XCTAssertTrue(variants.contains { !Calibration.isNeutral($0) }, "Calibration's kernel is built before its first drag")
        XCTAssertEqual(Set(variants.map { $0 }).count, variants.count, "no render twice")
    }

    func testWarmUpRendersEveryVariant() {
        let settings = DevelopSettings()
        XCTAssertEqual(DevelopRenderer.shared.warmUp(settings, scale: 0.25), DevelopRenderer.warmUpVariants(settings).count)
        XCTAssertEqual(DevelopRenderer.shared.warmUp(settings, scale: 0.25, isCurrent: { false }), 0, "stops when told")
    }

    /// Caching Highlights/Shadows' and Clarity/Texture's smoothed base doesn't change the photo
    /// beyond half-float rounding: within one 8-bit level everywhere.
    func testStageCacheKeepsTheLook() throws {
        var input = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        input = CIImage(color: CIColor(red: 0.7, green: 0.6, blue: 0.5)).cropped(to: CGRect(x: 40, y: 0, width: 56, height: 64))
            .composited(over: input)
        var settings = DevelopSettings()
        settings.highlights = -60
        settings.shadows = 40
        settings.clarity = 30
        settings.texture = -20
        let plain = try pixels(DevelopRenderer.applyAdjustments(settings, to: input, scale: 0.25))
        for _ in 0..<2 {
            let cached = try pixels(DevelopRenderer.applyAdjustments(settings, to: input, scale: 0.25, cacheStages: true))
            XCTAssertEqual(cached.count, plain.count)
            let worst = zip(plain, cached).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1)
        }
    }

    private func pixels(_ image: CIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(DevelopRenderer.shared.cgImage(image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                              bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return data
    }
}
