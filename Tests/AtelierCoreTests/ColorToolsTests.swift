import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Tone Curve, HSL / Color and Effects: the Lightroom-matching fixes and tools.
final class ColorToolsTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierColorTools-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testKernelsBuild() {
        XCTAssertTrue(ToneCurve.kernelAvailable)
        XCTAssertTrue(PostCropVignette.kernelAvailable)
        XCTAssertTrue(Glow.kernelAvailable)
    }

    // MARK: Tone Curve

    /// The region sliders never move black or white, and the curve keeps rising.
    func testRegionCurveKeepsBlackAndWhite() {
        var settings = DevelopSettings()
        settings[.curveShadows] = 100
        settings[.curveDarks] = 100
        settings[.curveLights] = -100
        settings[.curveHighlights] = -100
        XCTAssertEqual(DevelopRenderer.toneCurveValue(settings, at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(DevelopRenderer.toneCurveValue(settings, at: 1), 1, accuracy: 1e-6)
        var last = -1.0
        for i in 0...100 {
            let y = DevelopRenderer.toneCurveValue(settings, at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(y, last - 1e-9, "rising at \(i)")
            last = y
        }
    }

    /// Moving the split between Darks and Lights moves where Darks acts.
    func testSplitsMoveRegions() {
        var settings = DevelopSettings()
        settings[.curveDarks] = 100
        let before = DevelopRenderer.toneCurveValue(settings, at: 0.5)
        settings[.curveMidtoneSplit] = 70
        let after = DevelopRenderer.toneCurveValue(settings, at: 0.5)
        XCTAssertGreaterThan(after, before + 0.02, "Darks now reaches further up: \(before) → \(after)")

        settings[.curveShadowSplit] = 90
        let (low, middle, high) = DevelopRenderer.curveSplits(settings)
        XCTAssertLessThan(low, middle)
        XCTAssertLessThan(middle, high)
    }

    func testRegionWeightsFollowTone() {
        let settings = DevelopSettings()
        let dark = TargetedAdjustment.regionWeights(tone: 0.12, settings: settings)
        XCTAssertEqual(dark.firstIndex(of: 1), 0, "a dark tone belongs to Shadows: \(dark)")
        let bright = TargetedAdjustment.regionWeights(tone: 0.9, settings: settings)
        XCTAssertEqual(bright.firstIndex(of: 1), 3, "a bright tone belongs to Highlights: \(bright)")
    }

    // MARK: HSL

    /// Saturation -100 turns a color gray at the brightness the eye saw, not HSL lightness
    /// (which turned deep blue into 50% gray).
    func testDesaturatingKeepsBrightness() {
        var settings = DevelopSettings()
        for band in DevelopSettings.ColorBand.allCases { settings[.hsl(.saturation, band)] = -100 }
        let hsl = HSLAdjustment(settings)
        for color: RGB in [(0.1, 0.2, 0.8), (0.9, 0.8, 0.1), (0.2, 0.7, 0.3), (0.8, 0.2, 0.2)] {
            let before = Oklab.fromEncoded(color)
            let after = Oklab.fromEncoded(hsl.apply(color))
            XCTAssertEqual(after.x, before.x, accuracy: 0.01, "\(color)")
            XCTAssertLessThan(Oklab.chromaHue(after).chroma, 0.01, "\(color) turned gray")
        }
    }

    /// Grays and noise-level tints are left alone, so HSL does not stir up shadow noise.
    func testHSLLeavesNearGraysAlone() {
        var settings = DevelopSettings()
        for band in DevelopSettings.ColorBand.allCases { settings[.hsl(.saturation, band)] = 100 }
        let hsl = HSLAdjustment(settings)
        let noisy: RGB = (0.06, 0.055, 0.058)
        let out = hsl.apply(noisy)
        XCTAssertEqual(out.0, noisy.0, accuracy: 0.003)
        XCTAssertEqual(out.1, noisy.1, accuracy: 0.003)
        XCTAssertEqual(out.2, noisy.2, accuracy: 0.003)
    }

    /// The color cube spans Display P3: a pure P3 red that HSL does not touch comes out as it went
    /// in (an sRGB cube clipped it to sRGB red).
    func testCubeKeepsWideGamutColors() throws {
        var settings = DevelopSettings()
        settings[.hsl(.saturation, .aqua)] = 20
        let data = try XCTUnwrap(ColorLUT.cube(for: settings))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = ColorLUT.dimension
        let red = (n - 1) * 4 // r = 1, g = 0, b = 0
        XCTAssertEqual(Double(values[red]), 1, accuracy: 0.01)
        XCTAssertEqual(Double(values[red + 1]), 0, accuracy: 0.01)
        XCTAssertEqual(Double(values[red + 2]), 0, accuracy: 0.01)
    }

    /// A strong tint on a vivid color stays inside Display P3, the cube's gamut.
    func testTintsStayInDisplayP3() {
        var settings = DevelopSettings()
        settings[.gradeGlobalHue] = 180
        settings[.gradeGlobalSat] = 100
        let out = Oklab.encodedP3(fromSRGB: ColorGrade(settings).apply((0.9, 0.05, 0.05)))
        for channel in [out.0, out.1, out.2] {
            XCTAssertGreaterThanOrEqual(channel, -0.01)
            XCTAssertLessThanOrEqual(channel, 1.01)
        }
    }

    func testBandWeightsForTargetedAdjustment() throws {
        let orange = try XCTUnwrap(TargetedAdjustment.bandWeights(of: SIMD3(0.9, 0.55, 0.2)))
        XCTAssertEqual(orange.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(orange.indices.max { orange[$0] < orange[$1] }, DevelopSettings.ColorBand.allCases.firstIndex(of: .orange))
        XCTAssertNil(TargetedAdjustment.bandWeights(of: SIMD3(0.5, 0.5, 0.5)), "gray moves no band")
    }

    // MARK: Point Color

    private func pointColor(at sample: SIMD3<Double>, _ values: [DevelopSettings.PointColorSetting: Double]) throws
        -> DevelopSettings {
        let target = try XCTUnwrap(TargetedAdjustment.pointColor(of: sample))
        var settings = DevelopSettings()
        settings[.pointColor(0, .hue)] = target.hue
        settings[.pointColor(0, .chroma)] = target.chroma
        settings[.pointColor(0, .lightness)] = target.lightness
        for (setting, value) in values { settings[.pointColor(0, setting)] = value }
        return settings
    }

    /// A swatch changes the picked color and leaves colors far from it alone.
    func testPointColorChangesOnlyThePickedColor() throws {
        let skin = SIMD3(0.85, 0.62, 0.5)
        let settings = try pointColor(at: skin, [.satShift: -60])
        let mix = ColorMix(settings)
        let picked = Oklab.fromEncoded((skin.x, skin.y, skin.z))
        let changed = Oklab.fromEncoded(mix.apply((skin.x, skin.y, skin.z)))
        XCTAssertLessThan(Oklab.chromaHue(changed).chroma, Oklab.chromaHue(picked).chroma * 0.6)

        let sky: RGB = (0.3, 0.5, 0.85)
        let untouched = mix.apply(sky)
        XCTAssertEqual(untouched.0, sky.0, accuracy: 1e-6)
        XCTAssertEqual(untouched.2, sky.2, accuracy: 1e-6)
        XCTAssertNil(TargetedAdjustment.pointColor(of: SIMD3(0.4, 0.4, 0.4)), "gray has no color to pick")
    }

    /// Uniformity pulls nearby colors toward the picked one: blotchy skin evens out.
    func testUniformityEvensOutColors() throws {
        let skin = SIMD3(0.85, 0.62, 0.5)
        let settings = try pointColor(at: skin, [.uniformity: 100])
        let mix = ColorMix(settings)
        let target = Oklab.chromaHue(Oklab.fromEncoded((skin.x, skin.y, skin.z))).hue
        let redder: RGB = (0.86, 0.56, 0.5)
        let before = abs(Oklab.chromaHue(Oklab.fromEncoded(redder)).hue - target)
        let after = abs(Oklab.chromaHue(Oklab.fromEncoded(mix.apply(redder))).hue - target)
        XCTAssertLessThan(after, before * 0.75, "hue gap \(before) → \(after)")
    }

    func testPointColorRoundTrips() throws {
        let settings = try pointColor(at: SIMD3(0.85, 0.62, 0.5), [.hueShift: 20, .range: 70])
        XCTAssertTrue(settings.hasPointColor(0))
        XCTAssertFalse(settings.hasPointColor(1))
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        XCTAssertNotNil(ColorLUT.cube(for: settings))
    }

    // MARK: Effects

    /// The vignette follows the crop's shape: on a 2:1 photo the middle of the left edge and the
    /// middle of the top edge darken alike (Core Image's circle darkened the sides more).
    func testVignetteFollowsTheCrop() throws {
        let file = workDir.appendingPathComponent("wide.jpg")
        try makeJPEG(at: file, width: 128, height: 64, gray: 0.6)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 128))
        var settings = DevelopSettings()
        settings.vignette = -100
        let image = try XCTUnwrap(session.render(settings))
        let pixels = try gray(image)
        let w = image.width, h = image.height
        let center = pixels[h / 2 * w + w / 2]
        let side = pixels[h / 2 * w + 1]
        let top = pixels[1 * w + w / 2]
        XCTAssertLessThan(side, center - 0.1, "edges darken: center \(center), side \(side)")
        XCTAssertEqual(side, top, accuracy: 0.06, "side \(side), top \(top)")
    }

    func testGlowBrightensAroundHighlights() throws {
        let file = workDir.appendingPathComponent("spot.jpg")
        try makeJPEG(at: file, width: 64, height: 64, gray: 0.2, spot: true)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
        let plain = try gray(XCTUnwrap(session.render(.neutral)))
        var settings = DevelopSettings()
        settings[.glowAmount] = 100
        settings[.glowSpread] = 100
        let glowing = try gray(XCTUnwrap(session.render(settings)))
        // Just outside the bright spot in the middle (it spans 28...35).
        let near = 32 * 64 + 32 + 6
        XCTAssertGreaterThan(glowing[near], plain[near] + 0.01, "\(plain[near]) → \(glowing[near])")
    }

    // MARK: Helpers

    private func gray(_ image: CGImage) throws -> [Double] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<(w * h)).map { i in
            let red = Double(data[i * 4])
            let green = Double(data[i * 4 + 1])
            let blue = Double(data[i * 4 + 2])
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
    }

    private func makeJPEG(at url: URL, width: Int, height: Int, gray: CGFloat, spot: Bool = false) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if spot {
            context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: width / 2 - 4, y: height / 2 - 4, width: 8, height: 8))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
