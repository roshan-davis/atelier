import Foundation
import GRDB

/// "Make smart previews for photos here" on a location (AT-079d d2, PRD "Add Location…": on for
/// network shares and cloud drive folders). A column of its own beside `StorageLocation`'s, so
/// the record (and the v12 migration that inserts it) stays as it was.
extension Catalog {
    static func registerSmartPreviewLocationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-smart-preview-locations") { db in
            try db.alter(table: StorageLocation.databaseTableName) { t in
                t.add(column: "makesSmartPreviews", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                UPDATE storageLocation SET makesSmartPreviews = 1 WHERE kind IN (?, ?)
                """, arguments: [StorageLocationKind.networkShare.rawValue, StorageLocationKind.cloudFolder.rawValue])
        }
    }

    /// The default for a new location of `kind`: on for network shares and cloud drive folders.
    public static func makesSmartPreviewsByDefault(_ kind: StorageLocationKind) -> Bool {
        kind == .networkShare || kind == .cloudFolder
    }

    public func makesSmartPreviews(_ locationID: Int64) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT makesSmartPreviews FROM storageLocation WHERE id = ?", arguments: [locationID])
        } ?? false
    }

    public func setMakesSmartPreviews(_ locationID: Int64, _ on: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE storageLocation SET makesSmartPreviews = ? WHERE id = ?", arguments: [on, locationID])
        }
    }

    /// Among `assetIDs`, the masters in a location that makes smart previews (its folder or one
    /// inside it, never a sibling such as "PortfolioOld" for "Portfolio").
    public func smartPreviewCandidates(among assetIDs: [Int64]) throws -> [Int64] {
        guard !assetIDs.isEmpty else { return [] }
        return try writer.read { db in
            var found: [Int64] = []
            for chunk in stride(from: 0, to: assetIDs.count, by: 500).map({ Array(assetIDs[$0..<min($0 + 500, assetIDs.count)]) }) {
                found += try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT asset.id FROM asset
                    JOIN folder ON folder.id = asset.folderId
                    JOIN storageLocation l ON l.volumeId = folder.volumeId
                    WHERE l.makesSmartPreviews = 1 AND asset.virtualCopyOf IS NULL
                      AND (l.rootPath = '' OR folder.relativePath = l.rootPath
                           OR substr(folder.relativePath, 1, length(l.rootPath) + 1) = l.rootPath || '/')
                      AND asset.id IN (\(databaseQuestionMarks(count: chunk.count)))
                    """, arguments: StatementArguments(chunk))
            }
            return found
        }
    }
}
