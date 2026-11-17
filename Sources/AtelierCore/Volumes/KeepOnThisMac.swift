import Foundation
import GRDB

/// Keep on This Mac and Free Up Space (AT-079c part 2, PRD "Cache of remote originals"): the
/// originals of a folder, import, collection or location on a network share are read into the
/// cache of originals and pinned, so they open at full quality with the share offline. Pinned
/// copies are never let go to stay within the cache size; they have their own total and only the
/// 10% free-space rule bounds them. Cloud drive folders are left to their provider's own "keep
/// downloaded", because the cache never holds a second copy of a cloud file.
public enum KeepPlace: Sendable, Hashable {
    case folder(Int64)
    case importGroup(Int64)
    case collection(Int64)
    case location(Int64)
}

/// One original on a network share, as the catalog knows it. Virtual copies share their master's
/// file, so they are folded into it.
public struct ShareOriginal: Sendable, Hashable {
    public var assetId: Int64
    public var filename: String
    public var contentHash: String
    public var fileSize: Int64
    /// Where it is now; nil while the share is offline.
    public var fileURL: URL?
    public var volumeName: String

    public init(assetId: Int64, filename: String, contentHash: String, fileSize: Int64, fileURL: URL?, volumeName: String) {
        self.assetId = assetId
        self.filename = filename
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.fileURL = fileURL
        self.volumeName = volumeName
    }
}

/// What Keep on This Mac would do, worked out before anything is read, so the size can be shown
/// first and the request refused when it wouldn't fit.
public struct KeepPlan: Sendable, Equatable {
    /// Already stored and matching the catalog: pinned at once, nothing read.
    public var toPin: [Int64] = []
    /// To read from the share.
    public var toRead: [ShareOriginal] = []
    public var alreadyKept = 0
    /// On a share that isn't connected now.
    public var offline = 0
    /// Every photo in the place, share or not (for "none of these are on a share").
    public var photoCount = 0
    public var readBytes: Int64 = 0
    /// How much more free space reading would need, or nil when it fits. Atelier leaves at least
    /// 10% of the disk free (PRD).
    public var shortBy: Int64?

    public var fits: Bool { shortBy == nil }
    public var isEmpty: Bool { toPin.isEmpty && toRead.isEmpty }
    public var shareCount: Int { toPin.count + toRead.count + alreadyKept + offline }
    /// The share names the read comes from ("megham").
    public var sources: [String] { Array(Set(toRead.map(\.volumeName))).sorted() }

    /// The 10% rule: reading `bytes` must leave a tenth of the disk free.
    public static func shortfall(reading bytes: Int64, free: Int64, capacity: Int64) -> Int64? {
        guard bytes > 0, capacity > 0 else { return nil }
        let floor = capacity / 10
        let after = free - bytes
        return after >= floor ? nil : floor - after
    }
}

