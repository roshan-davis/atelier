import Foundation
import GRDB

/// When the original changed (AT-079c part 3, PRD "Cache of remote originals"). A photo on a
/// network share whose file no longer has the content hash cataloged at import is marked here,
/// and every command that needs its pixels stops for it and asks: Develop with a banner over the
/// photo, Export and Edit In with one sheet. Nothing silently uses either file. The choices are
/// Use the New File (the catalog takes the new hash), Use the Kept Copy (only when the photo was
/// kept with Keep on This Mac; the photo stays marked) and Skip.
public struct OriginalChange: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "originalChange"
    /// The photo whose file changed (a master; virtual copies share it).
    public var assetId: Int64
    public var newHash: String
    public var newSize: Int64
    public var foundAt: Date
}

/// Thrown by a command that found the original changed: what the sheet and the banner show.
public struct OriginalChangedError: LocalizedError, Sendable, Hashable {
    /// The photo the command ran on (a virtual copy keeps its own id here).
    public var assetID: Int64
    /// The photo whose file changed.
    public var fileID: Int64
    public var filename: String
    /// "megham": the share's location name.
    public var place: String
    /// A copy kept with Keep on This Mac, from before the change, is on this Mac.
    public var hasKeptCopy: Bool

    public init(assetID: Int64, fileID: Int64, filename: String, place: String, hasKeptCopy: Bool) {
        self.assetID = assetID
        self.fileID = fileID
        self.filename = filename
        self.place = place
        self.hasKeptCopy = hasKeptCopy
    }

    public var errorDescription: String? {
        "\(filename) changed on \(place) since it was imported, so Atelier didn't use it."
    }
}

/// The file a command reads a photo from, and whether it could be checked against the share.
public struct CheckedSource: Sendable, Hashable {
    public var url: URL
    /// False for a copy on this Mac used while its share is offline.
    public var checked: Bool
    /// When an unchecked copy was stored.
    public var storedAt: Date?
    public var place: String

