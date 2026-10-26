import Foundation
import GRDB

// Ratings, flags, labels, keywords and collections. Every edit marks the XMP sidecar dirty.

extension Catalog {
    public func setRating(_ rating: Int, for assetIDs: [Int64]) throws {
        let rating = min(max(rating, 0), 5)
        _ = try writer.write { db in
            try AssetMetadata.filter(keys: assetIDs)
                .updateAll(db, Column("rating").set(to: rating), Column("xmpDirty").set(to: true))
        }
    }

    public func setFlag(_ flag: Flag, for assetIDs: [Int64]) throws {
        _ = try writer.write { db in
            try AssetMetadata.filter(keys: assetIDs)
                .updateAll(db, Column("flag").set(to: flag.rawValue), Column("xmpDirty").set(to: true))
        }
    }

    /// Passing the label a photo already has clears it, as in Lightroom.
    public func toggleColorLabel(_ label: ColorLabel, for assetIDs: [Int64]) throws {
        try writer.write { db in
            let current = try AssetMetadata.filter(keys: assetIDs).fetchAll(db)
            let allHaveIt = !current.isEmpty && current.allSatisfy { $0.colorLabel == label }
            let newValue: String? = allHaveIt ? nil : label.rawValue
            try AssetMetadata.filter(keys: assetIDs)
                .updateAll(db, Column("colorLabel").set(to: newValue),
                           Column("xmpDirty").set(to: true))
        }
    }

    public func setTitle(_ title: String?, caption: String?, for assetID: Int64) throws {
        _ = try writer.write { db in
            try AssetMetadata.filter(key: assetID)
                .updateAll(db, Column("title").set(to: title?.nilIfBlank),
                           Column("caption").set(to: caption?.nilIfBlank),
                           Column("xmpDirty").set(to: true))
        }
    }

    // MARK: Keywords

    static func keywordID(_ db: Database, name: String) throws -> Int64 {
        if let existing = try Keyword
            .filter(Column("name").collating(.nocase) == name && Column("parentId") == nil)
            .fetchOne(db), let id = existing.id {
            return id
        }
        var keyword = Keyword(id: nil, name: name, parentId: nil)
        try keyword.insert(db)
        return keyword.id!
    }

    static func addKeywords(_ db: Database, names: [String], to assetIDs: [Int64]) throws {
        for name in names.cleanedKeywords {
            let keywordID = try keywordID(db, name: name)
            for assetID in assetIDs {
                try AssetKeyword(assetId: assetID, keywordId: keywordID).insert(db, onConflict: .ignore)
            }
        }
    }

    public func addKeywords(_ names: [String], to assetIDs: [Int64]) throws {
        try writer.write { db in
            try Self.addKeywords(db, names: names, to: assetIDs)
            try AssetMetadata.filter(keys: assetIDs).updateAll(db, Column("xmpDirty").set(to: true))
        }
    }

    /// Replaces the keyword list of each photo.
    public func setKeywords(_ names: [String], for assetIDs: [Int64]) throws {
        try writer.write { db in
            try AssetKeyword.filter(assetIDs.contains(Column("assetId"))).deleteAll(db)
            try Self.addKeywords(db, names: names, to: assetIDs)
            try AssetMetadata.filter(keys: assetIDs).updateAll(db, Column("xmpDirty").set(to: true))
        }
    }

    static func keywords(_ db: Database, for assetID: Int64) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT keyword.name FROM keyword
            JOIN assetKeyword ON assetKeyword.keywordId = keyword.id
            WHERE assetKeyword.assetId = ?
            ORDER BY keyword.name COLLATE NOCASE
            """, arguments: [assetID])
    }

    public func keywords(for assetID: Int64) throws -> [String] {
        try writer.read { db in try Self.keywords(db, for: assetID) }
    }

    // MARK: Collections

    @discardableResult
    public func createCollection(named name: String, parentId: Int64? = nil) throws -> PhotoCollection {
        try writer.write { db in
            var collection = PhotoCollection(name: name, parentId: parentId)
            try collection.insert(db)
            return collection
        }
    }

    public func deleteCollection(_ id: Int64) throws {
        _ = try writer.write { db in try PhotoCollection.deleteOne(db, key: id) }
    }

    public func addAssets(_ assetIDs: [Int64], toCollection collectionID: Int64) throws {
        try writer.write { db in
            for assetID in assetIDs {
                try CollectionAsset(collectionId: collectionID, assetId: assetID).insert(db, onConflict: .ignore)
            }
        }
    }

    public func removeAssets(_ assetIDs: [Int64], fromCollection collectionID: Int64) throws {
        _ = try writer.write { db in
            try CollectionAsset
                .filter(Column("collectionId") == collectionID && assetIDs.contains(Column("assetId")))
                .deleteAll(db)
        }
    }

    // MARK: Detail

    public static func fetchDetail(_ db: Database, assetID: Int64) throws -> AssetDetail? {
        guard let asset = try Asset.fetchOne(db, key: assetID),
              let metadata = try AssetMetadata.fetchOne(db, key: assetID),
              let folder = try Folder.fetchOne(db, key: asset.folderId),
              let volume = try Volume.fetchOne(db, key: folder.volumeId) else { return nil }
        return AssetDetail(asset: asset, metadata: metadata,
                           keywords: try keywords(db, for: assetID),
                           folder: folder, volume: volume,
                           fileURL: fileURL(volume: volume, folder: folder, filename: asset.filename))
    }

    public func detail(for assetID: Int64) throws -> AssetDetail? {
        try writer.read { db in try Self.fetchDetail(db, assetID: assetID) }
    }

    public func fileURL(for assetID: Int64) throws -> URL? {
        try detail(for: assetID)?.fileURL
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Array where Element == String {
    /// Trimmed, non-empty, de-duplicated (case-insensitive) keyword names.
    var cleanedKeywords: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in self {
            guard let name = raw.nilIfBlank else { continue }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }
}
