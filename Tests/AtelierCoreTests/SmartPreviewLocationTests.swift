import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079d d2: "Make smart previews for photos here" on a location, and which imported photos
/// get one.
final class SmartPreviewLocationTests: XCTestCase {
    private func volume(_ kind: VolumeKind, uuid: String) -> MountedVolume {
        MountedVolume(identityKey: "uuid:" + uuid, name: "Photos", kind: kind,
                      rootURL: URL(fileURLWithPath: "/Volumes/\(uuid)", isDirectory: true),
                      serverAddress: kind == .nas ? "smb://nas.local/\(uuid)" : nil)
    }

    @discardableResult
    private func photo(_ catalog: Catalog, on mounted: MountedVolume, folderPath: String) throws -> Int64 {
        try catalog.writer.write { db in
            var volume = try Volume.filter(Column("identityKey") == mounted.identityKey).fetchOne(db)
                ?? Volume(id: nil, identityKey: mounted.identityKey, name: mounted.name, kind: mounted.kind,
                          mountPath: mounted.rootURL.path, lastSeen: Date(), isOnline: true)
            try volume.save(db)
            try db.execute(sql: "INSERT OR IGNORE INTO folder (volumeId, relativePath) VALUES (?, ?)",
                           arguments: [volume.id!, folderPath])
            let folderId = try Int64.fetchOne(db, sql: "SELECT id FROM folder WHERE volumeId = ? AND relativePath = ?",
                                              arguments: [volume.id!, folderPath])!
            try db.execute(sql: """
                INSERT INTO asset (folderId, filename, fileSize, contentHash, importedAt)
                VALUES (?, 'DSC_1.NEF', 100, ?, ?)
                """, arguments: [folderId, UUID().uuidString, Date()])
            let id = db.lastInsertedRowID
            try AssetMetadata(assetId: id).insert(db)
            return id
        }
    }

    func testOnByDefaultForSharesAndCloudFoldersOnly() throws {
        XCTAssertTrue(Catalog.makesSmartPreviewsByDefault(.networkShare))
        XCTAssertTrue(Catalog.makesSmartPreviewsByDefault(.cloudFolder))
        XCTAssertFalse(Catalog.makesSmartPreviewsByDefault(.drive))
        XCTAssertFalse(Catalog.makesSmartPreviewsByDefault(.objectStorage))

        let catalog = try Catalog()
        let share = try catalog.addStorageLocation(folder: volume(.nas, uuid: "S").rootURL, on: volume(.nas, uuid: "S"))
        let drive = try catalog.addStorageLocation(folder: volume(.local, uuid: "D").rootURL, on: volume(.local, uuid: "D"))
        XCTAssertTrue(try catalog.makesSmartPreviews(XCTUnwrap(share.id)))
        XCTAssertFalse(try catalog.makesSmartPreviews(XCTUnwrap(drive.id)))
        // The sheet's switch wins over the default, and the detail's switch changes it later.
        let chosen = try catalog.addStorageLocation(folder: volume(.nas, uuid: "T").rootURL, on: volume(.nas, uuid: "T"),
                                                    makesSmartPreviews: false)
        XCTAssertFalse(try catalog.makesSmartPreviews(XCTUnwrap(chosen.id)))
        try catalog.setMakesSmartPreviews(XCTUnwrap(drive.id), true)
        XCTAssertTrue(try catalog.makesSmartPreviews(XCTUnwrap(drive.id)))
    }

    /// Only masters, only in a location that makes them, and a sibling folder isn't inside one.
    func testCandidatesAreMastersInsideALocationThatMakesThem() throws {
        let catalog = try Catalog()
        let share = volume(.nas, uuid: "S"), drive = volume(.local, uuid: "D")
        let inside = try photo(catalog, on: share, folderPath: "Portfolio")
        let deeper = try photo(catalog, on: share, folderPath: "Portfolio/2026")
        let sibling = try photo(catalog, on: share, folderPath: "PortfolioOld")
        let onDrive = try photo(catalog, on: drive, folderPath: "Shoot")
        let copy = try catalog.createVirtualCopy(of: inside)
        try catalog.addStorageLocation(folder: share.rootURL.appendingPathComponent("Portfolio"), on: share)
        try catalog.addStorageLocation(folder: drive.rootURL, on: drive)
        let all = [inside, deeper, sibling, onDrive, copy]
        XCTAssertEqual(Set(try catalog.smartPreviewCandidates(among: all)), [inside, deeper])
        XCTAssertEqual(try catalog.smartPreviewCandidates(among: []), [])
    }

    /// A catalog from before v14: its shares and cloud folders turn it on, other locations don't.
    func testTheMigrationTurnsItOnForExistingShares() throws {
        let catalog = try Catalog()
        let share = try catalog.addStorageLocation(folder: volume(.nas, uuid: "S").rootURL, on: volume(.nas, uuid: "S"))
        let drive = try catalog.addStorageLocation(folder: volume(.local, uuid: "D").rootURL, on: volume(.local, uuid: "D"))
        try catalog.writer.write { db in
            try db.execute(sql: "ALTER TABLE storageLocation DROP COLUMN makesSmartPreviews")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-smart-preview-locations'")
        }
        var migrator = DatabaseMigrator()
        Catalog.registerSmartPreviewLocationMigration(&migrator)
        try migrator.migrate(catalog.writer)
        XCTAssertTrue(try catalog.makesSmartPreviews(XCTUnwrap(share.id)))
        XCTAssertFalse(try catalog.makesSmartPreviews(XCTUnwrap(drive.id)))
    }
}
