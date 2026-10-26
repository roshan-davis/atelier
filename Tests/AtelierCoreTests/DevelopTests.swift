import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class DevelopTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierDevelop-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testSettingsJSONRoundTripAndMissingKeys() throws {
        var settings = DevelopSettings()
        settings.exposure = 1.25
        settings[.contrast] = 30
        settings[.shadows] = 500  // clamped to 100
        settings.temperature = 4800
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.shadows, 100)

        // Documents from older schema versions load with defaults for new fields.
        let old = try DevelopSettings.decoded(from: #"{"schemaVersion":1,"exposure":0.5}"#)
        XCTAssertEqual(old.exposure, 0.5)
        XCTAssertEqual(old.contrast, 0)
        XCTAssertNil(old.temperature)
    }

    func testCatalogStoresSettingsPerPhoto() async throws {
        let file = workDir.appendingPathComponent("IMG_0001.jpg")
        try makeJPEG(at: file, gray: 0.4)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.importedAssetIDs.first)

        XCTAssertEqual(try catalog.developSettings(for: id), .neutral)
        var settings = DevelopSettings()
        settings.exposure = -0.7
        try catalog.saveDevelopSettings(settings, for: id)
        XCTAssertEqual(try catalog.developSettings(for: id).exposure, -0.7)

        settings.vibrance = 20
        try catalog.saveDevelopSettings(settings, for: id)
        XCTAssertEqual(try catalog.developSettings(for: id), settings)
    }

    func testExposureAndContrastChangeTheRender() throws {
        let file = workDir.appendingPathComponent("gray.jpg")
        try makeJPEG(at: file, gray: 0.35)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))

        let neutral = try centerLuma(XCTUnwrap(session.render(.neutral)))
        var brighter = DevelopSettings()
        brighter.exposure = 1
        let bright = try centerLuma(XCTUnwrap(session.render(brighter)))
        var darker = DevelopSettings()
        darker.blacks = -100
        darker.contrast = 100
        let dark = try centerLuma(XCTUnwrap(session.render(darker)))

        XCTAssertGreaterThan(bright, neutral + 0.1, "neutral \(neutral), +1 EV \(bright)")
        XCTAssertLessThan(dark, neutral, "neutral \(neutral), contrast/blacks \(dark)")
    }

    // MARK: Helpers

    private func centerLuma(_ image: CGImage) throws -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let x = image.width / 2, y = image.height / 2
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    private func makeJPEG(at url: URL, gray: Double) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
