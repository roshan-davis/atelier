import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class SliderPreviewTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierSliderPreview-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testSlidersWithOptionViews() {
        XCTAssertEqual(SliderPreview(parameter: .sharpening), .sharpenAmount)
        XCTAssertEqual(SliderPreview(parameter: .sharpenRadius), .sharpenEdges)
        XCTAssertEqual(SliderPreview(parameter: .sharpenDetail), .sharpenEdges)
        XCTAssertEqual(SliderPreview(parameter: .sharpenMasking), .sharpenMask)
        for parameter in [DevelopSettings.Parameter.exposure, .highlights, .whites] {
            XCTAssertEqual(SliderPreview(parameter: parameter), .highlightClipping)
        }
        XCTAssertEqual(SliderPreview(parameter: .shadows), .shadowClipping)
        XCTAssertEqual(SliderPreview(parameter: .blacks), .shadowClipping)
        XCTAssertEqual(SliderPreview(parameter: .gradeMidtonesHue), .fullSaturation(.midtones))
        XCTAssertNil(SliderPreview(parameter: .contrast))
        XCTAssertNil(SliderPreview(parameter: .gradeMidtonesSat))
        XCTAssertTrue(SliderPreview.kernelsAvailable)
    }

    func testClippingViews() throws {
        let white = try session(gray: 1)
        let gray = try session(gray: 0.5)
        let black = try session(gray: 0)
        XCTAssertGreaterThan(try center(white.render(.neutral, preview: .highlightClipping)).luma, 0.95, "clipped white shows white")
        XCTAssertLessThan(try center(gray.render(.neutral, preview: .highlightClipping)).luma, 0.05, "midtones show black")
        XCTAssertGreaterThan(try center(gray.render(.neutral, preview: .shadowClipping)).luma, 0.95, "midtones show white")
        XCTAssertLessThan(try center(black.render(.neutral, preview: .shadowClipping)).luma, 0.05, "clipped black shows black")
        var brighter = DevelopSettings()
        brighter.exposure = 3
        XCTAssertGreaterThan(try center(gray.render(brighter, preview: .highlightClipping)).luma, 0.95, "+3 EV clips")
    }

    func testSharpeningViewsOnAFlatPhoto() throws {
        let gray = try session(gray: 0.5)
        var settings = DevelopSettings()
        settings.sharpening = 80
        XCTAssertEqual(try center(gray.render(settings, preview: .sharpenEdges)).luma, 0.5, accuracy: 0.06,
                       "no edges: mid gray")
        XCTAssertGreaterThan(try center(gray.render(settings, preview: .sharpenMask)).luma, 0.95,
                             "Masking 0 sharpens everywhere")
        settings[.sharpenMasking] = 80
        XCTAssertLessThan(try center(gray.render(settings, preview: .sharpenMask)).luma, 0.05,
                          "flat areas are masked out")
        let amount = try center(gray.render(settings, preview: .sharpenAmount))
        XCTAssertEqual(amount.r, amount.b, accuracy: 0.02)
        for detail in [0.0, 100] {
            settings[.sharpenDetail] = detail
            XCTAssertNotNil(gray.render(settings), "Detail \(detail) renders")
        }
    }

    func testHueViewShowsFullSaturation() throws {
        let gray = try session(gray: 0.5)
        var settings = DevelopSettings()
        settings[.gradeGlobalHue] = 0
        let plain = try center(gray.render(settings, preview: nil))
        XCTAssertEqual(plain.r, plain.b, accuracy: 0.02, "saturation 0 leaves gray")
        let full = try center(gray.render(settings, preview: .fullSaturation(.global)))
        XCTAssertGreaterThan(full.r, full.b + 0.05, "hue 0 at full saturation is red")
    }

    // MARK: Helpers

    private func session(gray: Double) throws -> DevelopSession {
        let file = workDir.appendingPathComponent("gray-\(gray).png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
    }

    private func center(_ image: CGImage?) throws -> (r: Double, g: Double, b: Double, luma: Double) {
        let image = try XCTUnwrap(image)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        return (r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
}
