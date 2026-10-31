import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class ExportPresetTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierExportPresets-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Watermark placement

    func testWatermarkOriginFollowsAnchorAndInset() {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let mark = CGSize(width: 200, height: 50)
        // Inset is a share of the short edge: 0.1 × 500 = 50 px.
        let cases: [(ExportWatermark.Anchor, CGPoint)] = [
            (.topLeft, CGPoint(x: 50, y: 400)),
            (.top, CGPoint(x: 400, y: 400)),
            (.topRight, CGPoint(x: 750, y: 400)),
            (.left, CGPoint(x: 50, y: 225)),
            (.center, CGPoint(x: 400, y: 225)),
            (.right, CGPoint(x: 750, y: 225)),
            (.bottomLeft, CGPoint(x: 50, y: 50)),
            (.bottom, CGPoint(x: 400, y: 50)),
            (.bottomRight, CGPoint(x: 750, y: 50)),
        ]
        for (anchor, expected) in cases {
            XCTAssertEqual(Watermark.origin(markSize: mark, in: extent, anchor: anchor, inset: 0.1), expected, anchor.rawValue)
        }
    }

    func testMarkSizeIsShareOfWidthAndFitsInsideInset() {
        var watermark = ExportWatermark(text: "© Rosh")
        watermark.size = 0.25
        watermark.inset = 0
        XCTAssertEqual(Watermark.markSize(watermark, aspect: 4, photo: CGSize(width: 2048, height: 1365)),
                       CGSize(width: 512, height: 128))
        // A tall logo on a wide photo is limited by the height left inside the inset.
        watermark.size = 0.9
        watermark.inset = 0.05
        let size = Watermark.markSize(watermark, aspect: 0.5, photo: CGSize(width: 1000, height: 500))
        XCTAssertEqual(size.height, 450, accuracy: 0.5)
        XCTAssertEqual(size.width, 225, accuracy: 0.5)
    }

    func testWatermarkScalesWithThePhoto() throws {
        var watermark = ExportWatermark(text: "© 2026 Rosh")
        watermark.shadow = false
        let small = try XCTUnwrap(Watermark.render(watermark, photo: CGSize(width: 1000, height: 600)))
        let large = try XCTUnwrap(Watermark.render(watermark, photo: CGSize(width: 4000, height: 2400)))
        XCTAssertEqual(small.contentSize.width, 200, accuracy: 2)
        XCTAssertEqual(large.contentSize.width / small.contentSize.width, 4, accuracy: 0.05)
    }

    func testBlankTextOrMissingImageDrawsNothing() {
        let photo = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var watermark = ExportWatermark(text: "   ")
        XCTAssertFalse(watermark.hasContent)
        XCTAssertTrue(Watermark.apply(watermark, to: photo) === photo)
        watermark.style = .image
        watermark.imagePath = workDir.appendingPathComponent("missing.png").path
        XCTAssertTrue(Watermark.apply(watermark, to: photo) === photo)
    }

    func testExportDrawsWatermarkInChosenCorner() async throws {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try makeGrayJPEG(at: shoot.appendingPathComponent("IMG_0050.jpg"), width: 400, height: 200)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(result.importedAssetIDs.first)

        var settings = ExportSettings(destination: workDir.appendingPathComponent("Exports", isDirectory: true))
        settings.format = .png
        var watermark = ExportWatermark(text: "WWWW")
        watermark.opacity = 1
        watermark.size = 0.4
        watermark.anchor = .bottomRight
        watermark.shadow = false
        settings.watermark = watermark
        let export = await Exporter(catalog: catalog).run(assetIDs: [id], settings: settings)
        let url = try XCTUnwrap(export.exported.first, "\(export.failures)")
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 400)

        let pixels = try rgba(image)
        func brightest(rows: Range<Int>, columns: Range<Int>) -> UInt8 {
            var best: UInt8 = 0
            for y in rows { for x in columns { best = max(best, pixels[(y * image.width + x) * 4]) } }
            return best
        }
        // Row 0 is the top of the photo.
        XCTAssertGreaterThan(brightest(rows: 100..<200, columns: 200..<400), 220, "white text in the bottom right")
        XCTAssertLessThan(brightest(rows: 0..<100, columns: 0..<200), 120, "top left untouched")
    }

    // MARK: Presets

    func testBuiltInPresetsApplyAndMatch() {
        var settings = ExportSettings(destination: workDir)
        ExportPreset.website.apply(to: &settings)
        XCTAssertEqual(settings.longEdge, 2048)
        XCTAssertEqual(settings.colorSpace, .sRGB)
        XCTAssertEqual(settings.metadata, .allExceptLocation)
        XCTAssertEqual(settings.destination, workDir, "a preset leaves the folder alone")
        XCTAssertTrue(ExportPreset.website.matches(settings))
        XCTAssertFalse(ExportPreset.fullSizeJPEG.matches(settings))

        settings.longEdge = 1600
        XCTAssertFalse(ExportPreset.website.matches(settings), "any change clears the preset")

        // TIFF has no quality, so a leftover JPEG quality doesn't stop it matching.
        ExportPreset.fullSizeTIFF.apply(to: &settings)
        settings.quality = 0.42
        XCTAssertTrue(ExportPreset.fullSizeTIFF.matches(settings))
        XCTAssertTrue(ExportPreset.builtIn.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(ExportPreset.website.summary, "JPEG 85, 2048 px, sRGB, sharpened, no location")
    }

    func testUserPresetCarriesWatermark() {
        var settings = ExportSettings(destination: workDir)
        ExportPreset.website.apply(to: &settings)
        settings.watermark = ExportWatermark(text: "© Rosh")
        let preset = ExportPreset(name: "Website + Watermark", settings: settings)
        XCTAssertFalse(preset.isBuiltIn)
        XCTAssertFalse(ExportPreset.website.matches(settings))
        XCTAssertTrue(preset.matches(settings))

        var other = ExportSettings(destination: workDir)
        preset.apply(to: &other)
        XCTAssertEqual(other.watermark?.text, "© Rosh")
        ExportPreset.website.apply(to: &other)
        XCTAssertNil(other.watermark, "a preset without a watermark turns it off")
    }

    func testPresetStoreSavesReplacesAndDeletes() throws {
        let store = ExportPresetStore(fileURL: workDir.appendingPathComponent("ExportPresets.json"))
        XCTAssertTrue(store.userPresets().isEmpty)
        var settings = ExportSettings(destination: workDir)
        settings.longEdge = 1080
        var instagram = ExportPreset(name: "Instagram", settings: settings)
        try store.save(instagram)
        try store.save(ExportPreset(name: "Archive", settings: ExportSettings(destination: workDir)))
        try store.save(ExportPreset.website)
        XCTAssertEqual(store.userPresets().map(\.name), ["Archive", "Instagram"], "built-ins are never saved; name order")

        instagram.longEdge = 1350
        try store.save(instagram)
        XCTAssertEqual(store.userPresets().count, 2)
        XCTAssertEqual(store.userPresets().first { $0.id == instagram.id }?.longEdge, 1350)

        try store.delete(instagram.id)
        XCTAssertEqual(store.userPresets().map(\.name), ["Archive"])
    }

    func testPresetStoreSkipsUnreadablePresetsAndKeepsUnreadableFile() throws {
        let url = workDir.appendingPathComponent("ExportPresets.json")
        let good = ExportPreset(name: "Good", settings: ExportSettings(destination: workDir))
        let json = "[\(String(data: try JSONEncoder().encode(good), encoding: .utf8)!), {\"name\": \"Broken\"}]"
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = ExportPresetStore(fileURL: url)
        XCTAssertEqual(store.userPresets().map(\.name), ["Good"])

        try "not a preset list".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.save(good))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not a preset list")
    }

    func testSettingsSavedBeforeWatermarksStillLoad() throws {
        var settings = ExportSettings(destination: workDir)
        settings.longEdge = 2048
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "watermark")
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.watermark)
        XCTAssertEqual(decoded.longEdge, 2048)
    }

    // MARK: Helpers

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func makeGrayJPEG(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.3, 0.3, 0.3, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
