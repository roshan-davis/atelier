import CoreGraphics
import Foundation
import GRDB
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
        // Concurrent imports finish out of filename order. Test stacking relative to
        // the catalog's actual chronological order, not worker completion IDs.
        try await catalog.writer.write { db in
            for (url, id) in result.assetIDsBySource {
                let offset = url.lastPathComponent == "A.jpg" ? 0.0 : 1.0
                try db.execute(sql: "UPDATE asset SET captureTime = ? WHERE id = ?",
                               arguments: [Date(timeIntervalSince1970: offset), id])
            }
        }
        let ordered = try catalog.assetRows(filter: LibraryFilter()).map(\.id)
        let (a, b) = (ordered[0], ordered[1])
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

    func testCullGroupsKeepTheRejectsForReview() async throws {
        for name in ["A", "B", "C"] { try makeJPEG(at: workDir.appendingPathComponent("\(name).jpg")) }
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        let group = try XCTUnwrap(result.importGroupId)
        // Give the synthetic shoot explicit capture times; import workers are concurrent.
        let ids = try ["A.jpg", "B.jpg", "C.jpg"].map {
            try XCTUnwrap(result.assetIDsBySource[workDir.appendingPathComponent($0)])
        }
        try await catalog.writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE asset SET captureTime = ? WHERE id = ?",
                               arguments: [Date(timeIntervalSince1970: Double(index)), id])
            }
        }
        XCTAssertEqual(result.assetIDsBySource.count, 3)
        // C was culled out before import, so it is not in the entry.
        try catalog.removeAssets([ids[2]], fromImportGroup: group)
        try catalog.applyCull(groups: [ids], keepers: [ids[0]])
        XCTAssertEqual(try catalog.cullGroup(of: ids[2]), ids)

        var rows = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(rows.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(rows.map(\.flag), [.picked, .rejected])
        XCTAssertEqual(rows.first?.cullGroupSize, 3)

        // Re-review: C wins after all and joins the entry.
        try catalog.applyCull(groups: [ids], keepers: [ids[2]])
        rows = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(rows.map(\.id), ids)
        XCTAssertEqual(rows.map(\.flag), [.rejected, .rejected, .picked])
    }

    func testVirtualCopiesHaveTheirOwnSettings() async throws {
        try makeJPEG(at: workDir.appendingPathComponent("A.jpg"))
        try makeJPEG(at: workDir.appendingPathComponent("B.jpg"))
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let result = await importer.run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        // Concurrent imports finish out of filename order. Test stacking relative to
        // the catalog's actual chronological order, not worker completion IDs.
        try await catalog.writer.write { db in
            for (url, id) in result.assetIDsBySource {
                let offset = url.lastPathComponent == "A.jpg" ? 0.0 : 1.0
                try db.execute(sql: "UPDATE asset SET captureTime = ? WHERE id = ?",
                               arguments: [Date(timeIntervalSince1970: offset), id])
            }
        }
        let ordered = try catalog.assetRows(filter: LibraryFilter()).map(\.id)
        let (a, b) = (ordered[0], ordered[1])
        let group = try XCTUnwrap(result.importGroupId)
        try catalog.setRating(3, for: [a])
        try catalog.setKeywords(["harbor"], for: [a])
        var warm = DevelopSettings.neutral
        warm.temperature = 7200
        try catalog.saveDevelopSettings(warm, for: a)

        let copy1 = try catalog.createVirtualCopy(of: a)
        // A copy of a copy stacks on the same master.
        let copy2 = try catalog.createVirtualCopy(of: copy1)
        XCTAssertEqual(try catalog.fileURL(for: copy1), try catalog.fileURL(for: a))
        XCTAssertEqual(try catalog.developSettings(for: copy1).temperature, 7200)
        XCTAssertEqual(try catalog.developHistory(for: copy1).steps.map(\.name), ["Virtual Copy"])
        XCTAssertEqual(try catalog.detail(for: copy2)?.keywords, ["harbor"])
        XCTAssertEqual(try catalog.virtualCopyName(of: copy2), "Copy 2")

        // Editing a copy leaves the master alone.
        var cool = warm
        cool.temperature = 4000
        try catalog.saveDevelopSettings(cool, for: copy1)
        XCTAssertEqual(try catalog.developSettings(for: a).temperature, 7200)

        var rows = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(rows.map(\.id), [a, copy1, copy2, b])
        XCTAssertEqual(rows[0].stackCount, 2)
        XCTAssertEqual(rows[1].stackKind, .virtualCopy)
        XCTAssertEqual(rows[1].stackName, "Copy 1")
        XCTAssertEqual(rows[2].rating, 3)

        // Importing the folder again doesn't mistake the copies for the file.
        let again = await importer.run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(Set(again.assetIDsBySource.values), [a, b])

        // A copy exports under its own name; the master's sidecar isn't written for it.
        let export = try Exporter(catalog: catalog).export(copy1, settings: ExportSettings(destination: workDir))
        XCTAssertEqual(export.lastPathComponent, "A-Copy1.jpg")
        try catalog.setRating(5, for: [copy1])
        let xmp = try catalog.writeXMPSidecars(for: [copy1])
        XCTAssertEqual(xmp.written, 0)

        // Removing copies never touches the master; the freed name is reused.
        XCTAssertEqual(try catalog.removeVirtualCopies([a, copy1]), 1)
        XCTAssertNotNil(try catalog.detail(for: a))
        XCTAssertEqual(try catalog.virtualCopyName(of: try catalog.createVirtualCopy(of: a)), "Copy 1")
        rows = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(group)))
        XCTAssertEqual(rows.count, 4)
    }

    func testVirtualCopyMigrationKeepsExistingPhotos() throws {
        let queue = try DatabaseQueue()
        try Catalog.migrator.migrate(queue, upTo: "v5-cull")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO volume (id, identityKey, name, kind, isOnline) VALUES (1, 'k', 'Disk', 'local', 1)")
            try db.execute(sql: "INSERT INTO folder (id, volumeId, relativePath) VALUES (1, 1, 'Shoot')")
            try db.execute(sql: """
                INSERT INTO asset (id, folderId, filename, fileSize, contentHash, importedAt)
                VALUES (7, 1, 'A.jpg', 10, 'h', '2026-10-01 10:00:00')
                """)
            try db.execute(sql: "INSERT INTO metadata (assetId, rating) VALUES (7, 4)")
            try db.execute(sql: "INSERT INTO importGroup (id, name, createdAt) VALUES (1, 'Shoot', '2026-10-01 10:00:00')")
            try db.execute(sql: "INSERT INTO importGroupAsset (importGroupId, assetId) VALUES (1, 7)")
        }
        try Catalog.migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Asset.fetchOne(db, key: 7)?.filename, "A.jpg")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rating FROM metadata WHERE assetId = 7"), 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM importGroupAsset"), 1)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        // The master stays unique per file.
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: """
                INSERT INTO asset (folderId, filename, fileSize, contentHash, importedAt)
                VALUES (1, 'A.jpg', 10, 'h', '2026-10-02 10:00:00')
                """)
        })
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
