import Foundation
import GRDB

/// Whether photos in private imports and collections are shown (View menu).
public enum PrivateVisibility: String, Hashable, Sendable {
    /// Left out everywhere (every launch starts here).
    case hidden
    /// Shown with every other photo.
    case shown
    /// Only private photos and lists are shown.
    case only
}

public enum LibraryScope: Hashable, Codable, Sendable {
    case all
    case volume(Int64)
    case folder(Int64)
    case collection(Int64)
    case importGroup(Int64)
}

/// The order photos are shown in, chosen from the Filmstrip's Sort menu. Edits and AI results
/// stacked on a photo always follow it, whatever the order.
public enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case captureTime, importOrder, fileName, rating, editTime

    public var title: String {
        switch self {
        case .captureTime: return "Capture Time"
        case .importOrder: return "Import Order"
        case .fileName: return "File Name"
        case .rating: return "Rating"
        case .editTime: return "Edit Time"
        }
    }
}

/// Library's Notes filter (AT-058).
public enum NotesFilter: String, CaseIterable, Codable, Sendable {
    case hasNotes, noNotes, openCheckboxes

    public var title: String {
        switch self {
        case .hasNotes: return "Has Notes"
        case .noNotes: return "No Notes"
        case .openCheckboxes: return "Unticked Checkboxes"
        }
    }
}

/// The filter bar plus sidebar scope. Conditions combine with AND.
public struct LibraryFilter: Hashable, Sendable {
    public var scope: LibraryScope = .all
    public var minRating: Int = 0
    public var flag: Flag?
    public var colorLabel: ColorLabel?
    /// True shows only photos with Develop edits, false only unedited ones, nil both.
    public var edited: Bool?
    /// Photos with notes, without, or with a checkbox still to tick (AT-058).
    public var notes: NotesFilter?
    /// Matches filename, title, caption, keyword or note.
    public var text: String = ""
    /// Shows a RAW+JPEG pair as its RAW alone (see `FilePairs`).
    public var groupsRawPairs: Bool = true
    public var sort: LibrarySort = .captureTime
    public var ascending = true
    /// Photos in private imports and collections: hidden unless View > Show Private Photos or
    /// Show Only Private Photos is on. Never saved with the session.
    public var privacy: PrivateVisibility = .hidden
    public var showsPrivate: Bool { privacy != .hidden }

    public init(scope: LibraryScope = .all, minRating: Int = 0, flag: Flag? = nil,
                colorLabel: ColorLabel? = nil, edited: Bool? = nil, notes: NotesFilter? = nil, text: String = "",
                groupsRawPairs: Bool = true, sort: LibrarySort = .captureTime, ascending: Bool = true,
                privacy: PrivateVisibility = .hidden) {
        self.scope = scope
        self.minRating = minRating
        self.flag = flag
        self.colorLabel = colorLabel
        self.edited = edited
        self.notes = notes
        self.text = text
        self.groupsRawPairs = groupsRawPairs
        self.sort = sort
        self.ascending = ascending
        self.privacy = privacy
    }

