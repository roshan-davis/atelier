import CoreGraphics
import CoreImage
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

    /// Outside the Lens Blur mode a photo's Lens Blur settings render nothing: export, previews
    /// and Develop leave it out; only an export (or session) that asks for it blurs. A stand-in
    /// depth model puts everything far away, so Lens Blur at 100 blurs the whole photo.
    func testOnlyWhatAsksForLensBlurRendersIt() async throws {
        DepthMap.standIn = { image in
            let width = max(1, image.width / 8), height = max(1, image.height / 8)
            return DepthMap.Field(width: width, height: height, values: Array(repeating: 1, count: width * height))
        }
        defer { DepthMap.standIn = nil }
        let url = workDir.appendingPathComponent("Checks.png")
        let squares = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 4, "inputSharpness": 1,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        try CIContext().writePNGRepresentation(of: squares, to: url, format: .RGBA8, colorSpace: DevelopRenderer.sRGB)
        var settings = DevelopSettings.neutral
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100

        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: nil))
        XCTAssertFalse(session.rendersLensBlur, "Off by default")
        let plain = try XCTUnwrap(session.render(settings))
        XCTAssertGreaterThan(Self.contrast(of: plain), 0.15, "A session that didn't ask blurred the photo")
        session.rendersLensBlur = true
        let blurred = try XCTUnwrap(session.render(settings))
        XCTAssertLessThan(Self.contrast(of: blurred), 0.05, "Lens Blur didn't render when asked")
        session.rendersLensBlur = false
        XCTAssertGreaterThan(Self.contrast(of: try XCTUnwrap(session.render(settings))), 0.15,
                             "The blur stayed after the session stopped rendering it")

        // Export: unblurred unless asked; the Lens Blur photo's Save asks.
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let result = await importer.run(sources: [url], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.assetIDsBySource.values.first)
        try catalog.saveDevelopSettings(settings, for: id)
        var export = ExportSettings(destination: workDir)
        export.format = .tiff
        let normal = try Exporter(catalog: catalog).export(id, settings: export, baseName: "Normal")
        XCTAssertGreaterThan(Self.contrast(of: try Self.load(normal)), 0.15, "A plain export blurred the photo")
        let saved = try LensBlurPhoto.save(id, catalog: catalog, importer: importer)
        XCTAssertLessThan(Self.contrast(of: try Self.load(saved.url)), 0.05, "The Lens Blur photo isn't blurred")
    }

    private static func load(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The mean difference between neighbouring pixels in the middle: about 0.25 for 4 px
    /// black-and-white squares, near 0 once Lens Blur at 100 (13 px) smooths them.
    static func contrast(of image: CGImage) -> Double {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        let x = CGFloat(image.width - size) / 2, y = CGFloat(image.height - size) / 2
        context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var total = 0.0
        for row in 0..<size {
            for column in 1..<size {
                total += abs(Double(data[row * size + column]) - Double(data[row * size + column - 1])) / 255
            }
        }
        return total / Double(size * (size - 1))
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
