import Foundation
import GRDB

/// Cull groups: similar shots culled together, kept so a keeper can be re-reviewed next to the
/// shots it beat, even ones that were never added to an import entry.
extension Catalog {
    static func registerCullMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-cull") { db in
            try db.create(table: "cullGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "cullGroupAsset") { t in
                t.column("cullGroupId", .integer).notNull().indexed().references("cullGroup", onDelete: .cascade)
                t.column("assetId", .integer).notNull().unique().references("asset", onDelete: .cascade)
            }
        }
    }

    /// Records the outcome of a cull. Groups of two or more are saved (a photo belongs to one
    /// group; culling again replaces its old group). Keepers in those groups are flagged Picked
    /// and the rest Rejected; single shots keep their flags. A keeper that isn't in any import
    /// entry joins the entries its group's other photos are in.
    public func applyCull(groups: [[Int64]], keepers: Set<Int64>) throws {
        try writer.write { db in
            let now = Date()
            for group in groups where group.count > 1 {
                for id in group {
                    try db.execute(sql: "DELETE FROM cullGroupAsset WHERE assetId = ?", arguments: [id])
                }
                try db.execute(sql: "INSERT INTO cullGroup (createdAt) VALUES (?)", arguments: [now])
                let groupID = db.lastInsertedRowID
                for id in group {
                    try db.execute(sql: "INSERT INTO cullGroupAsset (cullGroupId, assetId) VALUES (?, ?)",
                                   arguments: [groupID, id])
                    let flag: Flag = keepers.contains(id) ? .picked : .rejected
                    try db.execute(sql: "UPDATE metadata SET flag = ?, xmpDirty = 1 WHERE assetId = ?",
                                   arguments: [flag.rawValue, id])
                }
                let list = group.map(String.init).joined(separator: ",")
                for id in group where keepers.contains(id) {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO importGroupAsset (importGroupId, assetId)
                        SELECT DISTINCT importGroupId, ? FROM importGroupAsset
                        WHERE assetId IN (\(list))
                          AND NOT EXISTS (SELECT 1 FROM importGroupAsset WHERE assetId = ?)
                        """, arguments: [id, id])
                }
            }
            try db.execute(sql: "DELETE FROM cullGroup WHERE id NOT IN (SELECT cullGroupId FROM cullGroupAsset)")
        }
    }

    /// The photos culled together with `assetID`, in capture order, or [] when it was never
    /// in a group.
    public func cullGroup(of assetID: Int64) throws -> [Int64] {
        try writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT member.assetId FROM cullGroupAsset member
                JOIN asset ON asset.id = member.assetId
                WHERE member.cullGroupId = (SELECT cullGroupId FROM cullGroupAsset WHERE assetId = ?)
                ORDER BY COALESCE(asset.captureTime, asset.importedAt), asset.id
                """, arguments: [assetID])
        }
    }
}
