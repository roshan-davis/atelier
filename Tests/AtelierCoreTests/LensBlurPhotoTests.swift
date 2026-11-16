import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Lens Blur's Save (AT-074): one TIFF stacked on the original, replaced in place on later saves.
final class LensBlurPhotoTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierLensBlurPhoto-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testSavingStacksOneTIFFAndSavingAgainReplacesIt() async throws {
        try makeJPEG(at: workDir.appendingPathComponent("Portrait.jpg"))
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let result = await importer.run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        let source = try XCTUnwrap(result.assetIDsBySource.values.first)
        var settings = DevelopSettings.neutral
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 40
        try catalog.saveDevelopSettings(settings, for: source)

        let first = try LensBlurPhoto.save(source, catalog: catalog, importer: importer)
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.url.lastPathComponent, "Portrait-LensBlur.tif")
        XCTAssertEqual(try LensBlurPhoto.source(of: first.id, catalog: catalog), source)
        XCTAssertNil(try LensBlurPhoto.source(of: source, catalog: catalog))
        let version = try XCTUnwrap(LensBlurPhoto.version(of: source, catalog: catalog))
        XCTAssertEqual(version.derivedAssetId, first.id)
        XCTAssertEqual(LensBlurPhoto.madeFrom(version), settings)

        // The TIFF's own edit survives a later save of the original's Lens Blur.
        var tiffEdit = DevelopSettings.neutral
        tiffEdit[.exposure] = 0.5
        try catalog.saveDevelopSettings(tiffEdit, for: first.id)
        settings[.lensBlurAmount] = 80
        try catalog.saveDevelopSettings(settings, for: source)

        let second = try LensBlurPhoto.save(source, catalog: catalog, importer: importer)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(LensBlurPhoto.madeFrom(try XCTUnwrap(LensBlurPhoto.version(of: source, catalog: catalog))), settings)
        XCTAssertEqual(try catalog.developSettings(for: first.id)[.exposure], 0.5)
        // No leftover temporary file next to it.
        let tiffs = try FileManager.default.contentsOfDirectory(atPath: workDir.path).filter { $0.hasSuffix(".tif") }
        XCTAssertEqual(tiffs, ["Portrait-LensBlur.tif"])
    }

    /// Outside the Lens Blur mode a photo's Lens Blur settings render nothing.
    func testSessionsLeaveLensBlurOutUnlessAsked() throws {
        let url = workDir.appendingPathComponent("Plain.jpg")
        try makeJPEG(at: url)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: nil))
        XCTAssertFalse(session.rendersLensBlur)
        session.rendersLensBlur = true
        XCTAssertTrue(session.rendersLensBlur)
    }

    private func makeJPEG(at url: URL, width: Int = 120, height: Int = 80) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
