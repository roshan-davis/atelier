import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class AtelierCoreTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Import

    func testReferenceImportCatalogsFilesAndSkipsOnReimport() async throws {
        let shoot = try makeShoot(count: 3)
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)

        let first = await importer.run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(first.total, 3)
        XCTAssertEqual(first.imported, 3)
        XCTAssertTrue(first.failures.isEmpty, "\(first.failures)")

        let second = await importer.run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 3)

        let rows = try catalog.assetRows(filter: LibraryFilter())
        XCTAssertEqual(rows.count, 3)
        let url = try XCTUnwrap(catalog.fileURL(for: rows[0].id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
    }

    func testCopyImportUsesDatedFolderAndVerifiesHash() async throws {
        let shoot = try makeShoot(count: 2)
        let library = workDir.appendingPathComponent("Library", isDirectory: true)
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let options = ImportOptions(mode: .copy(destinationRoot: library, eventName: "Beach"),
                                    keywords: ["test", "Beach"], buildPreviews: false)

        let result = await importer.run(sources: [shoot], options: options)
        XCTAssertEqual(result.imported, 2)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")

        // Test JPEGs carry no EXIF date, so the file modification date (today) names the folder.
        let expected = Importer.destinationDirectory(root: library, date: Date(), eventName: "Beach")
        XCTAssertEqual(expected.lastPathComponent.hasSuffix(" Beach"), true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: expected.path)
        XCTAssertEqual(copied.count, 2)

        let id = try XCTUnwrap(result.importedAssetIDs.first)
        let detail = try XCTUnwrap(catalog.detail(for: id))
        // The resolved path may go through /System/Volumes/Data, so compare folder names, not full paths.
        let fileURL = try XCTUnwrap(detail.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), fileURL.path)
        XCTAssertEqual(fileURL.deletingLastPathComponent().lastPathComponent, expected.lastPathComponent)
        XCTAssertEqual(detail.asset.contentHash, try FileHasher.sha256(of: fileURL))
        XCTAssertEqual(detail.keywords, ["Beach", "test"])

        // Importing the same files again reuses the identical copies.
        let again = await importer.run(sources: [shoot], options: options)
        XCTAssertEqual(again.skipped, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: expected.path).count, 2)
    }

    // MARK: Import entries

    func testEachImportGetsAnEntryAndMoreCanBeAddedToIt() async throws {
        let first = try makeShoot(count: 2)
        let second = try makeShoot(count: 3)
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)

        let a = await importer.run(sources: [first], options: ImportOptions(buildPreviews: false))
        let groupA = try XCTUnwrap(a.importGroupId)
        let b = await importer.run(sources: [second],
                                   options: ImportOptions(target: .newGroup(name: "Studio"), buildPreviews: false))
        let groupB = try XCTUnwrap(b.importGroupId)

        var summaries = try catalog.importGroupSummaries()
        XCTAssertEqual(summaries.map(\.name), ["Studio", first.lastPathComponent])  // newest first
        XCTAssertEqual(summaries.map(\.photoCount), [3, 2])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(groupA))).count, 2)

        // Importing more into an existing entry, including files already cataloged.
        let more = try makeShoot(count: 1)
        _ = await importer.run(sources: [more, first],
                               options: ImportOptions(target: .existingGroup(groupB), buildPreviews: false))
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(groupB))).count, 6)
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter()).count, 6)

        // Rename, remove photos, delete: photos always stay in the catalog.
        try catalog.renameImportGroup(groupB, to: "Studio Week")
        let inB = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(groupB))).map(\.id)
        try catalog.removeAssets(Array(inB.prefix(2)), fromImportGroup: groupB)
        summaries = try catalog.importGroupSummaries()
        XCTAssertEqual(summaries.first { $0.id == groupB }?.name, "Studio Week")
        XCTAssertEqual(summaries.first { $0.id == groupB }?.photoCount, 4)

        try catalog.deleteImportGroup(groupB)
        XCTAssertEqual(try catalog.importGroupSummaries().map(\.id), [groupA])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter()).count, 6)
    }

    // MARK: Editing and filtering

    func testRatingsFlagsLabelsAndFilters() async throws {
        let shoot = try makeShoot(count: 4)
        let catalog = try Catalog()
        _ = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        let ids = try catalog.assetRows(filter: LibraryFilter()).map(\.id)

        try catalog.setRating(4, for: [ids[0], ids[1]])
        try catalog.setRating(9, for: [ids[2]])  // clamped to 5
        try catalog.setFlag(.picked, for: [ids[0]])
        try catalog.setFlag(.rejected, for: [ids[3]])
        try catalog.toggleColorLabel(.red, for: [ids[1]])

        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(minRating: 4)).count, 3)
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(minRating: 5)).map(\.id), [ids[2]])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(flag: .picked)).map(\.id), [ids[0]])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(colorLabel: .red)).map(\.id), [ids[1]])

        try catalog.toggleColorLabel(.red, for: [ids[1]])
        XCTAssertTrue(try catalog.assetRows(filter: LibraryFilter(colorLabel: .red)).isEmpty)

        try catalog.setKeywords(["Fog", "Barn"], for: [ids[3]])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(text: "barn")).map(\.id), [ids[3]])

        let collection = try catalog.createCollection(named: "Portfolio")
        try catalog.addAssets([ids[0], ids[2]], toCollection: collection.id!)
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(scope: .collection(collection.id!))).count, 2)
        try catalog.removeAssets([ids[0]], fromCollection: collection.id!)
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(scope: .collection(collection.id!))).map(\.id), [ids[2]])
    }

    // MARK: XMP

    func testXMPSidecarRoundTripKeepsForeignTags() throws {
        let sidecar = workDir.appendingPathComponent("IMG_0001.xmp")
        let fields = XMPFields(rating: 3, flag: .picked, colorLabel: .green,
                               keywords: ["Watercolor", "Studio"], title: "Morning", caption: "First light")
        try XMPSidecar.write(fields, toSidecar: sidecar)

        let read = try XCTUnwrap(XMPSidecar.read(sidecar: sidecar))
        XCTAssertEqual(read.rating, 3)
        XCTAssertEqual(read.flag, .picked)
        XCTAssertEqual(read.colorLabel, .green)
        XCTAssertEqual(Set(read.keywords), ["Watercolor", "Studio"])
        XCTAssertEqual(read.title, "Morning")
        XCTAssertEqual(read.caption, "First light")

        // Rewriting with fewer fields removes ours but keeps the file valid.
        try XMPSidecar.write(XMPFields(rating: 1), toSidecar: sidecar)
        let rewritten = try XCTUnwrap(XMPSidecar.read(sidecar: sidecar))
        XCTAssertEqual(rewritten.rating, 1)
        XCTAssertNil(rewritten.colorLabel)
        XCTAssertTrue(rewritten.keywords.isEmpty)
    }

    func testCatalogWritesSidecarsAndClearsDirtyFlag() async throws {
        let shoot = try makeShoot(count: 1)
        let catalog = try Catalog()
        _ = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(catalog.assetRows(filter: LibraryFilter()).first?.id)
        try catalog.setRating(5, for: [id])
        XCTAssertTrue(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)

        let result = try catalog.writeXMPSidecars()
        XCTAssertEqual(result.written, 1)
        XCTAssertFalse(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)

        let original = try XCTUnwrap(catalog.fileURL(for: id))
        XCTAssertEqual(XMPSidecar.read(sidecar: XMPSidecar.sidecarURL(for: original))?.rating, 5)
    }

    func testImportReadsExistingSidecar() async throws {
        let shoot = try makeShoot(count: 1)
        let file = try XCTUnwrap(Importer.collectFiles(from: [shoot]).first)
        try XMPSidecar.write(XMPFields(rating: 4, colorLabel: .blue, keywords: ["Lightroom"]),
                             toSidecar: XMPSidecar.sidecarURL(for: file))
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        let detail = try XCTUnwrap(catalog.detail(for: try XCTUnwrap(result.importedAssetIDs.first)))
        XCTAssertEqual(detail.metadata.rating, 4)
        XCTAssertEqual(detail.metadata.colorLabel, .blue)
        XCTAssertEqual(detail.keywords, ["Lightroom"])
    }

    // MARK: Previews

    func testPreviewGeneration() throws {
        let shoot = try makeShoot(count: 1, width: 3000, height: 2000)
        let file = try XCTUnwrap(Importer.collectFiles(from: [shoot]).first)
        let cache = PreviewCache(rootURL: workDir.appendingPathComponent("Previews"))
        try cache.generate(for: 42, from: file)
        XCTAssertTrue(cache.hasPreviews(for: 42))

        let thumb = try XCTUnwrap(CGImageSourceCreateWithURL(cache.url(for: 42, size: .thumbnail) as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 256)
    }

    /// A file that can't be read must not report a finished preview, or the grid asks again at
    /// once and the library refreshes in a loop.
    func testFailedPreviewIsNotReportedOrRetriedUntilAsked() throws {
        let cache = PreviewCache(rootURL: workDir.appendingPathComponent("Previews"))
        let scheduler = PreviewScheduler(cache: cache)
        let reports = Counter()
        scheduler.onFinish { _, _ in reports.increment() }
        let missing = workDir.appendingPathComponent("offline.NEF")

        scheduler.request(.thumbnail, for: 1, source: missing)
        scheduler.waitUntilIdle()
        scheduler.request(.thumbnail, for: 1, source: missing)
        scheduler.waitUntilIdle()
        XCTAssertEqual(reports.value, 0)
        XCTAssertFalse(cache.has(.thumbnail, for: 1))

        // The same photo after its drive came back.
        let file = try makeShoot(count: 1).appendingPathComponent("IMG_0001.jpg")
        scheduler.request(.thumbnail, for: 1, source: file)
        scheduler.waitUntilIdle()
        XCTAssertFalse(cache.has(.thumbnail, for: 1), "a failed preview waits for retryFailed")
        scheduler.retryFailed()
        scheduler.request(.thumbnail, for: 1, source: file)
        scheduler.waitUntilIdle()
        XCTAssertTrue(cache.has(.thumbnail, for: 1))
        XCTAssertEqual(reports.value, 1)
    }

    // MARK: Helpers

    private func makeShoot(count: Int, width: Int = 64, height: Int = 48) throws -> URL {
        let dir = workDir.appendingPathComponent("Shoot-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<count {
            try makeJPEG(at: dir.appendingPathComponent(String(format: "IMG_%04d.jpg", index + 1)),
                         width: width, height: height, shade: Double(index + 1) / Double(count + 1))
        }
        // Not photos: must be ignored.
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent("._IMG_0001.jpg"))
        return dir
    }

    private func makeJPEG(at url: URL, width: Int, height: Int, shade: Double) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