extension Catalog {
    /// The originals on network shares behind a place (masters only; a virtual copy counts as its
    /// master), and how many photos the place holds in all.
    public func shareOriginals(in place: KeepPlace) throws -> (originals: [ShareOriginal], photoCount: Int) {
        try writer.read { db in
            let condition: String
            var arguments: StatementArguments = []
            switch place {
            case .folder(let id):
                condition = "asset.folderId = ?"
                arguments += [id]
            case .importGroup(let id):
                condition = "asset.id IN (SELECT assetId FROM importGroupAsset WHERE importGroupId = ?)"
                arguments += [id]
            case .collection(let id):
                condition = "asset.id IN (SELECT assetId FROM collectionAsset WHERE collectionId = ?)"
                arguments += [id]
            case .location(let id):
                guard let location = try StorageLocation.fetchOne(db, key: id), let volumeId = location.volumeId else {
                    return ([], 0)
                }
                if location.rootPath.isEmpty {
                    condition = "asset.folderId IN (SELECT id FROM folder WHERE volumeId = ?)"
                    arguments += [volumeId]
                } else {
                    condition = """
                        asset.folderId IN (SELECT id FROM folder WHERE volumeId = ?
                            AND (relativePath = ? OR substr(relativePath, 1, ?) = ?))
                        """
                    let prefix = location.rootPath + "/"
                    arguments += [volumeId, location.rootPath, prefix.count, prefix]
                }
            }
            let ids = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT COALESCE(asset.virtualCopyOf, asset.id) FROM asset WHERE \(condition)
                """, arguments: arguments)
            guard !ids.isEmpty else { return ([], 0) }
            let volumes = Dictionary(uniqueKeysWithValues: try Volume.filter(Column("kind") == VolumeKind.nas.rawValue)
                .fetchAll(db).compactMap { volume in volume.id.map { ($0, volume) } })
            guard !volumes.isEmpty else { return ([], ids.count) }
            let assets = try Asset.filter(keys: ids).fetchAll(db)
            let folders = Dictionary(uniqueKeysWithValues: try Folder.filter(keys: Set(assets.map(\.folderId)))
                .fetchAll(db).compactMap { folder in folder.id.map { ($0, folder) } })
            var originals: [ShareOriginal] = []
            for asset in assets {
                guard let id = asset.id, let folder = folders[asset.folderId], let volume = volumes[folder.volumeId] else { continue }
                originals.append(ShareOriginal(assetId: id, filename: asset.filename, contentHash: asset.contentHash,
                                               fileSize: asset.fileSize,
                                               fileURL: Self.fileURL(volume: volume, folder: folder, filename: asset.filename),
                                               volumeName: volume.name))
            }
            return (originals.sorted { $0.assetId < $1.assetId }, ids.count)
        }
    }

    /// The id the cache of originals files a photo under: a virtual copy's master, so a virtual
    /// copy never stores the same file twice.
    public func originalID(for assetID: Int64) throws -> Int64 {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(virtualCopyOf, id) FROM asset WHERE id = ?", arguments: [assetID])
        } ?? assetID
    }
}

extension OriginalCache {
    /// Works out Keep on This Mac for `originals` without reading any photo: which copies are
    /// already here (pinned at once), which must be read, how many bytes, and whether that leaves
    /// 10% of the disk free. `free` and `capacity` are this Mac's disk (the cache's).
    public func keepPlan(for originals: [ShareOriginal], photoCount: Int, free: Int64, capacity: Int64) throws -> KeepPlan {
        var plan = KeepPlan(photoCount: photoCount)
        let entries = try entries(for: originals.map(\.assetId))
        for original in originals {
            if let entry = entries[original.assetId], entry.contentHash == original.contentHash,
               FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.file).path) {
                if entry.pinned { plan.alreadyKept += 1 } else { plan.toPin.append(original.assetId) }
            } else if original.fileURL == nil {
                plan.offline += 1
            } else {
                plan.toRead.append(original)
                plan.readBytes += original.fileSize
            }
        }
        plan.shortBy = KeepPlan.shortfall(reading: plan.readBytes, free: free, capacity: capacity)
        return plan
    }

    /// This Mac's disk, where the cache is: free space for important use and total size.
    public func diskSpace() -> (free: Int64, capacity: Int64) {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// Free Up Space: the kept copies among `assetIDs` go (not merely unpinned), except the photo
    /// open in Develop, which only stops being kept. Returns the bytes let go.
    @discardableResult
    public func freeUp(_ assetIDs: [Int64], sparing: Int64? = nil) throws -> (count: Int, bytes: Int64) {
        let open = sparing ?? inUse
        var count = 0
        var bytes: Int64 = 0
        let entries = try entries(for: assetIDs)
        for id in assetIDs {
            guard let entry = entries[id], entry.pinned else { continue }
            if id == open {
                try setKept([id], false)
            } else {
                try drop(id)
                count += 1
                bytes += entry.bytes
            }
        }
        return (count, bytes)
    }

    /// How many of `assetIDs` are kept, and their bytes (Free Up Space's line).
    public func keptUsage(of assetIDs: [Int64]) throws -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for entry in try entries(for: assetIDs).values where entry.pinned {
            count += 1
            bytes += entry.bytes
        }
        return (count, bytes)
    }
}
