import Foundation
import GRDB

public enum LibraryScope: Hashable, Sendable {
    case all
    case volume(Int64)
    case folder(Int64)
    case collection(Int64)
    case importGroup(Int64)
}

/// The filter bar plus sidebar scope. Conditions combine with AND.
public struct LibraryFilter: Hashable, Sendable {
    public var scope: LibraryScope = .all
    public var minRating: Int = 0
    public var flag: Flag?
    public var colorLabel: ColorLabel?
    /// Matches filename, title, caption or keyword.
    public var text: String = ""

    public init(scope: LibraryScope = .all, minRating: Int = 0, flag: Flag? = nil,
                colorLabel: ColorLabel? = nil, text: String = "") {
        self.scope = scope
        self.minRating = minRating
        self.flag = flag
        self.colorLabel = colorLabel
        self.text = text
    }
}

extension Catalog {
    public static func fetchAssetRows(_ db: Database, filter: LibraryFilter) throws -> [AssetRow] {
        var sql = """
            SELECT asset.id, asset.filename, asset.captureTime, asset.folderId,
                   metadata.rating, metadata.flag, metadata.colorLabel,
                   stackVersion.assetId AS stackParentId, stackVersion.kind AS stackKind,
                   (SELECT COUNT(*) FROM version derived
                    WHERE derived.assetId = asset.id AND derived.derivedAssetId IS NOT NULL) AS stackCount,
                   (SELECT COUNT(*) FROM cullGroupAsset member
                    WHERE member.cullGroupId = (SELECT cullGroupId FROM cullGroupAsset WHERE assetId = asset.id))
                    AS cullGroupSize
            FROM asset
            JOIN metadata ON metadata.assetId = asset.id
            LEFT JOIN version stackVersion ON stackVersion.derivedAssetId = asset.id
            LEFT JOIN asset stackParent ON stackParent.id = stackVersion.assetId
            """
        var conditions: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []

        switch filter.scope {
        case .all:
            break
        case .volume(let id):
            conditions.append("asset.folderId IN (SELECT id FROM folder WHERE volumeId = ?)")
            arguments.append(id)
        case .folder(let id):
            conditions.append("asset.folderId = ?")
            arguments.append(id)
        case .collection(let id):
            conditions.append("asset.id IN (SELECT assetId FROM collectionAsset WHERE collectionId = ?)")
            arguments.append(id)
        case .importGroup(let id):
            conditions.append("asset.id IN (SELECT assetId FROM importGroupAsset WHERE importGroupId = ?)")
            arguments.append(id)
        }
        if filter.minRating > 0 {
            conditions.append("metadata.rating >= ?")
            arguments.append(filter.minRating)
        }
        if let flag = filter.flag {
            conditions.append("metadata.flag = ?")
            arguments.append(flag.rawValue)
        }
        if let label = filter.colorLabel {
            conditions.append("metadata.colorLabel = ?")
            arguments.append(label.rawValue)
        }
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let pattern = "%\(text)%"
            conditions.append("""
                (asset.filename LIKE ? OR metadata.title LIKE ? OR metadata.caption LIKE ?
                 OR asset.id IN (SELECT assetKeyword.assetId FROM assetKeyword
                                 JOIN keyword ON keyword.id = assetKeyword.keywordId
                                 WHERE keyword.name LIKE ?))
                """)
            arguments.append(contentsOf: [pattern, pattern, pattern, pattern])
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        // Stacked edits sort right after the photo they came from.
        sql += """
             ORDER BY COALESCE(stackParent.captureTime, stackParent.importedAt, asset.captureTime, asset.importedAt),
                      COALESCE(stackParent.id, asset.id), asset.id
            """
        return try AssetRow.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    public func assetRows(filter: LibraryFilter) throws -> [AssetRow] {
        try writer.read { db in try Self.fetchAssetRows(db, filter: filter) }
    }
}
