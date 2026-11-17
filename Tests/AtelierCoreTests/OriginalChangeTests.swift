import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079c part 3: a photo on a share whose file changed since import is marked, and commands stop
/// for it (`OriginalChangedError`) until the person picks Use the New File or Use the Kept Copy.
/// A copy used while the share is offline carries a job note.
final class OriginalChangeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierChange-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("share/Trip"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A fresh cache on the same folder: what the next session sees.
    private func cache() throws -> OriginalCache {
        try OriginalCache(root: dir.appendingPathComponent("cache"), limit: 1_000_000, freeSpace: { .max })
    }

    private var file: URL { dir.appendingPathComponent("share/Trip/NZ6_9144.NEF") }

    /// A photo on a share named megham, cataloged with its file's hash.
    private func catalogPhoto() throws -> (Catalog, Int64) {
        try Data(repeating: 1, count: 1000).write(to: file)
        let hash = try FileHasher.sha256(of: file)
        let catalog = try Catalog()
        let id = try catalog.writer.write { db -> Int64 in
            var volume = Volume(id: nil, identityKey: "uuid:SHARE", name: "Photos", kind: .nas,
                                mountPath: dir.appendingPathComponent("share").path, lastSeen: Date(), isOnline: true)
            try volume.insert(db)
            var location = StorageLocation(name: "megham", kind: .networkShare, volumeId: volume.id)
            try location.insert(db)
            try db.execute(sql: "INSERT INTO folder (volumeId, relativePath) VALUES (?, 'Trip')", arguments: [volume.id!])
            try db.execute(sql: """
                INSERT INTO asset (folderId, filename, fileSize, contentHash, importedAt) VALUES (?, 'NZ6_9144.NEF', 1000, ?, ?)
                """, arguments: [db.lastInsertedRowID, hash, Date()])
            let id = db.lastInsertedRowID
            try AssetMetadata(assetId: id).insert(db)
            return id
        }
        return (catalog, id)
    }

    private func changeTheFile() throws {
        try Data(repeating: 2, count: 1200).write(to: file)
    }

    func testAShareOriginalIsReadOnceThroughTheCache() throws {
        let (catalog, id) = try catalogPhoto()
        let cache = try cache()
        let first = try catalog.checkedSource(for: id, cache: cache)
        XCTAssertTrue(first.checked)
        XCTAssertEqual(first.url.deletingLastPathComponent().path, cache.root.path)
        XCTAssertEqual(first.place, "megham")
        XCTAssertEqual(try catalog.checkedSource(for: id, cache: cache).url, first.url)
        XCTAssertNil(first.note(filename: "NZ6_9144.NEF"))
    }

    func testAChangedFileStopsTheCommandAndIsMarked() throws {
        let (catalog, id) = try catalogPhoto()
        try changeTheFile()
        XCTAssertThrowsError(try catalog.checkedSource(for: id, cache: cache())) { error in
            let change = error as? OriginalChangedError
            XCTAssertEqual(change?.filename, "NZ6_9144.NEF")
            XCTAssertEqual(change?.place, "megham")
            XCTAssertEqual(change?.hasKeptCopy, false)
        }
        XCTAssertEqual(try catalog.originalChange(for: id)?.newSize, 1200)
        XCTAssertEqual(try catalog.changedOriginals(among: [id]), [id])
        // Marked: the next command stops at once, without reading the file again.
        XCTAssertThrowsError(try catalog.checkedSource(for: id, cache: cache())) { XCTAssertTrue($0 is OriginalChangedError) }
    }

    func testUseTheKeptCopyRunsFromItAndKeepsTheMark() throws {
        let (catalog, id) = try catalogPhoto()
        let session = try cache()
        let kept = try catalog.checkedSource(for: id, cache: session).url
        try session.setKept([id], true)
        try changeTheFile()

        let later = try cache()
        XCTAssertThrowsError(try catalog.checkedSource(for: id, cache: later)) {
            XCTAssertEqual(($0 as? OriginalChangedError)?.hasKeptCopy, true)
        }
        XCTAssertEqual(try catalog.useKeptCopy(id, cache: later), kept)
        XCTAssertEqual(try catalog.checkedSource(for: id, cache: later).url, kept)
        XCTAssertEqual(try Data(contentsOf: kept), Data(repeating: 1, count: 1000), "the copy from before the change")
        XCTAssertNotNil(try catalog.originalChange(for: id), "still marked")
    }

    func testUseTheNewFileTakesItsHashAndStaysKept() throws {
        let (catalog, id) = try catalogPhoto()
        let session = try cache()
        _ = try catalog.checkedSource(for: id, cache: session)
        try session.setKept([id], true)
        let copy = try catalog.createVirtualCopy(of: id)
        try changeTheFile()
        XCTAssertThrowsError(try catalog.checkedSource(for: copy, cache: cache()))

        let later = try cache()
        let url = try catalog.useNewOriginal(copy, cache: later)
        let newHash = try FileHasher.sha256(of: file)
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 2, count: 1200))
        XCTAssertNil(try catalog.originalChange(for: id))
        XCTAssertEqual(try catalog.detail(for: id)?.asset.contentHash, newHash)
        XCTAssertEqual(try catalog.detail(for: copy)?.asset.contentHash, newHash, "the virtual copy follows")
        XCTAssertEqual(try catalog.detail(for: id)?.asset.fileSize, 1200)
        XCTAssertEqual(try later.entry(for: id)?.pinned, true, "replaced by the new file, still kept")
        XCTAssertEqual(try catalog.checkedSource(for: copy, cache: cache()).url, url)
    }

    func testAnOfflineShareUsesTheCopyWithAJobNote() throws {
        let (catalog, id) = try catalogPhoto()
        _ = try catalog.checkedSource(for: id, cache: cache())
        try catalog.writer.write { db in try db.execute(sql: "UPDATE volume SET isOnline = 0") }
        let source = try catalog.checkedSource(for: id, cache: cache())
        XCTAssertFalse(source.checked)
        let note = try XCTUnwrap(source.note(filename: "NZ6_9144.NEF"))
        XCTAssertTrue(note.contains("megham was offline"), note)
    }
}
