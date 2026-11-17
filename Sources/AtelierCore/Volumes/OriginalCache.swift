import Foundation
import GRDB

/// The cache of remote originals (AT-079c, NAS-2 of the Nov 9 NAS review). A referenced original on
/// a network share is read once, start to end, into `~/Library/Caches`, and opened from there, so
/// Develop, Loupe and Export never read the photo over the network twice. On disk only, bounded by
/// bytes (the user's size, at most a quarter of free space), oldest-opened let go first; copies kept
/// with Keep on This Mac are never let go and don't count toward the size (PRD "Cache of remote
/// originals").
///
/// Fresh or not: each copy records the source's size and modification date and is checked against
/// the catalog's content hash when it is stored. When the source is reachable, a copy is used only
/// if size and date still match (one metadata read); when it isn't, the copy is used and the caller
/// is told it couldn't be checked.
///
/// The index is a small SQLite file beside the copies, never the catalog: clearing the folder (or
/// macOS clearing Caches) loses nothing but copies.
public final class OriginalCache: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
        public static let databaseTableName = "entry"
        public var assetId: Int64
        public var contentHash: String
        /// The copy's file name in the cache folder.
        public var file: String
        public var bytes: Int64
        public var sourceSize: Int64
        public var sourceModified: Date?
        public var storedAt: Date
        public var lastOpened: Date
        /// Keep on This Mac: never let go to stay within the size.
        public var pinned: Bool
    }

    /// What a source file is now: one metadata read, no data.
    public struct SourceInfo: Sendable, Hashable {
        public var size: Int64
        public var modified: Date?

        public init(size: Int64, modified: Date?) {
            self.size = size
            self.modified = modified
        }

        public init?(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            self.init(size: Int64(size), modified: values.contentModificationDate)
        }

        func matches(_ entry: Entry) -> Bool {
            guard size == entry.sourceSize else { return false }
            switch (modified, entry.sourceModified) {
            case let (now?, then?): return abs(now.timeIntervalSince(then)) < 1
            case (nil, nil): return true
            default: return false
            }
        }
    }

    /// A copy that can be used now. `checked` is false when the source couldn't be reached.
    public struct Copy: Sendable, Hashable {
        public var url: URL
        public var checked: Bool
        public var storedAt: Date
    }

    public enum StoreResult: Sendable, Equatable {
        case stored(URL)
        /// The file's bytes differ from what was cataloged at import: nothing was kept.
        case changed(newHash: String)
    }

    public struct Usage: Sendable, Equatable {
        public var cachedBytes: Int64 = 0
        public var cachedCount = 0
        public var keptBytes: Int64 = 0
        public var keptCount = 0
    }

    public static let defaultLimit: Int64 = 20 * 1_000_000_000

    public let root: URL
    private let index: DatabaseQueue
    private let lock = NSLock()
    /// Copies checked or stored this session, for readers that can't wait (`readableURL`).
    private var ready: [Int64: URL] = [:]
    /// The photo open in Develop: its copy is never let go, whatever is stored after it.
    private var open: Int64?
    private var limit: Int64
    /// Free space of the cache's disk, for the "at most a quarter" rule; tests pass their own.
    private let freeSpace: @Sendable () -> Int64

    /// `~/Library/Caches/Atelier/Originals`.
    public static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Atelier/Originals", isDirectory: true)
    }

    public init(root: URL = OriginalCache.defaultRoot, limit: Int64 = OriginalCache.defaultLimit,
                freeSpace: (@Sendable () -> Int64)? = nil) throws {
        self.root = root
        self.limit = limit
        try FileManager.default.createDirectory(at: root.appendingPathComponent("partial", isDirectory: true),
                                                withIntermediateDirectories: true)
        index = try DatabaseQueue(path: root.appendingPathComponent("index.sqlite").path)
        let folder = root
        self.freeSpace = freeSpace ?? {
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage ?? .max
        }
        try index.write { db in
            try db.create(table: Entry.databaseTableName, ifNotExists: true) { t in
                t.primaryKey("assetId", .integer)
                t.column("contentHash", .text).notNull()
                t.column("file", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("sourceSize", .integer).notNull()
                t.column("sourceModified", .datetime)
                t.column("storedAt", .datetime).notNull()
                t.column("lastOpened", .datetime).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
        }
        // A copy interrupted by a quit is never trusted.
        let partial = root.appendingPathComponent("partial", isDirectory: true)
        for leftover in (try? FileManager.default.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    // MARK: Size

    /// Settings > Storage > Cache size.
    public var limitBytes: Int64 {
        get { lock.withLock { limit } }
        set {
            lock.withLock { limit = max(0, newValue) }
            try? evict()
        }
    }

    /// The size actually allowed: the user's, but at most a quarter of what would be free with the
    /// cache emptied (so the limit doesn't shrink as the cache fills).
    public func effectiveLimit() throws -> Int64 {
        let cached = try usage().cachedBytes
        let free = freeSpace()
        let quarter = free == .max ? Int64.max : (free + cached) / 4
        return min(limitBytes, quarter)
    }

    public func usage() throws -> Usage {
        try index.read { db in
            var usage = Usage()
            for row in try Row.fetchAll(db, sql: "SELECT pinned, COUNT(*) AS n, IFNULL(SUM(bytes), 0) AS b FROM entry GROUP BY pinned") {
                let pinned: Bool = row["pinned"]
                if pinned {
                    usage.keptCount = row["n"]
                    usage.keptBytes = row["b"]
                } else {
                    usage.cachedCount = row["n"]
                    usage.cachedBytes = row["b"]
                }
            }
            return usage
        }
    }

    /// Develop sets the photo it has open (nil when none).
    public var inUse: Int64? {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }

    // MARK: Using a copy

    public func entry(for assetID: Int64) throws -> Entry? {
        try index.read { db in try Entry.fetchOne(db, key: assetID) }
    }

    /// The copy checked or stored this session, without any file or network access. Readers that
    /// can't wait (a render that is already running) use it; `copy(for:…)` is what checks.
    public func readyCopy(for assetID: Int64) -> URL? {
        lock.withLock { ready[assetID] }
    }

    /// The copy to use for a photo, if there is a good one. `source` is the original's size and date
    /// read just now, nil when it can't be reached. A copy that no longer matches a reachable source
    /// is dropped (unless kept) and nil is returned, so the caller reads the original again.
    public func copy(for assetID: Int64, contentHash: String, source: SourceInfo?) throws -> Copy? {
        guard let entry = try entry(for: assetID) else { return nil }
        let url = root.appendingPathComponent(entry.file)
        guard entry.contentHash == contentHash, FileManager.default.fileExists(atPath: url.path) else {
            try drop(assetID)
            return nil
        }
        if let source, !source.matches(entry) {
            // Changed on the source: an unkept copy goes; a kept one stays, set aside, until the
            // new file is read and checked (PRD "Fresh or not").
            if !entry.pinned { try drop(assetID) }
            lock.withLock { _ = ready.removeValue(forKey: assetID) }
            return nil
        }
        try index.write { db in
            try db.execute(sql: "UPDATE entry SET lastOpened = ? WHERE assetId = ?", arguments: [Date(), assetID])
        }
        lock.withLock { ready[assetID] = url }
        return Copy(url: url, checked: source != nil, storedAt: entry.storedAt)
    }

    // MARK: Storing

    /// Reads `source` once, start to end, into the cache, hashing as it reads. The copy is kept only
    /// if its hash is the catalog's; otherwise `.changed` and nothing is kept. Streams in 8 MB
    /// chunks, so memory stays flat whatever the file's size. Throws `CancellationError` when the
    /// task is cancelled. `shouldPause` lets a prefetch step aside for the photo being opened; a
    /// prefetch (`readAhead`) also stops as soon as another read stored the same photo, so a photo
    /// opened while it was being read ahead is never read over the network twice.
    @discardableResult
    public func store(_ assetID: Int64, from source: URL, contentHash: String, pinned: Bool = false,
                      readAhead: Bool = false,
                      progress: ((Int64) -> Void)? = nil, shouldPause: (() -> Bool)? = nil) throws -> StoreResult {
        if readAhead, let existing = readyCopy(for: assetID) { return .stored(existing) }
        guard let info = SourceInfo(source) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]) }
        let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension.lowercased()
        let partial = root.appendingPathComponent("partial/\(assetID)-\(UUID().uuidString)\(ext)")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let hash: String
        do {
            hash = try Importer.copyHashing(source, to: fd, progress: progress, shouldPause: shouldPause,
                                            shouldStop: readAhead ? { [weak self] in self?.readyCopy(for: assetID) != nil } : nil)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if readAhead, error is CancellationError, let existing = readyCopy(for: assetID) { return .stored(existing) }
            throw error
        }
        guard hash == contentHash else {
            try? FileManager.default.removeItem(at: partial)
            if let entry = try entry(for: assetID), !entry.pinned { try drop(assetID) }
            return .changed(newHash: hash)
        }
        let name = "\(assetID)\(ext)"
        let destination = root.appendingPathComponent(name)
        let wasPinned = (try entry(for: assetID))?.pinned ?? false
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        let now = Date()
        let entry = Entry(assetId: assetID, contentHash: contentHash, file: name, bytes: info.size,
                          sourceSize: info.size, sourceModified: info.modified, storedAt: now, lastOpened: now,
                          pinned: pinned || wasPinned)
        try index.write { db in try entry.save(db) }
        lock.withLock { ready[assetID] = destination }
        try evict(sparing: assetID)
        return .stored(destination)
    }

    // MARK: Letting go

    /// Lets the oldest-opened unkept copies go until the cache fits its size. `sparing` (the copy
    /// just stored) and the photo open in Develop (`inUse`) stay, even when over the size alone.
    public func evict(sparing: Int64? = nil) throws {
        let allowed = try effectiveLimit()
        var total = try usage().cachedBytes
        guard total > allowed else { return }
        let candidates = try index.read { db in
            try Entry.filter(Column("pinned") == false).order(Column("lastOpened")).fetchAll(db)
        }
        let open = inUse
        for entry in candidates where total > allowed && entry.assetId != sparing && entry.assetId != open {
            try drop(entry.assetId)
            total -= entry.bytes
        }
    }

    /// Keep on This Mac / Free Up Space. Freeing makes the copies ordinary cached ones, which then
    /// go as the size requires.
    public func setKept(_ assetIDs: [Int64], _ kept: Bool) throws {
        try index.write { db in
            for id in assetIDs {
                try db.execute(sql: "UPDATE entry SET pinned = ? WHERE assetId = ?", arguments: [kept, id])
            }
        }
        if !kept { try evict() }
    }

    /// Clear Cache: removes the cached copies, and the kept ones too only when asked. `sparing` is the
    /// photo open in Develop, which is reading its copy.
    public func clear(includingKept: Bool = false, sparing: Int64? = nil) throws {
        let entries = try index.read { db in
            includingKept ? try Entry.fetchAll(db) : try Entry.filter(Column("pinned") == false).fetchAll(db)
        }
        let open = inUse
        for entry in entries where entry.assetId != sparing && entry.assetId != open { try drop(entry.assetId) }
    }

    public func drop(_ assetID: Int64) throws {
        if let entry = try entry(for: assetID) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.file))
        }
        _ = try index.write { db in try Entry.deleteOne(db, key: assetID) }
        lock.withLock { _ = ready.removeValue(forKey: assetID) }
    }
}

extension Catalog {
    /// The file to read a photo from: its copy on this Mac when one was checked this session
    /// (AT-079c), else the original where it is. Readers that open the original for other apps
    /// (Edit In, Show in Finder) use `fileURL(for:)` instead.
    public func readableURL(for assetID: Int64, cache: OriginalCache?) throws -> URL? {
        if let copy = cache?.readyCopy(for: assetID) { return copy }
        return try fileURL(for: assetID)
    }
}
