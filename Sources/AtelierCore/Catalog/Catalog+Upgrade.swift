import Foundation
import GRDB

/// Keeping catalogs safe across Atelier versions (AT-087, PRD "Updates and distribution").
///
/// - Before a catalog takes new migrations, its database is copied to
///   `Backups/Before Upgrade/` inside the catalog (the newest `beforeUpgradeKeep` kept, apart from
///   the quit-time backups so those never push it out). If the copy fails, nothing is migrated.
/// - The catalog's format number (`PRAGMA user_version`) says which major catalog format it uses.
///   Minor versions only add tables and columns an older Atelier ignores, so the number stays the
///   same and switching between versions (or branches) keeps working. A major version that
///   changes the catalog in a way older versions can't read raises `Catalog.format`; an older
///   Atelier then refuses the catalog instead of damaging it.
extension Catalog {
    /// The catalog format this Atelier writes. Raise it only in a major version, together with
    /// the migration that needs it, and say so in the release notes.
    public static let format = 1
    public static let beforeUpgradeFolder = "Before Upgrade"
    public static let beforeUpgradeKeep = 3

    /// Run on an existing catalog before `migrator.migrate`: refuses a newer format, then backs
    /// up the database if any migration is still to run.
    static func prepareForUpgrade(_ writer: any DatabaseWriter, packageURL: URL) throws {
        let found = try writer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        let complete = try writer.read { try Self.migrator.hasCompletedMigrations($0) }
        if found > format { throw CatalogError.newerFormat(found: found, supported: format) }
        if !complete { try backUpBeforeUpgrade(writer, packageURL: packageURL) }
    }

    /// Stamps the format after migrating (a catalog from before AT-087 reads as 0).
    static func stampFormat(_ writer: any DatabaseWriter) throws {
        let found = try writer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard found < format else { return }
        try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA user_version = \(format)") }
    }

    @discardableResult
    static func backUpBeforeUpgrade(_ writer: any DatabaseWriter, packageURL: URL, date: Date = Date()) throws -> URL {
        let dir = packageURL.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(beforeUpgradeFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        var url = dir.appendingPathComponent("catalog-\(formatter.string(from: date)).sqlite")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("catalog-\(formatter.string(from: date))-\(suffix).sqlite")
            suffix += 1
        }
        do {
            let destination = try DatabaseQueue(path: url.path)
            try writer.backup(to: destination)
            try destination.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw CatalogError.upgradeBackupFailed(error.localizedDescription)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(beforeUpgradeKeep) { try? FileManager.default.removeItem(at: old) }
        return url
    }
}
