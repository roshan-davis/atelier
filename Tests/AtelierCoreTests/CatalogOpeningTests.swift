import GRDB

import XCTest
@testable import AtelierCore

final class CatalogOpeningTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Library.atelier")
    }

    @MainActor
    func testDamagedDatabaseIsPreservedAcrossRetries() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let database = url.appendingPathComponent("catalog.sqlite")
        let bytes = Data("This is a damaged catalog, not SQLite.".utf8)
        try bytes.write(to: database)
        let backup = url.appendingPathComponent("Backups/keep.sqlite")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: backup)
        let opening = CatalogOpening(packageURL: url)
        for _ in 0..<2 {
            await opening.open()
            XCTAssertNil(opening.catalog, "No library or quit backup may use a failed catalog")
            XCTAssertNotNil(opening.failureReason)
            XCTAssertFalse(opening.isOpening)
            XCTAssertEqual(try Data(contentsOf: database), bytes)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
        }
    }

    @MainActor
    func testUnavailableLocationCanBeRetriedAfterItBecomesAvailable() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file where a directory is required reliably fails even when tests run as root.
        try Data("blocked".utf8).write(to: url)
        let opening = CatalogOpening(packageURL: url)
        await opening.open()
        XCTAssertNil(opening.catalog)
        XCTAssertNotNil(opening.failureReason)
        XCTAssertEqual(try Data(contentsOf: url), Data("blocked".utf8))
        // Only this test fixture removes the obstruction; the recovery code never does.
        try FileManager.default.removeItem(at: url)
        await opening.open()
        let catalog = try XCTUnwrap(opening.catalog)
        XCTAssertEqual(catalog.packageURL, url)
        XCTAssertNil(opening.failureReason)
        XCTAssertFalse(opening.isOpening)
        await opening.open()
        XCTAssertTrue(opening.catalog === catalog, "An open catalog must not be opened twice")
    }

    @MainActor
    func testEmptyPackageCanFinishAnInterruptedFirstLaunch() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let opening = CatalogOpening(packageURL: url)
        await opening.open()
        XCTAssertNotNil(opening.catalog)
        XCTAssertNil(opening.failureReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path))
    }

    @MainActor
    func testFinderMetadataOnlyPackageCanOpenWithoutChangingMetadata() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let metadata = url.appendingPathComponent(".DS_Store")
        let bytes = Data("Finder metadata fixture".utf8)
        try bytes.write(to: metadata)
        let opening = CatalogOpening(packageURL: url)
        await opening.open()
        XCTAssertNotNil(opening.catalog)
        XCTAssertNil(opening.failureReason)
        XCTAssertEqual(try Data(contentsOf: metadata), bytes)
    }

    @MainActor
    func testOtherContentsAreNeverTreatedAsAnEmptyFirstLaunch() async throws {
        for name in ["Backups", "catalog.sqlite-wal", ".recovery-marker", ".DS_Store"] {
            let url = location()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let item = url.appendingPathComponent(name)
            if name == "Backups" || name == ".DS_Store" {
                // A directory named .DS_Store is not harmless Finder metadata.
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            } else {
                try Data("Keep this file".utf8).write(to: item)
            }
            let opening = CatalogOpening(packageURL: url)
            await opening.open()
            XCTAssertNil(opening.catalog, name)
            XCTAssertTrue(opening.failureReason?.contains("Backups") == true, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), name)
            if name != "Backups" && name != ".DS_Store" {
                XCTAssertEqual(try Data(contentsOf: item), Data("Keep this file".utf8), name)
            }
        }
    }

    @MainActor
    func testMissingDatabaseDoesNotCreateAnEmptyReplacement() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previews = url.appendingPathComponent("Previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let opening = CatalogOpening(packageURL: url)
        await opening.open()
        XCTAssertNil(opening.catalog)
        XCTAssertTrue(opening.failureReason?.contains("missing") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previews.path))
    }

    @MainActor
    func testFirstLaunchAndReopeningPreserveCatalogContents() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let opening = CatalogOpening(packageURL: url)
        await opening.open()
        let catalog = try XCTUnwrap(opening.catalog)
        try await catalog.writer.write { db in
            try db.execute(sql: "CREATE TABLE recovery_marker (value TEXT)")
            try db.execute(sql: "INSERT INTO recovery_marker VALUES ('keep')")
        }
        let reopened = CatalogOpening(packageURL: url)
        await reopened.open()
        let second = try XCTUnwrap(reopened.catalog)
        let value = try await second.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM recovery_marker")
        }
        XCTAssertEqual(value, "keep")
        XCTAssertNil(reopened.failureReason)
    }
}
