import Foundation
import GRDB

public enum VersionKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// The photo as developed from its original. Every asset gets one on first edit.
    case master
    case virtualCopy
    case externalEdit
    case ai
}

/// A version in a photo's stack (PRD data model). Phase 2 uses the master version; virtual
/// copies, Edit In results and AI results stack on top later.
public struct PhotoVersion: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "version"

    public var id: Int64?
    public var assetId: Int64
    public var kind: VersionKind
    public var parentVersionId: Int64?
    public var name: String?
    /// Rendered file for external edits and AI results; nil for parameter-only versions.
    public var filePath: String?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct DevelopSettingsRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "developSettings"
    var versionId: Int64
    var schemaVersion: Int
    var json: String
    var historyJson: String
    var updatedAt: Date
}

extension Catalog {
    static func registerDevelopMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-develop") { db in
            try db.create(table: "version") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .integer).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("parentVersionId", .integer).references("version", onDelete: .setNull)
                t.column("name", .text)
                t.column("filePath", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "developSettings") { t in
                t.column("versionId", .integer).primaryKey().references("version", onDelete: .cascade)
                t.column("schemaVersion", .integer).notNull()
                t.column("json", .text).notNull()
                t.column("historyJson", .text).notNull().defaults(to: "[]")
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    static func masterVersionID(_ db: Database, assetID: Int64, create: Bool) throws -> Int64? {
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM version WHERE assetId = ? AND kind = 'master'",
                                       arguments: [assetID]) {
            return id
        }
        guard create else { return nil }
        var version = PhotoVersion(id: nil, assetId: assetID, kind: .master, parentVersionId: nil,
                                   name: nil, filePath: nil, createdAt: Date())
        try version.insert(db)
        return version.id
    }

    /// The master version's settings; neutral when the photo was never edited.
    public func developSettings(for assetID: Int64) throws -> DevelopSettings {
        try writer.read { db in
            guard let versionID = try Self.masterVersionID(db, assetID: assetID, create: false),
                  let record = try DevelopSettingsRecord.fetchOne(db, key: versionID) else { return .neutral }
            return try DevelopSettings.decoded(from: record.json)
        }
    }

    /// The master version's edit history and snapshots.
    public func developHistory(for assetID: Int64) throws -> DevelopHistory {
        try writer.read { db in
            guard let versionID = try Self.masterVersionID(db, assetID: assetID, create: false),
                  let json = try String.fetchOne(db, sql: "SELECT historyJson FROM developSettings WHERE versionId = ?",
                                                 arguments: [versionID]) else { return DevelopHistory() }
            return DevelopHistory.decoded(from: json)
        }
    }

    /// Saves settings and history together (the open photo in Develop keeps both in memory).
    public func saveDevelop(_ settings: DevelopSettings, history: DevelopHistory, for assetID: Int64) throws {
        let json = try settings.encoded()
        let historyJSON = try history.encoded()
        try writer.write { db in
            guard let versionID = try Self.masterVersionID(db, assetID: assetID, create: true) else { return }
            try DevelopSettingsRecord(versionId: versionID, schemaVersion: settings.schemaVersion, json: json,
                                      historyJson: historyJSON, updatedAt: Date()).save(db)
        }
    }

    /// Saves settings and adds a history step named `step` (paste, presets, sync).
    public func saveDevelopSettings(_ settings: DevelopSettings, for assetID: Int64, step: String = "Edit") throws {
        var history = try developHistory(for: assetID)
        let previous = try developSettings(for: assetID)
        history.record(step, settings: settings, previous: previous)
        try saveDevelop(settings, history: history, for: assetID)
    }

    /// Copies the settings of one photo onto others (paste settings, sync).
    public func applyDevelopSettings(_ settings: DevelopSettings, to assetIDs: [Int64], step: String = "Paste Settings") throws {
        for id in assetIDs { try saveDevelopSettings(settings, for: id, step: step) }
    }
}
