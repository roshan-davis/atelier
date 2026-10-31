import Foundation
import GRDB

// Private import entries and collections (AT-023). While private photos are hidden, a photo in
// any private list is left out of every list of photos, count and sidebar item, whatever other
// lists it is in. This is about seeing them only on purpose, not security: files and previews
// are not encrypted.

extension Catalog {
    static func registerPrivateMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9-private-lists") { db in
            try db.alter(table: "importGroup") { t in
                t.add(column: "isPrivate", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "collection") { t in
                t.add(column: "isPrivate", .boolean).notNull().defaults(to: false)
            }
        }
    }

    /// The photos in a private import entry or collection.
    static let privateMembers = """
        SELECT assetId FROM importGroupAsset
        WHERE importGroupId IN (SELECT id FROM importGroup WHERE isPrivate)
        UNION SELECT assetId FROM collectionAsset
        WHERE collectionId IN (SELECT id FROM collection WHERE isPrivate)
        """

    /// SQL that is true when the photo `alias` is private: it is in a private list, or it is a
    /// virtual copy, stacked edit or AI result of one, or the other file of its RAW+JPEG pair is.
    /// Never NULL (every NULL column is checked first), so `NOT` it is safe.
    public static func privateCondition(_ alias: String = "asset") -> String {
        """
        (\(alias).id IN (\(privateMembers))
         OR (\(alias).virtualCopyOf IS NOT NULL AND \(alias).virtualCopyOf IN (\(privateMembers)))
         OR \(alias).id IN (SELECT derivedAssetId FROM version
                            WHERE derivedAssetId IS NOT NULL AND assetId IN (\(privateMembers)))
         OR (\(alias).stem IS NOT NULL AND EXISTS (
                SELECT 1 FROM asset privateSibling
                WHERE privateSibling.folderId = \(alias).folderId AND privateSibling.stem = \(alias).stem
                  AND privateSibling.id != \(alias).id AND privateSibling.id IN (\(privateMembers)))))
        """
    }

    /// The condition that leaves out (hidden) or keeps only (only) private photos; nil when shown.
    public static func privacyCondition(_ privacy: PrivateVisibility, _ alias: String = "asset") -> String? {
        switch privacy {
        case .hidden: return "NOT " + privateCondition(alias)
        case .shown: return nil
        case .only: return privateCondition(alias)
        }
    }

    /// Right-click an import entry > Make Private / Make Not Private.
    public func setImportGroup(_ id: Int64, isPrivate: Bool) throws {
        _ = try writer.write { db in
            try ImportGroup.filter(key: id).updateAll(db, Column("isPrivate").set(to: isPrivate))
        }
    }

    /// Right-click a collection > Make Private / Make Not Private. Collection sets hold no photos
    /// and can't be private.
    public func setCollection(_ id: Int64, isPrivate: Bool) throws {
        _ = try writer.write { db in
            try PhotoCollection.filter(key: id).filter(Column("isSet") == false)
                .updateAll(db, Column("isPrivate").set(to: isPrivate))
        }
    }

    /// How many import entries and collections are private: the View menu's private photo
    /// commands appear only when there is one.
    public static func fetchPrivateListCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT (SELECT COUNT(*) FROM importGroup WHERE isPrivate)
                 + (SELECT COUNT(*) FROM collection WHERE isPrivate)
            """) ?? 0
    }

    /// Those of `ids` that are private.
    public func privatePhotoIDs(among ids: some Collection<Int64>) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return Set(try Int64.fetchAll(db, sql: """
                SELECT asset.id FROM asset WHERE asset.id IN (\(placeholders)) AND \(Self.privateCondition())
                """, arguments: StatementArguments(Array(ids))))
        }
    }

    /// Collections by name: without private ones (hidden), all (shown) or only private ones (only).
    public static func fetchCollections(_ db: Database, privacy: PrivateVisibility = .hidden) throws -> [PhotoCollection] {
        var request = PhotoCollection.order(Column("name"))
        switch privacy {
        case .hidden: request = request.filter(Column("isPrivate") == false)
        case .shown: break
        case .only: request = request.filter(Column("isPrivate") == true)
        }
        return try request.fetchAll(db)
    }

    /// Folders by path. Hidden: a folder whose photos are all private is left out, so its name
    /// doesn't show either (empty folders stay). Only: just folders holding a private photo.
    public static func fetchFolders(_ db: Database, privacy: PrivateVisibility = .hidden) throws -> [Folder] {
        guard let condition = privacyCondition(privacy) else { return try Folder.order(Column("relativePath")).fetchAll(db) }
        let keepsEmpty = privacy == .hidden ? "NOT EXISTS (SELECT 1 FROM asset WHERE asset.folderId = folder.id) OR " : ""
        return try Folder.fetchAll(db, sql: """
            SELECT folder.* FROM folder
            WHERE \(keepsEmpty)EXISTS (SELECT 1 FROM asset WHERE asset.folderId = folder.id AND \(condition))
            ORDER BY folder.relativePath
            """)
    }
}
