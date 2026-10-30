import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class ColorTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierColor-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testDefaultsAreNotStored() throws {
        var settings = DevelopSettings()
        settings.exposure = 1
        settings.exposure = 0
        settings[.hsl(.saturation, .blue)] = 0
        XCTAssertEqual(settings, .neutral)
        XCTAssertTrue(settings.isNeutral)
        XCTAssertEqual(try settings.encoded(), #"{"schemaVersion":3}"#)

        settings[.gradeShadowsHue] = 220
        settings[.hsl(.luminance, .orange)] = -30
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        XCTAssertEqual(DevelopSettings.Parameter.hsl(.luminance, .orange).panel, .hsl)
        XCTAssertEqual(DevelopSettings.Parameter.gradeShadowsHue.panel, .colorGrading)
        XCTAssertEqual(DevelopSettings.Panel.hsl.parameters.filter { $0.hslBand != nil }.count, 24)
        XCTAssertEqual(DevelopSettings.Panel.hsl.parameters.filter { $0.grayBand != nil }.count, 8)
    }

    func testRegionCurveLiftsShadows() {
        var settings = DevelopSettings()
        settings[.curveShadows] = 100
        XCTAssertGreaterThan(DevelopRenderer.toneCurveValue(settings, at: 0.125), 0.2)
        XCTAssertEqual(DevelopRenderer.toneCurveValue(settings, at: 0.9), 0.9, accuracy: 0.001)
        XCTAssertNotNil(DevelopRenderer.masterCurveLUT(settings))
        XCTAssertNil(DevelopRenderer.masterCurveLUT(.neutral))
        XCTAssertNil(DevelopRenderer.channelCurvesLUT(settings))
    }

    func testPointCurves() throws {
        typealias Point = DevelopSettings.CurvePoint
        var settings = DevelopSettings()
        settings.setPoints(Point.identity, for: .rgb)
        XCTAssertEqual(settings, .neutral, "a straight line is not stored")

        settings.setPoints([Point(x: 0, y: 0), Point(x: 0.5, y: 0.3), Point(x: 0.5001, y: 0.9), Point(x: 1, y: 1)], for: .rgb)
        XCTAssertEqual(settings.points(for: .rgb).count, 3, "points too close together collapse")
        settings.setPoints([Point(x: 0, y: 0.2), Point(x: 1, y: 1)], for: .blue)
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.hasPointCurve)

        // Sample 5 is x = 0.5: the RGB curve darkens it; the blue curve lifts blue alone.
        let master = try XCTUnwrap(DevelopRenderer.masterCurveLUT(settings, samples: 11))
        XCTAssertEqual(Double(master[5]), 0.3, accuracy: 0.01)
        let channels = try XCTUnwrap(DevelopRenderer.channelCurvesLUT(settings, samples: 11))
        XCTAssertEqual(Double(channels[15]), 0.5, accuracy: 0.001, "red is a straight line")
        XCTAssertEqual(channels[15], channels[16])
        XCTAssertGreaterThan(channels[17], channels[15])
    }

    func testHSLWeightsAndGrays() {
        for hue in stride(from: 0.0, to: 360, by: 7.5) {
            XCTAssertEqual(HSLAdjustment.weights(for: hue).reduce(0, +), 1, accuracy: 1e-9)
        }
        var settings = DevelopSettings()
        for band in DevelopSettings.ColorBand.allCases { settings[.hsl(.saturation, band)] = -100 }
        let hsl = HSLAdjustment(settings)
        let gray = hsl.apply((0.4, 0.4, 0.4))
        // Oklab round trips include Float-precision matrix coefficients.
        for channel in [gray.0, gray.1, gray.2] {
            XCTAssertEqual(channel, 0.4, accuracy: 1e-7)
        }
        let red = hsl.apply((0.8, 0.2, 0.2))
        XCTAssertEqual(red.0, red.1, accuracy: 0.01, "fully desaturated")
    }

    func testHSLAndColorGradingRender() throws {
        let file = workDir.appendingPathComponent("red.jpg")
        try makeJPEG(at: file, color: [0.8, 0.2, 0.2])
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 32))

        var desaturate = DevelopSettings()
        desaturate[.hsl(.saturation, .red)] = -100
        let gray = try pixel(XCTUnwrap(session.render(desaturate)))
        XCTAssertLessThan(abs(gray.0 - gray.1), 0.08, "red band desaturated: \(gray)")

        let darkFile = workDir.appendingPathComponent("dark.jpg")
        try makeJPEG(at: darkFile, color: [0.15, 0.15, 0.15])
        let dark = try XCTUnwrap(DevelopRenderer.shared.session(for: darkFile, maxPixelSize: 32))
        var grade = DevelopSettings()
        grade[.gradeShadowsHue] = 240
        grade[.gradeShadowsSat] = 100
        let tinted = try pixel(XCTUnwrap(dark.render(grade)))
        XCTAssertGreaterThan(tinted.2, tinted.0 + 0.03, "shadows tinted blue: \(tinted)")
    }

    /// Contrast moves an orange's brightness and saturation but keeps its hue, as in Lightroom;
    /// a per-channel curve would turn it redder.
    func testContrastKeepsHue() throws {
        XCTAssertTrue(ToneCurve.kernelAvailable)
        let file = workDir.appendingPathComponent("orange.jpg")
        try makeJPEG(at: file, color: [0.85, 0.5, 0.2])
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 32))
        let before = try pixel(XCTUnwrap(session.render(.neutral)))
        var settings = DevelopSettings()
        settings.contrast = 100
        settings.whites = 40
        settings.blacks = -40
        let after = try pixel(XCTUnwrap(session.render(settings)))
        XCTAssertNotEqual(after.0, before.0, accuracy: 0.005, "contrast changed the color")
        XCTAssertEqual(hue(after), hue(before), accuracy: 3, "before \(before), after \(after)")

        let grayFile = workDir.appendingPathComponent("gray.jpg")
        try makeJPEG(at: grayFile, color: [0.6, 0.6, 0.6])
        let gray = try pixel(XCTUnwrap(XCTUnwrap(DevelopRenderer.shared.session(for: grayFile, maxPixelSize: 32))
            .render(settings)))
        XCTAssertEqual(gray.0, gray.1, accuracy: 0.01, "gray stays gray")
        XCTAssertEqual(gray.1, gray.2, accuracy: 0.01, "gray stays gray")
    }

    private func hue(_ c: (Double, Double, Double)) -> Double {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2), d = high - low
        guard d > 0 else { return 0 }
        var h: Double
        if high == c.0 { h = (c.1 - c.2) / d } else if high == c.1 { h = 2 + (c.2 - c.0) / d } else { h = 4 + (c.0 - c.1) / d }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    // MARK: Helpers

    private func pixel(_ image: CGImage) throws -> (Double, Double, Double) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    private func makeJPEG(at url: URL, color: [CGFloat]) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: color + [1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
