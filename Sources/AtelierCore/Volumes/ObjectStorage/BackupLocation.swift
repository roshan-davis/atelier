import Foundation
import GRDB

/// When catalog backups go to the backup location (Settings > Storage > Backups). Lightroom's
/// choices: each one is done when Atelier quits, if one is due.
public enum BackupSchedule: String, CaseIterable, Sendable, Codable {
    case everyQuit, daily, weekly

    public var title: String {
        switch self {
        case .everyQuit: return "Every Time Atelier Quits"
        case .daily: return "Once a Day, When Atelier Quits"
        case .weekly: return "Once a Week, When Atelier Quits"
        }
    }

    /// Whether a backup is due now, after the last one that worked at `last`.
    public func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        switch self {
        case .everyQuit: return true
        case .daily: return now.timeIntervalSince(last) >= 20 * 3600
        case .weekly: return now.timeIntervalSince(last) >= 6.5 * 24 * 3600
        }
    }
}

extension Catalog {
    /// The location catalog backups go to: the one with Backups ticked (Settings > Storage >
    /// Backups chooses one); nil for none.
    public func backupLocationID() throws -> Int64? {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM storageLocation WHERE usesBackups = 1 ORDER BY id LIMIT 1")
        }
    }

    /// "Back up the catalog to": ticks Backups on `locationID` only (nil: none).
    public func setBackupLocation(_ locationID: Int64?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE storageLocation SET usesBackups = (id IS ?)", arguments: [locationID])
        }
    }

    /// Where a backup to the location goes now: its bucket (with its Keychain keys), or its folder
    /// while it is connected. Throws a plain reason when it can't be reached.
    public func backupDestination(for locationID: Int64, secrets: SecretStore = KeychainSecrets()) throws -> BackupDestination {
        let name = CatalogBackups.catalogName(self)
        if let storage = try objectStorage(locationID) {
            guard let credentials = secrets.credentials(storage.keychainItem) else {
                throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey:
                    "The keys for “\(storage.location.name)” aren't in the Keychain. Choose Sign In Again… in Settings > Storage."])
            }
            return S3BackupDestination(client: S3Client(bucket: storage.bucket, credentials: credentials), catalogName: name)
        }
        guard let info = try storageLocations().first(where: { $0.id == locationID }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The backup location was removed."])
        }
        guard let root = info.rootURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "“\(info.location.name)” isn't connected."])
        }
        return FolderBackupDestination(root: root, catalogName: name)
    }
}
