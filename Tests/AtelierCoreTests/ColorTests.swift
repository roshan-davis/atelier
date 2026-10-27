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
        XCTAssertEqual(DevelopSettings.Panel.hsl.parameters.count, 24)
    }

    func testRegionCurveLiftsShadows() {
        var settings = DevelopSettings()
        settings[.curveShadows] = 100
        XCTAssertGreaterThan(DevelopRenderer.toneCurveValue(settings, at: 0.125), 0.2)
        XCTAssertEqual(DevelopRenderer.toneCurveValue(settings, at: 0.9), 0.9, accuracy: 0.001)
        XCTAssertNotNil(DevelopRenderer.toneCurveLUT(settings))
        XCTAssertNil(DevelopRenderer.toneCurveLUT(.neutral))
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

        let lut = try XCTUnwrap(DevelopRenderer.toneCurveLUT(settings, samples: 11))
        // Sample 5 is x = 0.5: the RGB curve darkens it; blue is lifted on top.
        XCTAssertEqual(Double(lut[15]), 0.3, accuracy: 0.01)
        XCTAssertGreaterThan(lut[17], lut[15])
        XCTAssertEqual(lut[15], lut[16])
    }

    func testHSLWeightsAndGrays() {
        for hue in stride(from: 0.0, to: 360, by: 7.5) {
            XCTAssertEqual(HSLAdjustment.weights(for: hue).reduce(0, +), 1, accuracy: 1e-9)
        }
        var settings = DevelopSettings()
        for band in DevelopSettings.ColorBand.allCases { settings[.hsl(.saturation, band)] = -100 }
        let hsl = HSLAdjustment(settings)
        let gray = hsl.apply((0.4, 0.4, 0.4))
        XCTAssertEqual(gray.0, 0.4, accuracy: 1e-9)
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
