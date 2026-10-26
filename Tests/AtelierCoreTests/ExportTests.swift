import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class ExportTests: XCTestCase {
    private var workDir: URL!
    private var sourceDir: URL!
    private var exportDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierExport-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        sourceDir = workDir.appendingPathComponent("Shoot", isDirectory: true)
        exportDir = workDir.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testExportAppliesEditsSizeAndMetadataRules() async throws {
        let source = sourceDir.appendingPathComponent("IMG_0042.jpg")
        try makeJPEG(at: source, width: 200, height: 100)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [sourceDir], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.importedAssetIDs.first)

        var develop = DevelopSettings()
        develop.exposure = 1
        try catalog.saveDevelopSettings(develop, for: id)
        try catalog.setTitle("Harbor at dusk", caption: nil, for: id)
        try catalog.setKeywords(["harbor", "boats"], for: [id])

        var settings = ExportSettings(destination: exportDir)
        settings.longEdge = 100
        settings.metadata = .allExceptLocation
        let exporter = Exporter(catalog: catalog)
        let first = await exporter.run(assetIDs: [id], settings: settings)
        XCTAssertTrue(first.failures.isEmpty, "\(first.failures)")
        let url = try XCTUnwrap(first.exported.first)
        XCTAssertEqual(url.lastPathComponent, "IMG_0042.jpg")

        let image = try XCTUnwrap(loadImage(url))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
        XCTAssertGreaterThan(try centerLuma(image), try centerLuma(XCTUnwrap(loadImage(source))) + 0.1,
                             "+1 EV should be applied")

        let properties = try XCTUnwrap(self.properties(url))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], "location should be stripped")
        let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        XCTAssertEqual(Set(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []), ["harbor", "boats"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCObjectName as String] as? String, "Harbor at dusk")

        // A second export never overwrites, and "All metadata" keeps the location.
        settings.metadata = .all
        let second = await exporter.run(assetIDs: [id], settings: settings)
        let secondURL = try XCTUnwrap(second.exported.first)
        XCTAssertEqual(secondURL.lastPathComponent, "IMG_0042 (2).jpg")
        XCTAssertNotNil(try XCTUnwrap(self.properties(secondURL))[kCGImagePropertyGPSDictionary as String])
    }

    func testFullSizeTIFFIsSixteenBit() async throws {
        let source = sourceDir.appendingPathComponent("IMG_0043.jpg")
        try makeJPEG(at: source, width: 120, height: 80)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [sourceDir], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.importedAssetIDs.first)

        var settings = ExportSettings(destination: exportDir)
        settings.format = .tiff
        settings.colorSpace = .adobeRGB
        let export = await Exporter(catalog: catalog).run(assetIDs: [id], settings: settings)
        let url = try XCTUnwrap(export.exported.first, "\(export.failures)")
        XCTAssertEqual(url.pathExtension, "tif")
        let image = try XCTUnwrap(loadImage(url))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.bitsPerComponent, 16)
    }

    func testOfflineOriginalIsReported() async throws {
        let source = sourceDir.appendingPathComponent("IMG_0044.jpg")
        try makeJPEG(at: source, width: 40, height: 40)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [sourceDir], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.importedAssetIDs.first)
        try FileManager.default.removeItem(at: source)

        let export = await Exporter(catalog: catalog).run(assetIDs: [id], settings: ExportSettings(destination: exportDir))
        XCTAssertTrue(export.exported.isEmpty)
        XCTAssertEqual(export.failures.first?.filename, "IMG_0044.jpg")
    }

    // MARK: Helpers

    private func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func properties(_ url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    private func centerLuma(_ image: CGImage) throws -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    private func makeJPEG(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.3, 0.3, 0.3, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 9.97, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 76.28, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
