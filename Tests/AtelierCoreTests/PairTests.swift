import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class PairTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierPairs-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPairsFilesByNameInAFolder() {
        let folder = URL(fileURLWithPath: "/Shoot"), other = URL(fileURLWithPath: "/Other")
        let files = [folder.appendingPathComponent("DSC_1.NEF"), folder.appendingPathComponent("DSC_1.JPG"),
                     folder.appendingPathComponent("dsc_1.heic"), folder.appendingPathComponent("DSC_2.JPG"),
                     other.appendingPathComponent("DSC_1.JPG"),
                     // Two RAWs with one name aren't a pair.
                     folder.appendingPathComponent("X.NEF"), folder.appendingPathComponent("X.DNG")]
        let pairs = FilePairs.pairs(files)
        XCTAssertEqual(pairs.map(\.primary.lastPathComponent), ["DSC_1.NEF", "DSC_2.JPG", "DSC_1.JPG", "X.NEF", "X.DNG"])
        XCTAssertEqual(pairs[0].siblings.map(\.lastPathComponent), ["DSC_1.JPG", "dsc_1.heic"])
        XCTAssertTrue(pairs.dropFirst().allSatisfy { $0.siblings.isEmpty })
        XCTAssertTrue(FilePairs.isRaw("a.cr3") && FilePairs.isRaw("B.ARW") && !FilePairs.isRaw("c.jpg"))
    }

    func testRawStandsForItsJPEG() async throws {
        // A fake RAW is enough: the catalog only goes by name.
        try makeJPEG(at: workDir.appendingPathComponent("DSC_1.NEF"))
        try makeJPEG(at: workDir.appendingPathComponent("DSC_1.JPG"))
        try makeJPEG(at: workDir.appendingPathComponent("DSC_2.JPG"))
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        let byName = Dictionary(uniqueKeysWithValues: result.assetIDsBySource.map { ($0.key.lastPathComponent, $0.value) })
        let raw = try XCTUnwrap(byName["DSC_1.NEF"], "imported: \(byName.keys.sorted())")
        let jpeg = try XCTUnwrap(byName["DSC_1.JPG"]), single = try XCTUnwrap(byName["DSC_2.JPG"])
        let group = try XCTUnwrap(result.importGroupId)

        let grouped = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(Set(grouped.map(\.id)), [raw, single])
        XCTAssertEqual(grouped.first { $0.id == raw }?.pairedFormats, "JPG")
        XCTAssertNil(grouped.first { $0.id == single }?.pairedFormats)

        let separate = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group), groupsRawPairs: false))
        XCTAssertEqual(Set(separate.map(\.id)), [raw, jpeg, single])
        XCTAssertTrue(separate.allSatisfy { $0.pairedFormats == nil })

        XCTAssertEqual(try catalog.pairSiblings(of: [raw, single]), [jpeg])
        XCTAssertEqual(try catalog.withPairSiblings([raw]), [raw, jpeg])
        try await catalog.writer.read { db in
            XCTAssertEqual(try Catalog.fetchPhotoCount(db, groupingRawPairs: true), 2)
            XCTAssertEqual(try Catalog.fetchPhotoCount(db, groupingRawPairs: false), 3)
            XCTAssertEqual(try Catalog.fetchImportGroupSummaries(db, groupingRawPairs: true).first?.photoCount, 2)
            XCTAssertEqual(try Catalog.fetchImportGroupSummaries(db).first?.photoCount, 3)
        }

        // Culling the RAW decides for its JPEG too, which stays out of the cull group.
        try catalog.applyCull(groups: [[raw, single]], keepers: [single])
        XCTAssertEqual(try catalog.detail(for: jpeg)?.metadata.flag, .rejected)
        XCTAssertEqual(try catalog.cullGroup(of: raw), [raw, single])

        // A virtual copy of the JPEG is a deliberate version and always shows.
        let copy = try catalog.createVirtualCopy(of: jpeg)
        XCTAssertTrue(try catalog.assetRows(filter: LibraryFilter()).contains { $0.id == copy })
    }

    func testPairMigrationFillsInNames() throws {
        let queue = try DatabaseQueue()
        try Catalog.migrator.migrate(queue, upTo: "v6-virtual-copies")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO volume (id, identityKey, name, kind, isOnline) VALUES (1, 'k', 'Disk', 'local', 1)")
            try db.execute(sql: "INSERT INTO folder (id, volumeId, relativePath) VALUES (1, 1, 'Shoot')")
            for (id, name) in [(1, "DSC_1.NEF"), (2, "DSC_1.JPG")] {
                try db.execute(sql: """
                    INSERT INTO asset (id, folderId, filename, fileSize, contentHash, importedAt)
                    VALUES (?, 1, ?, 10, 'h', '2026-10-01 10:00:00')
                    """, arguments: [id, name])
                try db.execute(sql: "INSERT INTO metadata (assetId) VALUES (?)", arguments: [id])
            }
        }
        try Catalog.migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Asset.fetchOne(db, key: 1)?.stem, "dsc_1")
            XCTAssertEqual(try Asset.fetchOne(db, key: 1)?.isRaw, true)
            XCTAssertEqual(try Asset.fetchOne(db, key: 2)?.isRaw, false)
            XCTAssertEqual(try Catalog.fetchAssetRows(db, filter: LibraryFilter()).map(\.id), [1])
        }
    }

    private func makeJPEG(at url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
