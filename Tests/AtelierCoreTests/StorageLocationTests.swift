import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079a: storage locations the user adds. Nothing is seeded, old catalogs keep every photo
/// linked, and a location never rebases a stored folder path (Codex review of PR #178).
final class StorageLocationTests: XCTestCase {
    private func share(_ mount: String, uuid: String = "SHARE-1") -> MountedVolume {
        MountedVolume(identityKey: "uuid:" + uuid, name: "Photos", kind: .nas,
                      rootURL: URL(fileURLWithPath: mount, isDirectory: true),
                      serverAddress: "smb://megham.local/Photos")
    }

    /// Adds a photo at `folderPath/filename` on the volume, as an import would have.
    @discardableResult
    private func catalogPhoto(_ catalog: Catalog, on mounted: MountedVolume, folderPath: String,
                              filename: String = "DSC_1.NEF") throws -> Int64 {
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
                VALUES (?, ?, 100, ?, ?)
                """, arguments: [folderId, filename, UUID().uuidString, Date()])
            let assetId = db.lastInsertedRowID
            try AssetMetadata(assetId: assetId).insert(db)
            return assetId
        }
    }

    func testFreshCatalogHasNoLocation() throws {
        XCTAssertEqual(try Catalog().storageLocations(), [])
    }

    func testOldCatalogGetsOneLocationPerVolumeWithItsName() throws {
        let queue = try DatabaseQueue()
        try Catalog.migrator.migrate(queue, upTo: "v11-note-spots")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO volume (identityKey, name, kind, isOnline) VALUES
                ('uuid:AAA', 'Photos SSD', 'local', 1),
                ('net:smb://rosh:secret@megham.local/Photos', 'megham', 'nas', 0)
                """)
        }
        try Catalog.migrator.migrate(queue)
        let locations = try queue.read { db in try StorageLocation.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(locations.map(\.name), ["Photos SSD", "megham"])
        XCTAssertEqual(locations.map(\.kind), [.drive, .networkShare])
        XCTAssertEqual(locations.map(\.rootPath), ["", ""])
        XCTAssertEqual(locations.map(\.volumeId), [1, 2])
        // The password in the old identity key never reaches the location.
        XCTAssertEqual(locations[1].serverAddress, "smb://megham.local/Photos")
        XCTAssertFalse(locations.contains { ($0.serverAddress ?? "").contains("secret") })
    }

    /// The Codex P1 case: adding /Volumes/Photos/Portfolio when Portfolio/2026 is cataloged must not
    /// make the photo resolve to Portfolio/Portfolio/2026, and a remount elsewhere keeps it linked.
    func testSubfolderLocationKeepsExistingPathsAndSurvivesRemount() throws {
        let catalog = try Catalog()
        let mounted = share("/Volumes/Photos")
        let photo = try catalogPhoto(catalog, on: mounted, folderPath: "Portfolio/2026")
        try catalog.refreshVolumes(mounted: [mounted])
        let before = try catalog.fileURL(for: photo)
        XCTAssertEqual(before?.path, "/Volumes/Photos/Portfolio/2026/DSC_1.NEF")

        let location = try catalog.addStorageLocation(
            folder: URL(fileURLWithPath: "/Volumes/Photos/Portfolio", isDirectory: true), on: mounted)
        XCTAssertEqual(location.rootPath, "Portfolio")
        XCTAssertEqual(location.name, "Portfolio")
        XCTAssertEqual(try catalog.fileURL(for: photo), before)
        let folders = try catalog.writer.read { db in try String.fetchAll(db, sql: "SELECT relativePath FROM folder") }
        XCTAssertEqual(folders, ["Portfolio/2026"])

        // Mounted again as /Volumes/Photos-1: same volume identity, same photo.
        try catalog.refreshVolumes(mounted: [share("/Volumes/Photos-1")])
        XCTAssertEqual(try catalog.fileURL(for: photo)?.path, "/Volumes/Photos-1/Portfolio/2026/DSC_1.NEF")
        let info = try XCTUnwrap(try catalog.storageLocations().first { $0.location.rootPath == "Portfolio" })
        XCTAssertEqual(info.rootURL?.path, "/Volumes/Photos-1/Portfolio")
        XCTAssertEqual(info.photoCount, 1)
        XCTAssertEqual(info.status, .connected)

        // Offline: the photo has no file URL but stays in the catalog.
        try catalog.refreshVolumes(mounted: [])
        XCTAssertNil(try catalog.fileURL(for: photo))
        XCTAssertEqual(try catalog.storageLocations().first?.status, .offline)
    }

    func testAddingTheSamePlaceTwiceKeepsOneLocation() throws {
        let catalog = try Catalog()
        let mounted = share("/Volumes/Photos")
        let first = try catalog.addStorageLocation(folder: mounted.rootURL, on: mounted, name: "megham")
        let second = try catalog.addStorageLocation(folder: mounted.rootURL, on: mounted)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try catalog.storageLocations().map(\.location.name), ["megham"])
    }

    func testPhotoCountsOnlyTheLocationsFolder() throws {
        let catalog = try Catalog()
        let mounted = share("/Volumes/Photos")
        try catalogPhoto(catalog, on: mounted, folderPath: "Portfolio")
        try catalogPhoto(catalog, on: mounted, folderPath: "Portfolio/2026")
        try catalogPhoto(catalog, on: mounted, folderPath: "PortfolioOld")
        try catalogPhoto(catalog, on: mounted, folderPath: "Family")
        try catalog.addStorageLocation(folder: mounted.rootURL, on: mounted)
        try catalog.addStorageLocation(folder: mounted.rootURL.appendingPathComponent("Portfolio"), on: mounted)
        let counts = try catalog.storageLocations().map { ($0.location.rootPath, $0.photoCount) }
        XCTAssertEqual(counts.map(\.0), ["", "Portfolio"])
        XCTAssertEqual(counts.map(\.1), [4, 2])
    }

    func testRemovingALocationKeepsItsPhotos() throws {
        let catalog = try Catalog()
        let mounted = share("/Volumes/Photos")
        let photo = try catalogPhoto(catalog, on: mounted, folderPath: "Shoot")
        let location = try catalog.addStorageLocation(folder: mounted.rootURL, on: mounted)
        try catalog.removeStorageLocation(try XCTUnwrap(location.id))
        XCTAssertEqual(try catalog.storageLocations(), [])
        XCTAssertNotNil(try catalog.detail(for: photo))
    }

    func testImportingFromANewVolumeAddsItsLocation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierStorage-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a photo but a file".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        let catalog = try Catalog()
        _ = await Importer(catalog: catalog, previews: nil).run(sources: [dir], options: ImportOptions(buildPreviews: false))
        let volumes = try await catalog.writer.read { db in try Volume.fetchCount(db) }
        let locations = try catalog.storageLocations()
        XCTAssertEqual(locations.count, volumes)
        XCTAssertEqual(locations.first?.location.rootPath, "")
    }

    func testServerAddressesMatchWithoutCredentialsCaseOrDotLocal() {
        XCTAssertEqual(ServerAddress.normalized("smb://rosh:pw@Megham.local/Photos/"), "smb://megham.local/Photos")
        XCTAssertEqual(ServerAddress.normalized("megham.local/Photos"), "smb://megham.local/Photos")
        XCTAssertNil(ServerAddress.normalized("smb://"))
        XCTAssertEqual(ServerAddress.matchKey("smb://megham.local/Photos"), ServerAddress.matchKey("smb://MEGHAM/photos"))
        XCTAssertNotEqual(ServerAddress.matchKey("smb://megham/Photos"), ServerAddress.matchKey("smb://megham/Music"))
        XCTAssertEqual(ServerAddress.display("smb://megham.local/My%20Photos"), "megham.local/My Photos")
    }

    func testShareMountedLaterLinksToItsLocation() throws {
        let catalog = try Catalog()
        try catalog.writer.write { db in
            var pending = StorageLocation(name: "megham", kind: .networkShare, volumeId: nil,
                                          serverAddress: "smb://megham.local/Photos", connectAtLaunch: true)
            try pending.insert(db)
        }
        XCTAssertEqual(try catalog.storageLocations().first?.status, .notConnectedYet)
        var mounted = share("/Volumes/Photos")
        mounted.serverAddress = "smb://rosh@MEGHAM/Photos"
        try catalog.refreshVolumes(mounted: [mounted])
        let info = try XCTUnwrap(try catalog.storageLocations().first)
        XCTAssertEqual(info.status, .connected)
        XCTAssertEqual(info.location.name, "megham")
        XCTAssertEqual(info.detailLine, "Network share · megham.local/Photos")
    }

    /// The sidebar lists locations, not volumes: a share never connected gets its own row, a subfolder
    /// location is named for itself, and a folder shows under the most specific location only.
    func testSidebarGroupsFoldersUnderTheMostSpecificLocation() {
        func info(_ id: Int64, _ name: String, volume: Int64?, root: String = "") -> StorageLocationInfo {
            let location = StorageLocation(id: id, name: name, kind: .drive, volumeId: volume, rootPath: root)
            return StorageLocationInfo(location: location, volume: nil, photoCount: 0)
        }
        func folder(_ id: Int64, _ volume: Int64, _ path: String) -> Folder {
            Folder(id: id, volumeId: volume, relativePath: path)
        }
        let rows = SidebarLocation.make(
            locations: [info(1, "Photos SSD", volume: 7), info(2, "Portfolio", volume: 7, root: "Portfolio"),
                        info(3, "Studio Mac", volume: nil)],
            folders: [folder(10, 7, "Family"), folder(11, 7, "Portfolio"), folder(12, 7, "Portfolio/2026"),
                      folder(13, 7, "PortfolioOld"), folder(14, 8, "Elsewhere")])
        XCTAssertEqual(rows.map(\.info.location.name), ["Photos SSD", "Portfolio", "Studio Mac"])
        XCTAssertEqual(rows[0].folders.map(\.relativePath), ["Family", "PortfolioOld"])
        XCTAssertNil(rows[0].rootFolder)
        XCTAssertEqual(rows[1].rootFolder?.id, 11)
        XCTAssertEqual(rows[1].folders.map(\.relativePath), ["Portfolio/2026"])
        XCTAssertEqual(rows[2].folders, [])
    }
}
