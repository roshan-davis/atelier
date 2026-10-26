import Foundation
import GRDB

// Named import entries. Every import lands in one, either new or existing.

extension Catalog {
    @discardableResult
    public func createImportGroup(named name: String) throws -> ImportGroup {
        try writer.write { db in try Self.createImportGroup(db, named: name) }
    }

    static func createImportGroup(_ db: Database, named name: String) throws -> ImportGroup {
        var group = ImportGroup(name: name.nilIfBlank ?? "Untitled Import")
        try group.insert(db)
        return group
    }

    public func renameImportGroup(_ id: Int64, to name: String) throws {
        guard let name = name.nilIfBlank else { return }
        _ = try writer.write { db in
            try ImportGroup.filter(key: id).updateAll(db, Column("name").set(to: name))
        }
    }

    /// Deletes the entry only. Its photos stay in the catalog.
    public func deleteImportGroup(_ id: Int64) throws {
        _ = try writer.write { db in try ImportGroup.deleteOne(db, key: id) }
    }

    public func addAssets(_ assetIDs: [Int64], toImportGroup groupID: Int64) throws {
        try writer.write { db in try Self.addAssets(db, assetIDs, toImportGroup: groupID) }
    }

    static func addAssets(_ db: Database, _ assetIDs: [Int64], toImportGroup groupID: Int64) throws {
        for assetID in assetIDs {
            try ImportGroupAsset(importGroupId: groupID, assetId: assetID).insert(db, onConflict: .ignore)
        }
    }

    /// Removes photos from the entry. They stay in the catalog.
    public func removeAssets(_ assetIDs: [Int64], fromImportGroup groupID: Int64) throws {
        _ = try writer.write { db in
            try ImportGroupAsset
                .filter(Column("importGroupId") == groupID && assetIDs.contains(Column("assetId")))
                .deleteAll(db)
        }
    }

    /// Newest first.
    public static func fetchImportGroupSummaries(_ db: Database) throws -> [ImportGroupSummary] {
        try ImportGroupSummary.fetchAll(db, sql: """
            SELECT importGroup.id, importGroup.name, importGroup.createdAt,
                   COUNT(importGroupAsset.assetId) AS photoCount
            FROM importGroup
            LEFT JOIN importGroupAsset ON importGroupAsset.importGroupId = importGroup.id
            GROUP BY importGroup.id
            ORDER BY importGroup.createdAt DESC, importGroup.id DESC
            """)
    }

    public func importGroupSummaries() throws -> [ImportGroupSummary] {
        try writer.read { db in try Self.fetchImportGroupSummaries(db) }
    }

    public func renameCollection(_ id: Int64, to name: String) throws {
        guard let name = name.nilIfBlank else { return }
        _ = try writer.write { db in
            try PhotoCollection.filter(key: id).updateAll(db, Column("name").set(to: name))
        }
    }
}
