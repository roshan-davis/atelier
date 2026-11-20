import GRDB
import XCTest
@testable import AtelierCore

/// AT-087: versions, release notes, What's New and keeping catalogs safe across versions.
final class UpdatesTests: XCTestCase {
    func testVersionParsingAndOrder() throws {
        XCTAssertEqual(AppVersion("v1.3"), AppVersion(1, 3, 0))
        XCTAssertEqual(AppVersion("1.3.0-beta.2")?.description, "1.3.0-beta.2")
        for bad in ["", "1.x", "1.2.3.4", "1.2-", "beta", "1..2"] { XCTAssertNil(AppVersion(bad), bad) }
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
            .compactMap(AppVersion.init)
        XCTAssertEqual(ordered.count, 9)
        XCTAssertEqual(ordered.reversed().sorted(), ordered)
        XCTAssertEqual(AppVersion(1, 3, 0).shortDescription, "1.3")
        XCTAssertEqual(AppVersion(1, 3, 1).shortDescription, "1.3.1")
    }

    func testUpdateKinds() {
        XCTAssertEqual(UpdateKind(from: AppVersion(1, 2, 0), to: AppVersion(1, 2, 1)), .patch)
        XCTAssertEqual(UpdateKind(from: AppVersion(1, 2, 0), to: AppVersion(1, 3, 0)), .minor)
        XCTAssertEqual(UpdateKind(from: AppVersion(1, 9, 3), to: AppVersion(2, 0, 0)), .major)
        XCTAssertEqual(UpdateKind(from: AppVersion(1, 2, 0), to: AppVersion(1, 1, 0)), .none)
        XCTAssertTrue(UpdateKind.minor.installsWithoutAsking)
        XCTAssertFalse(UpdateKind.major.installsWithoutAsking)
    }

    static let notes = ReleaseNotes(markdown: """
        # Atelier release notes
        <!--
        ## 9.9.9 (inside a comment, ignored)
        -->
        ## 1.2.0 (2026-11-20)
        Updates arrive by themselves.
        ### New
        - **Settings > Updates** shows the version.
        - A long bullet that
          wraps onto a second line.
        ### Fixed
        - Crop streaks.
        ## 1.3.0-beta.1 (2026-11-25)
        - Preview.
        ## 1.1.0
        ### Fixed
        - Older fix.
        """)

    func testReleaseNotesParse() throws {
        XCTAssertEqual(Self.notes.releases.map(\.version.description), ["1.3.0-beta.1", "1.2.0", "1.1.0"])
        let release = try XCTUnwrap(Self.notes.release(AppVersion(1, 2, 0)))
        XCTAssertEqual(release.date, "2026-11-20")
        XCTAssertEqual(release.summary, "Updates arrive by themselves.")
        XCTAssertEqual(release.sections.map(\.title), ["New", "Fixed"])
        XCTAssertEqual(release.sections[0].items, ["**Settings > Updates** shows the version.",
                                                   "A long bullet that wraps onto a second line."])
        XCTAssertEqual(Self.notes.release(AppVersion(1, 3, 0, prerelease: "beta.1"))?.sections.first?.title, "")
        XCTAssertNil(Self.notes.release(AppVersion(1, 1, 0))?.date)
    }

