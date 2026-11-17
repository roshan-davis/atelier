import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079c part 2: Keep on This Mac works out what to read before reading anything, refuses when
/// that would leave less than 10% of the disk free, keeps what is already here at once, and Free Up
/// Space lets the kept copies go. Virtual copies share their master's copy.
final class KeepOnThisMacTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierKeep-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("share/Trip"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("local"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cache(limit: Int64 = 1_000_000) throws -> OriginalCache {
        try OriginalCache(root: dir.appendingPathComponent("cache"), limit: limit, freeSpace: { .max })
    }

    /// A photo file in `folder` of a volume of `kind` mounted at `mount`, cataloged with its hash.
    @discardableResult
    private func photo(_ catalog: Catalog, kind: VolumeKind, mount: String, folder: String, name: String,
                       size: Int = 1000) throws -> Int64 {
        let root = dir.appendingPathComponent(mount)
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(name.count), count: size).write(to: url)
        let hash = try FileHasher.sha256(of: url)
        return try catalog.writer.write { db in
            var volume = try Volume.filter(Column("identityKey") == "uuid:" + mount).fetchOne(db)
                ?? Volume(id: nil, identityKey: "uuid:" + mount, name: mount == "share" ? "megham" : "Mac",
                          kind: kind, mountPath: root.path, lastSeen: Date(), isOnline: true)
            try volume.save(db)
            try db.execute(sql: "INSERT OR IGNORE INTO folder (volumeId, relativePath) VALUES (?, ?)",
                           arguments: [volume.id!, folder])
            let folderId = try Int64.fetchOne(db, sql: "SELECT id FROM folder WHERE volumeId = ? AND relativePath = ?",
                                              arguments: [volume.id!, folder])!
            try db.execute(sql: """
                INSERT INTO asset (folderId, filename, fileSize, contentHash, importedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [folderId, name, size, hash, Date()])
            let id = db.lastInsertedRowID
            try AssetMetadata(assetId: id).insert(db)
            return id
        }
    }

    private func folderID(_ catalog: Catalog, _ path: String) throws -> Int64 {
        try catalog.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM folder WHERE relativePath = ?", arguments: [path])!
        }
    }

    func testTheTenPercentRule() {
        XCTAssertNil(KeepPlan.shortfall(reading: 0, free: 0, capacity: 1000))
        XCTAssertNil(KeepPlan.shortfall(reading: 400, free: 500, capacity: 1000), "leaves exactly 10%")
        XCTAssertEqual(KeepPlan.shortfall(reading: 450, free: 500, capacity: 1000), 50)
        XCTAssertEqual(KeepPlan.shortfall(reading: 900, free: 50, capacity: 1000), 950)
    }

    /// Only the share's photos are counted; a virtual copy is its master; a collection with a
    /// local photo and a share photo keeps only the share one.
    func testShareOriginalsInACollection() throws {
        let catalog = try Catalog()
        let onShare = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "DSC_1.NEF")
        let local = try photo(catalog, kind: .local, mount: "local", folder: "", name: "IMG_2.JPG")
        let copy = try catalog.createVirtualCopy(of: onShare)
        let collection = try catalog.createCollection(named: "Best")
        try catalog.addAssets([copy, local], toCollection: collection.id!)

        let found = try catalog.shareOriginals(in: .collection(collection.id!))
        XCTAssertEqual(found.originals.map(\.assetId), [onShare])
        XCTAssertEqual(found.photoCount, 2)
        XCTAssertEqual(found.originals.first?.volumeName, "megham")
        XCTAssertEqual(found.originals.first?.fileURL?.lastPathComponent, "DSC_1.NEF")
        XCTAssertEqual(try catalog.originalID(for: copy), onShare)
        XCTAssertEqual(try catalog.originalID(for: local), local)
    }

    /// A folder location counts only the folders under its root.
    func testShareOriginalsInAFolderLocation() throws {
        let catalog = try Catalog()
        let inTrip = try photo(catalog, kind: .nas, mount: "share", folder: "Trip/Day 1", name: "a.NEF")
        try photo(catalog, kind: .nas, mount: "share", folder: "Tripping", name: "b.NEF")
        let volumeId = try catalog.writer.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM volume WHERE kind = 'nas'")! }
        let location = try catalog.writer.write { db -> StorageLocation in
            var location = StorageLocation(name: "Trip", kind: .networkShare, volumeId: volumeId, rootPath: "Trip")
            try location.insert(db)
            return location
        }
        XCTAssertEqual(try catalog.shareOriginals(in: .location(location.id!)).originals.map(\.assetId), [inTrip])
        XCTAssertEqual(try catalog.shareOriginals(in: .folder(folderID(catalog, "Tripping"))).originals.count, 1)
    }

    /// The plan reads nothing: copies already here are pinned, missing ones are read, offline ones
    /// are skipped, and the size decides whether it fits.
    func testPlanSplitsWhatIsHereFromWhatMustBeRead() throws {
        let catalog = try Catalog()
        let a = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "a.NEF", size: 1000)
        let b = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "bb.NEF", size: 3000)
        let c = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "ccc.NEF", size: 2000)
        let cache = try cache()
        var originals = try catalog.shareOriginals(in: .folder(folderID(catalog, "Trip"))).originals
        let byID = Dictionary(uniqueKeysWithValues: originals.map { ($0.assetId, $0) })
        try cache.store(a, from: byID[a]!.fileURL!, contentHash: byID[a]!.contentHash)
        try cache.store(c, from: byID[c]!.fileURL!, contentHash: byID[c]!.contentHash, pinned: true)
        originals = originals.map { original in
            var original = original
            if original.assetId == c { original.fileURL = nil } // kept, and its share offline: still kept
            return original
        }

        let plan = try cache.keepPlan(for: originals, photoCount: 3, free: 100_000, capacity: 100_000)
        XCTAssertEqual(plan.toPin, [a])
        XCTAssertEqual(plan.toRead.map(\.assetId), [b])
        XCTAssertEqual(plan.alreadyKept, 1)
        XCTAssertEqual(plan.readBytes, 3000)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.sources, ["megham"])

        let tight = try cache.keepPlan(for: originals, photoCount: 3, free: 12_000, capacity: 100_000)
        XCTAssertEqual(tight.shortBy, 1000)
        XCTAssertFalse(tight.fits)
    }

    func testFreeUpLetsKeptCopiesGoButSparesTheOpenPhoto() throws {
        let catalog = try Catalog()
        let a = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "a.NEF")
        let b = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "bb.NEF")
        let c = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "ccc.NEF")
        let cache = try cache()
        for original in try catalog.shareOriginals(in: .folder(folderID(catalog, "Trip"))).originals {
            try cache.store(original.assetId, from: original.fileURL!, contentHash: original.contentHash,
                            pinned: original.assetId != c)
        }
        XCTAssertEqual(try cache.keptUsage(of: [a, b, c]).count, 2)

        let freed = try cache.freeUp([a, b, c], sparing: b)
        XCTAssertEqual(freed.count, 1)
        XCTAssertEqual(freed.bytes, 1000)
        XCTAssertNil(try cache.entry(for: a), "a kept copy goes")
        XCTAssertEqual(try cache.entry(for: b)?.pinned, false, "the open photo only stops being kept")
        XCTAssertNotNil(try cache.entry(for: c), "an ordinary cached copy is left to the cache size")
        XCTAssertEqual(try cache.usage().keptCount, 0)
    }

    /// A virtual copy opens from its master's copy instead of reading the file again.
    func testVirtualCopyReadsItsMastersCopy() throws {
        let catalog = try Catalog()
        let master = try photo(catalog, kind: .nas, mount: "share", folder: "Trip", name: "a.NEF")
        let copy = try catalog.createVirtualCopy(of: master)
        let cache = try cache()
        let original = try XCTUnwrap(catalog.shareOriginals(in: .folder(folderID(catalog, "Trip"))).originals.first)
        guard case .stored(let stored) = try cache.store(master, from: original.fileURL!, contentHash: original.contentHash) else {
            return XCTFail("not stored")
        }
        XCTAssertEqual(try catalog.readableURL(for: copy, cache: cache), stored)
    }
}
