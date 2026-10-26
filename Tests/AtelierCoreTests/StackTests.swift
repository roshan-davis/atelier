import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class StackTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierStack-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testEditInResultStacksOnItsOriginal() async throws {
        try makeJPEG(at: workDir.appendingPathComponent("A.jpg"))
        try makeJPEG(at: workDir.appendingPathComponent("B.jpg"))
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let result = await importer.run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        let (a, b) = (result.importedAssetIDs[0], result.importedAssetIDs[1])
        let group = try XCTUnwrap(result.importGroupId)
        try catalog.setRating(4, for: [a])
        try catalog.setKeywords(["harbor"], for: [a])

        var settings = ExportSettings(destination: DerivedFiles.folder(for: workDir.appendingPathComponent("A.jpg")))
        settings.format = .tiff
        settings.colorSpace = .proPhoto
        let file = try Exporter(catalog: catalog).export(a, settings: settings, baseName: "A-Edit")
        XCTAssertEqual(file.lastPathComponent, "A-Edit.tif")

        let edit = try importer.addStacked(file, on: a, kind: .externalEdit, name: "Photoshop")
        // Stacking twice is harmless.
        try importer.addStacked(file, on: a, kind: .externalEdit, name: "Photoshop")

        let rows = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(rows.map(\.id), [a, edit, b])
        XCTAssertEqual(rows[0].stackCount, 1)
        XCTAssertEqual(rows[1].stackParentId, a)
        XCTAssertEqual(rows[1].stackKind, .externalEdit)
        XCTAssertEqual(rows[1].rating, 4)
        XCTAssertEqual(try catalog.detail(for: edit)?.keywords, ["harbor"])
        XCTAssertEqual(try catalog.derivation(of: edit)?.name, "Photoshop")

        // An external editor saves over the file: the catalog picks up the new size.
        try makeJPEG(at: file, width: 40, height: 30)
        try catalog.refreshFileInfo(for: edit)
        XCTAssertEqual(try catalog.detail(for: edit)?.asset.width, 40)
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