    /// Whether any rule hides photos (the scope and the order aside).
    public var isFiltering: Bool {
        minRating > 0 || flag != nil || colorLabel != nil || edited != nil || notes != nil
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rules in force, shortest first, for the Filmstrip's Filter button: "Picked", "★3+",
    /// "Red", "Edited", "“sea”".
    public var summary: [String] {
        var parts: [String] = []
        switch flag {
        case .picked?: parts.append("Picked")
        case .rejected?: parts.append("Rejected")
        case .none?: parts.append("Unflagged")
        case nil: break
        }
        if minRating > 0 { parts.append(minRating >= 5 ? "★5" : "★\(minRating)+") }
        if let colorLabel { parts.append(colorLabel.rawValue) }
        if let edited { parts.append(edited ? "Edited" : "Unedited") }
        if let notes { parts.append(notes.title) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts
    }

    /// Every rule off; keeps the scope, the order, pair grouping and private photos shown or hidden.
    public var cleared: LibraryFilter {
        LibraryFilter(scope: scope, groupsRawPairs: groupsRawPairs, sort: sort, ascending: ascending,
                      privacy: privacy)
    }
}

extension Catalog {
    public static func fetchAssetRows(_ db: Database, filter: LibraryFilter) throws -> [AssetRow] {
        var sql = """
            SELECT asset.id, asset.filename, asset.captureTime, asset.folderId,
                   metadata.rating, metadata.flag, metadata.colorLabel,
                   stackVersion.assetId AS stackParentId, stackVersion.kind AS stackKind,
                   stackVersion.name AS stackName,
                   (SELECT COUNT(*) FROM version derived
                    WHERE derived.assetId = asset.id AND derived.derivedAssetId IS NOT NULL) AS stackCount,
                   (SELECT COUNT(*) FROM cullGroupAsset member
                    WHERE member.cullGroupId = (SELECT cullGroupId FROM cullGroupAsset WHERE assetId = asset.id))
                    AS cullGroupSize,
                   \(filter.groupsRawPairs ? pairedFormats : "NULL") AS pairedFormats,
                   \(hasEdits) AS hasEdits,
                   (develop.json IS NOT NULL AND json_type(develop.json, '$.crop') IS NOT NULL) AS isCropped,
                   (develop.json IS NOT NULL AND IFNULL(json_array_length(develop.json, '$.masks'), 0) > 0) AS hasMasks,
                   \(hasNotesCondition()) AS hasNotes,
                   IFNULL((SELECT NOT volume.isOnline FROM folder JOIN volume ON volume.id = folder.volumeId
                           WHERE folder.id = asset.folderId), 0) AS isOffline,
                   (SELECT volume.mountPath || CASE folder.relativePath WHEN '' THEN '' ELSE '/' || folder.relativePath END
                           || '/' || asset.filename
                    FROM folder JOIN volume ON volume.id = folder.volumeId
                    WHERE folder.id = asset.folderId AND volume.kind = 'cloud' AND volume.isOnline) AS cloudPath,
                   0 AS notDownloaded
            FROM asset
            JOIN metadata ON metadata.assetId = asset.id
            LEFT JOIN version stackVersion ON stackVersion.derivedAssetId = asset.id
            LEFT JOIN asset stackParent ON stackParent.id = stackVersion.assetId
            LEFT JOIN metadata stackParentMetadata ON stackParentMetadata.assetId = stackParent.id
            LEFT JOIN developSettings develop ON develop.versionId =
                (SELECT id FROM version WHERE assetId = asset.id AND kind = 'master' LIMIT 1)
            """
        var conditions: [String] = filter.groupsRawPairs ? ["NOT " + FilePairs.hiddenCondition()] : []
        if let condition = privacyCondition(filter.privacy) { conditions.append(condition) }
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
        if let edited = filter.edited {
            conditions.append(edited ? hasEdits : "NOT \(hasEdits)")
        }
        switch filter.notes {
        case .hasNotes?: conditions.append(hasNotesCondition())
        case .noNotes?: conditions.append("NOT " + hasNotesCondition())
        case .openCheckboxes?:
            conditions.append("EXISTS (SELECT 1 FROM note WHERE note.assetId = asset.id AND note.text LIKE '%- [ ] %')")
        case nil: break
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
                                 WHERE keyword.name LIKE ?)
                 OR asset.id IN (SELECT note.assetId FROM note WHERE note.text LIKE ?))
                """)
            arguments.append(contentsOf: [pattern, pattern, pattern, pattern, pattern])
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        // Stacked edits sort right after the photo they came from: every key is the photo's own
        // for an original and the original's for a stacked version.
        let captureTime = "COALESCE(stackParent.captureTime, stackParent.importedAt, asset.captureTime, asset.importedAt)"
        let key: String
        switch filter.sort {
        case .captureTime: key = captureTime
        case .importOrder: key = "COALESCE(stackParent.importedAt, asset.importedAt)"
        case .fileName: key = "COALESCE(stackParent.filename, asset.filename) COLLATE NOCASE"
        case .rating: key = "COALESCE(stackParentMetadata.rating, metadata.rating)"
        case .editTime:
            key = """
                CASE WHEN stackParent.id IS NULL THEN develop.updatedAt
                     ELSE (SELECT parentDevelop.updatedAt FROM version parentMaster
                           JOIN developSettings parentDevelop ON parentDevelop.versionId = parentMaster.id
                           WHERE parentMaster.assetId = stackParent.id AND parentMaster.kind = 'master' LIMIT 1) END
                """
        }
        let direction = filter.ascending ? "ASC" : "DESC"
        sql += """
             ORDER BY \(key) \(direction), \(captureTime) \(direction),
                      COALESCE(stackParent.id, asset.id) \(direction), asset.id
            """
        var rows = try AssetRow.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        // Cloud drive folders (AT-079b): which originals are still only in the cloud. Reads each
        // file's flags on this Mac's disk (no download, no network); local photos skip it.
        for index in rows.indices {
            if let path = rows[index].cloudPath {
                rows[index].notDownloaded = CloudFiles.isPlaceholder(atPath: path)
            }
        }
        return rows
    }

    /// The master version's settings change something. Neutral settings are saved as only their
    /// schema version (see `DevelopSettings.encode`); "gradeDisabled" is an old key that may be 0.
    private static let hasEdits = """
        EXISTS (SELECT 1 FROM json_each(develop.json) WHERE key NOT IN ('schemaVersion', 'gradeDisabled'))
        """

    /// The extensions of the files hidden behind a pair's RAW, such as "JPG,HEIC".
    private static let pairedFormats = """
        (SELECT group_concat(upper(substr(sibling.filename, length(sibling.stem) + 2)), ',')
         FROM asset sibling
         WHERE asset.isRaw = 1 AND asset.virtualCopyOf IS NULL AND sibling.folderId = asset.folderId
           AND sibling.stem = asset.stem AND sibling.id != asset.id AND \(FilePairs.hiddenCondition("sibling")))
        """

    public func assetRows(filter: LibraryFilter) throws -> [AssetRow] {
        try writer.read { db in try Self.fetchAssetRows(db, filter: filter) }
    }
}
