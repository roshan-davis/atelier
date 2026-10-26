import Foundation
import GRDB

/// Edit In results and AI results are cataloged as photos of their own, stacked on the photo
/// they came from through a `version` row.
extension Catalog {
    static func registerStackMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4-stacks") { db in
            try db.alter(table: "version") { t in
                t.add(column: "derivedAssetId", .integer).references("asset", onDelete: .cascade)
                t.add(column: "provenance", .text)
            }
            try db.create(index: "version_derivedAssetId", on: "version", columns: ["derivedAssetId"], unique: true)
        }
    }

    /// Records `derivedID` as a version of `parentID` and copies the parent's rating, label,
    /// title, caption, keywords, collections and import entries onto it.
    public func stack(_ derivedID: Int64, on parentID: Int64, kind: VersionKind, name: String?,
                      provenance: String? = nil) throws {
        try writer.write { db in
            let filePath = try Self.fetchDetail(db, assetID: derivedID)?.fileURL?.path
            if try PhotoVersion.filter(Column("derivedAssetId") == derivedID).fetchCount(db) == 0 {
                var version = PhotoVersion(assetId: parentID, kind: kind, name: name, filePath: filePath,
                                           derivedAssetId: derivedID, provenance: provenance)
                try version.insert(db)
            }
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

    /// The version row describing how a stacked photo was made, if it is one.
    public func derivation(of assetID: Int64) throws -> PhotoVersion? {
        try writer.read { db in
            try PhotoVersion.filter(Column("derivedAssetId") == assetID).fetchOne(db)
        }
    }

    /// Re-reads a file that changed on disk (an external editor saved it): size, date, hash
    /// and pixel size.
    public func refreshFileInfo(for assetID: Int64) throws {
        guard let url = try fileURL(for: assetID) else { return }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash = try FileHasher.sha256(of: url)
        let metadata = MetadataReader.read(url)
        try writer.write { db in
            try db.execute(sql: """
                UPDATE asset SET fileSize = ?, modifiedAt = ?, contentHash = ?, width = COALESCE(?, width),
                    height = COALESCE(?, height) WHERE id = ?
                """, arguments: [Int64(values.fileSize ?? 0), values.contentModificationDate, hash,
                                 metadata.width, metadata.height, assetID])
        }
    }
}

extension Importer {
    /// Catalogs one file where it is (referenced) and stacks it on `parentID`: how an Edit In
    /// or AI result joins the catalog. Returns the new photo's id.
    @discardableResult
    public func addStacked(_ url: URL, on parentID: Int64, kind: VersionKind, name: String?,
                           provenance: String? = nil) throws -> Int64 {
        let id: Int64
        switch try importFile(url, options: ImportOptions(buildPreviews: false)) {
        case .imported(let newID, _): id = newID
        case .existing(let existingID): id = existingID
        }
        try catalog.stack(id, on: parentID, kind: kind, name: name, provenance: provenance)
        return id
    }
}

/// Where Edit In and AI results are written.
public enum DerivedFiles {
    /// Next to the original when its folder is writable, otherwise `~/Pictures/Atelier/Edits`.
    public static func folder(for original: URL) -> URL {
        let folder = original.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path) { return folder }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Atelier/Edits", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
