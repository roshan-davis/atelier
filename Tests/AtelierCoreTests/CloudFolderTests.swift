import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079b: cloud drive folders are found where the provider apps keep them, named without the
/// account's email, and are their own volumes so photos relink by provider folder, not by disk path.
final class CloudFolderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierCloud-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        for folder in ["Library/CloudStorage/Dropbox", "Library/CloudStorage/GoogleDrive-rosh@example.com",
                       "Library/CloudStorage/OneDrive-Personal", "Library/Mobile Documents/com~apple~CloudDocs"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testProvidersAreFoundAndNamedWithoutTheEmail() {
        let providers = CloudFolders.providers(home: home)
        XCTAssertEqual(providers.map(\.name), ["iCloud Drive", "Dropbox", "Google Drive", "OneDrive (Personal)"])
        XCTAssertEqual(providers.map(\.identityKey), ["cloud:iCloudDrive", "cloud:Dropbox",
                                                      "cloud:GoogleDrive-rosh@example.com", "cloud:OneDrive-Personal"])
        XCTAssertTrue(providers.allSatisfy { $0.kind == .cloud && $0.serverAddress == nil })
        XCTAssertFalse(providers.map(\.name).joined().contains("@"))
    }

    func testNoProvidersOnAMacWithoutThem() throws {
        let empty = home.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(CloudFolders.providers(home: empty), [])
    }

    func testAFileIsOnTheProviderThatHoldsIt() {
        let providers = CloudFolders.providers(home: home)
        let photo = home.appendingPathComponent("Library/CloudStorage/Dropbox/Shoots/2026/DSC_1.NEF")
        let found = CloudFolders.provider(containing: photo, in: providers)
        XCTAssertEqual(found?.name, "Dropbox")
        XCTAssertEqual(VolumeIdentity.relativePath(of: photo.deletingLastPathComponent(), inVolumeAt: found!.rootURL),
                       "Shoots/2026")
        // A sibling folder whose name starts the same is not inside it.
        XCTAssertNil(CloudFolders.provider(containing: home.appendingPathComponent("Library/CloudStorage/DropboxOld/a.jpg"),
                                           in: providers))
        XCTAssertNil(CloudFolders.provider(containing: home.appendingPathComponent("Pictures/a.jpg"), in: providers))
    }

    func testCloudFolderLocationKeepsPathsRelativeToTheProvider() throws {
        let catalog = try Catalog()
        let dropbox = try XCTUnwrap(CloudFolders.providers(home: home).first { $0.name == "Dropbox" })
        let folder = dropbox.rootURL.appendingPathComponent("Shoots", isDirectory: true)
        let location = try catalog.addStorageLocation(folder: folder, on: dropbox)
        XCTAssertEqual(location.kind, .cloudFolder)
        XCTAssertEqual(location.rootPath, "Shoots")
        XCTAssertNil(location.serverAddress)
        let info = try XCTUnwrap(try catalog.storageLocations().first)
        XCTAssertEqual(info.detailLine, "Cloud drive folder · Dropbox/Shoots")

        // Signed in again on a new Mac: same provider folder name, another home.
        var moved = dropbox
        moved.rootURL = URL(fileURLWithPath: "/Users/other/Library/CloudStorage/Dropbox", isDirectory: true)
        try catalog.refreshVolumes(mounted: [moved])
        XCTAssertEqual(try catalog.storageLocations().first?.rootURL?.path,
                       "/Users/other/Library/CloudStorage/Dropbox/Shoots")
    }

    func testVolumeKindsMapToLocationKinds() {
        XCTAssertEqual(StorageLocationKind(.local), .drive)
        XCTAssertEqual(StorageLocationKind(.nas), .networkShare)
        XCTAssertEqual(StorageLocationKind(.cloud), .cloudFolder)
    }

    func testALocalFileNeedsNoDownload() throws {
        let file = home.appendingPathComponent("a.jpg")
        try Data(repeating: 1, count: 1000).write(to: file)
        XCTAssertFalse(CloudFiles.needsDownload(file))
        let size = CloudFiles.downloadSize(of: [file])
        XCTAssertEqual(size.files, 0)
        XCTAssertEqual(size.bytes, 0)
    }

    func testNamesForProviderFolders() {
        XCTAssertEqual(CloudFolders.displayName(forFolder: "Box-Box"), "Box")
        XCTAssertEqual(CloudFolders.displayName(forFolder: "SynologyDrive-megham"), "Synology Drive (megham)")
        XCTAssertEqual(CloudFolders.displayName(forFolder: "Dropbox"), "Dropbox")
        XCTAssertEqual(CloudFolders.displayName(forFolder: "SomeNewCloud-x@y.z"), "SomeNewCloud")
    }

    /// Grid rows know the original's path in a cloud folder, and whether it still has to be
    /// downloaded; photos elsewhere skip the check.
    func testRowsInACloudFolderCarryTheirPath() throws {
        let catalog = try Catalog()
        let dropbox = try XCTUnwrap(CloudFolders.providers(home: home).first { $0.name == "Dropbox" })
        let shoot = dropbox.rootURL.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: shoot.appendingPathComponent("a.jpg"))
        try catalog.writer.write { db in
            var volume = Volume(id: nil, identityKey: dropbox.identityKey, name: dropbox.name, kind: .cloud,
                                mountPath: dropbox.rootURL.path, lastSeen: Date(), isOnline: true)
            try volume.save(db)
            try db.execute(sql: "INSERT INTO folder (volumeId, relativePath) VALUES (?, 'Shoot')", arguments: [volume.id!])
            try db.execute(sql: """
                INSERT INTO asset (folderId, filename, fileSize, contentHash, importedAt)
                VALUES (?, 'a.jpg', 100, 'h', ?)
                """, arguments: [db.lastInsertedRowID, Date()])
            try db.execute(sql: "INSERT INTO metadata (assetId) VALUES (?)", arguments: [db.lastInsertedRowID])
        }
        let row = try XCTUnwrap(try catalog.assetRows(filter: LibraryFilter()).first)
        XCTAssertEqual(row.cloudPath, shoot.appendingPathComponent("a.jpg").path)
        XCTAssertFalse(row.notDownloaded)
    }
}