    /// "DSC_1.NEF: from the copy on this Mac from Nov 17; megham was offline, so changes there
    /// couldn't be checked." Nil when checked.
    public func note(filename: String) -> String? {
        guard !checked else { return nil }
        let day = storedAt.map { " from " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        return "\(filename): from the copy on this Mac\(day); \(place) was offline, so changes there couldn't be checked."
    }
}

extension Catalog {
    static func registerOriginalChangeMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13-original-changes") { db in
            try db.create(table: OriginalChange.databaseTableName) { t in
                t.primaryKey("assetId", .integer).references("asset", onDelete: .cascade)
                t.column("newHash", .text).notNull()
                t.column("newSize", .integer).notNull()
                t.column("foundAt", .datetime).notNull()
            }
        }
    }

    public func originalChange(for assetID: Int64) throws -> OriginalChange? {
        let fileID = try originalID(for: assetID)
        return try writer.read { db in try OriginalChange.fetchOne(db, key: fileID) }
    }

    /// Ids of the photos (masters) marked changed among `assetIDs`' files.
    public func changedOriginals(among assetIDs: [Int64]) throws -> Set<Int64> {
        guard !assetIDs.isEmpty else { return [] }
        return try writer.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT asset.id FROM asset JOIN originalChange ON originalChange.assetId = COALESCE(asset.virtualCopyOf, asset.id)
                WHERE asset.id IN (\(databaseQuestionMarks(count: assetIDs.count)))
                """, arguments: StatementArguments(assetIDs)))
        }
    }

    func markOriginalChanged(_ fileID: Int64, newHash: String, newSize: Int64) throws {
        try writer.write { db in
            try OriginalChange(assetId: fileID, newHash: newHash, newSize: newSize, foundAt: Date()).save(db)
        }
    }

    /// Use the New File: the photo (and its virtual copies) takes the new file's hash, size and
    /// date; the mark goes. Edits stay; previews are made again by the caller.
    public func acceptNewOriginal(_ fileID: Int64, newHash: String, size: Int64, modified: Date?) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE asset SET contentHash = ?, fileSize = ?, modifiedAt = ? WHERE id = ? OR virtualCopyOf = ?
                """, arguments: [newHash, size, modified, fileID, fileID])
            _ = try OriginalChange.deleteOne(db, key: fileID)
        }
    }

    /// The share's name for messages: its location's name, else the volume's.
    func placeName(for volume: Volume) throws -> String {
        guard let id = volume.id else { return volume.name }
        return try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT name FROM storageLocation WHERE volumeId = ? AND rootPath = '' ORDER BY id LIMIT 1
                """, arguments: [id])
        } ?? volume.name
    }

    /// The file to render a photo from for Export, Edit In and AI (AT-079c). A photo on a share goes
    /// through the cache of originals: its checked copy, else the original read once into the cache
    /// with its hash checked; with the share offline, its copy is used unchecked (the note says so).
    /// A photo whose file changed since import throws `OriginalChangedError`, unless the person
    /// chose its kept copy this session (Use the Kept Copy). Other photos read their original.
    public func checkedSource(for assetID: Int64, cache: OriginalCache?) throws -> CheckedSource {
        guard let detail = try detail(for: assetID) else { throw CocoaError(.fileNoSuchFile) }
        let fileID = detail.asset.virtualCopyOf ?? assetID
        let place = (try? placeName(for: detail.volume)) ?? detail.volume.name
        let offline = CocoaError(.fileReadNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "The original is offline. Connect its drive and try again."])
        guard detail.volume.kind == .nas, let cache else {
            guard let url = detail.fileURL, FileManager.default.fileExists(atPath: url.path) else { throw offline }
            return CheckedSource(url: url, checked: true, place: place)
        }
        if let ready = cache.readyCopy(for: fileID) { return CheckedSource(url: ready, checked: true, place: place) }
        let changed = { (kept: Bool) in
            OriginalChangedError(assetID: assetID, fileID: fileID, filename: detail.asset.filename, place: place, hasKeptCopy: kept)
        }
        let hash = detail.asset.contentHash
        if try originalChange(for: fileID) != nil {
            throw changed(cache.keptCopyExists(for: fileID, contentHash: hash))
        }
        let source = detail.fileURL
        if let copy = try cache.copy(for: fileID, contentHash: hash, source: source.flatMap(OriginalCache.SourceInfo.init)) {
            return CheckedSource(url: copy.url, checked: copy.checked, storedAt: copy.storedAt, place: place)
        }
        guard let source else { throw offline }
        switch try cache.store(fileID, from: source, contentHash: hash) {
        case .stored(let url):
            return CheckedSource(url: url, checked: true, place: place)
        case .changed(let newHash):
            let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try markOriginalChanged(fileID, newHash: newHash, newSize: size)
            throw changed(cache.keptCopyExists(for: fileID, contentHash: hash))
        }
    }

    /// Records that a read found the file changed (Develop's own read into the cache).
    public func noteOriginalChanged(_ assetID: Int64, newHash: String, source: URL?) throws {
        let size = Int64((try? source?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try markOriginalChanged(try originalID(for: assetID), newHash: newHash, newSize: size)
    }

    /// Use the New File: reads the new file into the cache (still kept if it was), checks it is
    /// the file that was found, and the catalog takes its hash. Throws `OriginalChangedError` when
    /// it changed yet again (the mark then has the newest hash).
    @discardableResult
    public func useNewOriginal(_ assetID: Int64, cache: OriginalCache?, progress: ((Int64) -> Void)? = nil) throws -> URL {
        guard let detail = try detail(for: assetID) else { throw CocoaError(.fileNoSuchFile) }
        let fileID = detail.asset.virtualCopyOf ?? assetID
        guard let source = detail.fileURL else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The original is offline. Connect its drive and try again."])
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        guard let cache, detail.volume.kind == .nas else {
            try acceptNewOriginal(fileID, newHash: try FileHasher.sha256(of: source), size: size,
                                  modified: values.contentModificationDate)
            return source
        }
        let expected = try originalChange(for: fileID)?.newHash ?? detail.asset.contentHash
        switch try cache.store(fileID, from: source, contentHash: expected, progress: progress) {
        case .stored(let url):
            try acceptNewOriginal(fileID, newHash: expected, size: size, modified: values.contentModificationDate)
            return url
        case .changed(let newest):
            try markOriginalChanged(fileID, newHash: newest, newSize: size)
            let place = (try? placeName(for: detail.volume)) ?? detail.volume.name
            throw OriginalChangedError(assetID: assetID, fileID: fileID, filename: detail.asset.filename, place: place,
                                       hasKeptCopy: cache.keptCopyExists(for: fileID, contentHash: detail.asset.contentHash))
        }
    }

    /// Use the Kept Copy: commands read the copy kept on this Mac (from before the change) for the
    /// rest of this session; the photo stays marked. Nil when there is no kept copy.
    public func useKeptCopy(_ assetID: Int64, cache: OriginalCache) throws -> URL? {
        guard let detail = try detail(for: assetID) else { return nil }
        return cache.useKeptCopy(for: detail.asset.virtualCopyOf ?? assetID, contentHash: detail.asset.contentHash)
    }
}
