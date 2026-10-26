import Foundation
import GRDB

/// Virtual copies: more photos of the same file, each with its own develop settings and
/// metadata. A copy is an `asset` row pointing at the same file, marked with `virtualCopyOf`,
/// and stacked on the master through a `version` row named "Copy 1", "Copy 2", ….
extension Catalog {
    static func registerVirtualCopyMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-virtual-copies") { db in
            // SQLite can't drop the (folderId, filename) unique key in place, so the table is
            // rebuilt; GRDB runs this with foreign key checks deferred.
            try db.create(table: "new_asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull().references("folder", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime)
                t.column("contentHash", .text).notNull()
                t.column("perceptualHash", .text)
                t.column("captureTime", .datetime)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("lens", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("orientation", .integer)
                t.column("uti", .text)
                t.column("importedAt", .datetime).notNull()
                t.column("virtualCopyOf", .integer).references("asset", onDelete: .cascade)
            }
            let columns = "id, folderId, filename, fileSize, modifiedAt, contentHash, perceptualHash, captureTime, "
                + "cameraMake, cameraModel, lens, width, height, orientation, uti, importedAt"
            try db.execute(sql: "INSERT INTO new_asset (\(columns)) SELECT \(columns) FROM asset")
            try db.drop(table: "asset")
            try db.rename(table: "new_asset", to: "asset")
            try db.create(index: "asset_on_folderId", on: "asset", columns: ["folderId"])
            try db.create(index: "asset_on_contentHash", on: "asset", columns: ["contentHash"])
            try db.create(index: "asset_on_captureTime", on: "asset", columns: ["captureTime"])
            try db.create(index: "asset_on_virtualCopyOf", on: "asset", columns: ["virtualCopyOf"])
            // One master per file; any number of copies.
            try db.execute(sql: """
                CREATE UNIQUE INDEX asset_file ON asset (folderId, filename) WHERE virtualCopyOf IS NULL
                """)
        }
    }

    /// Photo > Create Virtual Copy. The copy starts with the photo's current develop settings,
    /// rating, label, title, caption, keywords, collections and import entries, and is stacked on
    /// the master (a copy of a copy stacks on the same master). Returns the copy's id.
    @discardableResult
    public func createVirtualCopy(of assetID: Int64) throws -> Int64 {
        try writer.write { db in
            guard var asset = try Asset.fetchOne(db, key: assetID) else { throw CatalogError.notFound("The photo") }
            let masterID = asset.virtualCopyOf ?? assetID
            let used = Set(try String.fetchAll(db, sql: """
                SELECT name FROM version WHERE assetId = ? AND kind = ? AND name IS NOT NULL
                """, arguments: [masterID, VersionKind.virtualCopy.rawValue]))
            let number = (1...).first { !used.contains("Copy \($0)") }!

            asset.id = nil
            asset.virtualCopyOf = masterID
            asset.importedAt = Date()
            try asset.insert(db)
            let copyID = asset.id!
            try AssetMetadata(assetId: copyID).insert(db)
            try Self.copyCatalogInfo(db, from: assetID, to: copyID)
            var version = PhotoVersion(assetId: masterID, kind: .virtualCopy, name: "Copy \(number)",
                                       derivedAssetId: copyID)
            try version.insert(db)

            if let sourceVersion = try Self.masterVersionID(db, assetID: assetID, create: false),
               let record = try DevelopSettingsRecord.fetchOne(db, key: sourceVersion),
               let copyVersion = try Self.masterVersionID(db, assetID: copyID, create: true) {
                let settings = try DevelopSettings.decoded(from: record.json)
                var history = DevelopHistory()
                history.steps = [DevelopHistory.Step(name: "Virtual Copy", settings: settings)]
                history.position = 0
                try DevelopSettingsRecord(versionId: copyVersion, schemaVersion: record.schemaVersion, json: record.json,
                                          historyJson: try history.encoded(), updatedAt: Date()).save(db)
            }
            return copyID
        }
    }

    /// Removes virtual copies from the catalog. Masters and their files are never touched;
    /// ids that aren't copies are skipped. Returns how many were removed.
    @discardableResult
    public func removeVirtualCopies(_ assetIDs: [Int64]) throws -> Int {
        try writer.write { db in
            try Asset.filter(keys: assetIDs).filter(Column("virtualCopyOf") != nil).deleteAll(db)
        }
    }

    /// "Copy 2" for a virtual copy; nil for any other photo.
    public func virtualCopyName(of assetID: Int64) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM version WHERE derivedAssetId = ? AND kind = ?",
                                arguments: [assetID, VersionKind.virtualCopy.rawValue])
        }
    }

    /// Rating, label, title, caption, keywords, collections and import entries, for a photo
    /// that joins a stack.
    static func copyCatalogInfo(_ db: Database, from parentID: Int64, to derivedID: Int64) throws {
        try db.execute(sql: """
            UPDATE metadata SET
                rating = (SELECT rating FROM metadata WHERE assetId = :parent),
                colorLabel = (SELECT colorLabel FROM metadata WHERE assetId = :parent),
                title = COALESCE(title, (SELECT title FROM metadata WHERE assetId = :parent)),
                caption = COALESCE(caption, (SELECT caption FROM metadata WHERE assetId = :parent))
            WHERE assetId = :derived
            """, arguments: ["parent": parentID, "derived": derivedID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO assetKeyword (assetId, keywordId)
            SELECT :derived, keywordId FROM assetKeyword WHERE assetId = :parent
            """, arguments: ["parent": parentID, "derived": derivedID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO collectionAsset (collectionId, assetId)
            SELECT collectionId, :derived FROM collectionAsset WHERE assetId = :parent
            """, arguments: ["parent": parentID, "derived": derivedID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO importGroupAsset (importGroupId, assetId)
            SELECT importGroupId, :derived FROM importGroupAsset WHERE assetId = :parent
            """, arguments: ["parent": parentID, "derived": derivedID])
    }
}