    func testWhatsNewShowsOnceAfterAnUpdate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UpdatesTests-\(UUID())"))
        // A fresh install shows nothing, but remembers the version.
        XCTAssertNil(WhatsNewSchedule.releasesToShow(current: AppVersion(1, 1, 0), notes: Self.notes, defaults: defaults))
        // The update to 1.2 shows 1.2 only; betas stay out of a release's notes.
        let shown = WhatsNewSchedule.releasesToShow(current: AppVersion(1, 2, 0), notes: Self.notes, defaults: defaults)
        XCTAssertEqual(shown?.map(\.version.description), ["1.2.0"])
        // Then never again for the same version, nor for a downgrade.
        XCTAssertNil(WhatsNewSchedule.releasesToShow(current: AppVersion(1, 2, 0), notes: Self.notes, defaults: defaults))
        XCTAssertNil(WhatsNewSchedule.releasesToShow(current: AppVersion(1, 1, 0), notes: Self.notes, defaults: defaults))
        // A beta tester sees betas.
        let beta = Self.notes.releases(after: AppVersion(1, 1, 0), upTo: AppVersion(1, 3, 0, prerelease: "beta.1"))
        XCTAssertEqual(beta.map(\.version.description), ["1.3.0-beta.1", "1.2.0"])
    }

    func testShippedChangelogHasTheCurrentVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/AtelierApp/Resources/ReleaseNotes.md"), encoding: .utf8)
        let version = try XCTUnwrap(AppVersion(try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)))
        XCTAssertNotNil(ReleaseNotes(markdown: text).release(version), "ReleaseNotes.md needs a section for VERSION")
    }

    // MARK: Catalog

    private func temporaryPackage() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdatesTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Test.atelier", isDirectory: true)
    }

    private func beforeUpgradeBackups(_ package: URL) -> [URL] {
        let dir = package.appendingPathComponent("Backups/\(Catalog.beforeUpgradeFolder)")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sqlite" }
    }

    func testNewCatalogIsStampedAndNotBackedUp() throws {
        let package = try temporaryPackage()
        let catalog = try Catalog(packageURL: package)
        XCTAssertEqual(try catalog.writer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, Catalog.format)
        XCTAssertEqual(beforeUpgradeBackups(package), [])
        // Reopening an up-to-date catalog backs nothing up.
        _ = try Catalog(packageURL: package)
        XCTAssertEqual(beforeUpgradeBackups(package), [])
    }

    func testPendingMigrationsAreBackedUpFirst() throws {
        let package = try temporaryPackage()
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        // A database with migrations still to run (here, all of them).
        let old = try DatabaseQueue(path: package.appendingPathComponent("catalog.sqlite").path)
        try old.write { try $0.execute(sql: "CREATE TABLE oldData (value TEXT); INSERT INTO oldData VALUES ('kept')") }
        try old.close()
        _ = try Catalog(packageURL: package)
        let backups = beforeUpgradeBackups(package)
        XCTAssertEqual(backups.count, 1)
        let backup = try DatabaseQueue(path: try XCTUnwrap(backups.first).path)
        XCTAssertEqual(try backup.read { try String.fetchOne($0, sql: "SELECT value FROM oldData") }, "kept")
        XCTAssertEqual(try backup.read { try Bool.fetchOne($0, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'asset'") }, false)
    }

    func testOnlyTheNewestBeforeUpgradeBackupsAreKept() throws {
        let package = try temporaryPackage()
        let catalog = try Catalog(packageURL: package)
        for day in 0..<5 {
            try Catalog.backUpBeforeUpgrade(catalog.writer, packageURL: package, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
        }
        XCTAssertEqual(beforeUpgradeBackups(package).count, Catalog.beforeUpgradeKeep)
        // Quit-time snapshots keep their own count and never remove these.
        try catalog.snapshot(keep: 1)
        try catalog.snapshot(keep: 1)
        XCTAssertEqual(beforeUpgradeBackups(package).count, Catalog.beforeUpgradeKeep)
    }

    func testNewerCatalogFormatIsRefusedUntouched() throws {
        let package = try temporaryPackage()
        do {
            let catalog = try Catalog(packageURL: package)
            try catalog.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA user_version = \(Catalog.format + 1)") }
        }
        XCTAssertThrowsError(try Catalog(packageURL: package)) { error in
            guard case CatalogError.newerFormat(let found, let supported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, Catalog.format + 1)
            XCTAssertEqual(supported, Catalog.format)
        }
        XCTAssertEqual(beforeUpgradeBackups(package), [])
    }
}
