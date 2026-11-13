import Foundation
import GRDB

/// What a photo's library fields are at one moment: rating, flag, label, title, caption,
/// keywords and collections. Agent changes (AT-050c) record it before and after, so an agent's
/// change can be undone only while it is still the latest one on those photos.
public struct LibraryState: Hashable, Sendable {
    public var rating: Int
    public var flag: Flag
    public var colorLabel: ColorLabel?
    public var title: String?
    public var caption: String?
    /// Sorted, compared without case.
    public var keywords: [String]
    public var collectionIDs: Set<Int64>

    public init(rating: Int = 0, flag: Flag = .none, colorLabel: ColorLabel? = nil, title: String? = nil,
                caption: String? = nil, keywords: [String] = [], collectionIDs: Set<Int64> = []) {
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.title = title
        self.caption = caption
        self.keywords = keywords
        self.collectionIDs = collectionIDs
    }
}

extension Catalog {
    /// Each photo's library state. Photos that no longer exist are left out.
    public func libraryStates(for assetIDs: [Int64]) throws -> [Int64: LibraryState] {
        guard !assetIDs.isEmpty else { return [:] }
        return try writer.read { db in
            var states: [Int64: LibraryState] = [:]
            for metadata in try AssetMetadata.filter(keys: assetIDs).fetchAll(db) {
                states[metadata.assetId] = LibraryState(
                    rating: metadata.rating, flag: metadata.flag, colorLabel: metadata.colorLabel,
                    title: metadata.title, caption: metadata.caption)
            }
            let ids = Array(states.keys)
            let keywordRows = try Row.fetchAll(db, sql: """
                SELECT assetKeyword.assetId AS assetId, keyword.name AS name FROM assetKeyword
                JOIN keyword ON keyword.id = assetKeyword.keywordId
                WHERE assetKeyword.assetId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
            for row in keywordRows {
                let id: Int64 = row["assetId"]
                states[id]?.keywords.append(row["name"])
            }
            for membership in try CollectionAsset.filter(ids.contains(Column("assetId"))).fetchAll(db) {
                states[membership.assetId]?.collectionIDs.insert(membership.collectionId)
            }
            for id in ids {
                states[id]?.keywords.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            return states
        }
    }

    /// Puts photos back to the given states in one transaction: all of them, or none if
    /// anything fails. Collections deleted since are skipped. Marks their sidecars to write.
    public func restoreLibraryStates(_ states: [Int64: LibraryState]) throws {
        guard !states.isEmpty else { return }
        try writer.write { db in
            let liveCollections = Set(try Int64.fetchAll(db, sql: "SELECT id FROM collection"))
            for (assetID, state) in states {
                try AssetMetadata.filter(key: assetID).updateAll(
                    db,
                    Column("rating").set(to: state.rating),
                    Column("flag").set(to: state.flag.rawValue),
                    Column("colorLabel").set(to: state.colorLabel?.rawValue),
                    Column("title").set(to: state.title),
                    Column("caption").set(to: state.caption),
                    Column("xmpDirty").set(to: true))
                try AssetKeyword.filter(Column("assetId") == assetID).deleteAll(db)
                try Self.addKeywords(db, names: state.keywords, to: [assetID])
                try CollectionAsset.filter(Column("assetId") == assetID).deleteAll(db)
                for collectionID in state.collectionIDs where liveCollections.contains(collectionID) {
                    try CollectionAsset(collectionId: collectionID, assetId: assetID).insert(db, onConflict: .ignore)
                }
            }
        }
    }

    /// Sets the color label (nil clears it), unlike `toggleColorLabel`, which clears a label the
    /// photos already have.
    public func setColorLabel(_ label: ColorLabel?, for assetIDs: [Int64]) throws {
        _ = try writer.write { db in
            try AssetMetadata.filter(keys: assetIDs)
                .updateAll(db, Column("colorLabel").set(to: label?.rawValue), Column("xmpDirty").set(to: true))
        }
    }

    /// Takes keywords off photos (compared without case). The keywords themselves stay.
    public func removeKeywords(_ names: [String], from assetIDs: [Int64]) throws {
        let lowered = Set(names.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        guard !lowered.isEmpty, !assetIDs.isEmpty else { return }
        try writer.write { db in
            let keywordIDs = try Keyword.fetchAll(db)
                .filter { lowered.contains($0.name.lowercased()) }
                .compactMap(\.id)
            guard !keywordIDs.isEmpty else { return }
            try AssetKeyword
                .filter(assetIDs.contains(Column("assetId")) && keywordIDs.contains(Column("keywordId")))
                .deleteAll(db)
            try AssetMetadata.filter(keys: assetIDs).updateAll(db, Column("xmpDirty").set(to: true))
        }
    }

    /// Sets the title or caption of each photo, leaving the other one as it is. An empty
    /// string clears it.
    public func setTitle(_ title: String?, orCaption caption: String?, for assetIDs: [Int64]) throws {
        guard title != nil || caption != nil else { return }
        _ = try writer.write { db in
            var assignments: [ColumnAssignment] = [Column("xmpDirty").set(to: true)]
            if let title { assignments.append(Column("title").set(to: title.nilIfBlank)) }
            if let caption { assignments.append(Column("caption").set(to: caption.nilIfBlank)) }
            try AssetMetadata.filter(keys: assetIDs).updateAll(db, assignments)
        }
    }
}
