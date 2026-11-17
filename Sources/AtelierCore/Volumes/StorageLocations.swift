import Foundation
import GRDB

// Storage locations (AT-079a, PRD "Storage locations and offline photos"). Atelier runs no storage
// of its own: the user adds the places they already have in Settings > Storage. A location is a
// named place on a volume: the volume (identity and mount, as before) plus the location's root
// folder relative to that volume's root. Photos keep their folder paths relative to the *volume*
// root, so adding or removing a location never moves or rebases a stored path (Codex review of
// PR #178). Nothing is seeded: a fresh catalog has no location, and an existing catalog gets one
// per volume it already holds, rooted at the volume root.

public enum StorageLocationKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// This Mac, an external drive, or a folder on one.
    case drive
    /// A network share (SMB, WebDAV, NFS) that macOS mounts.
    case networkShare
    /// A cloud drive folder synced by the provider's own app (AT-079b).
    case cloudFolder
    /// S3-compatible object storage, for backups (AT-079e).
    case objectStorage
}

extension StorageLocationKind {
    /// The kind a volume's own location gets: drive, network share or cloud drive folder.
    public init(_ volume: VolumeKind) {
        switch volume {
        case .local: self = .drive
        case .nas: self = .networkShare
        case .cloud: self = .cloudFolder
        }
    }
}

public struct StorageLocation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "storageLocation"

    public var id: Int64?
    public var name: String
    public var kind: StorageLocationKind
    /// The volume the location is on; nil for a share added but never connected yet.
    public var volumeId: Int64?
    /// The location's root folder relative to its volume's root ("" for the whole volume).
    public var rootPath: String
    /// A share's address with any user name and password stripped, e.g. "smb://megham.local/Photos".
    public var serverAddress: String?
    public var usesPhotos: Bool
    public var usesBackups: Bool
    public var usesExports: Bool
    /// Shares: mount it, silently with the Keychain's password, when Atelier opens.
    public var connectAtLaunch: Bool
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, kind: StorageLocationKind, volumeId: Int64?,
                rootPath: String = "", serverAddress: String? = nil, usesPhotos: Bool = true,
                usesBackups: Bool = false, usesExports: Bool = false, connectAtLaunch: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.volumeId = volumeId
        self.rootPath = rootPath
        self.serverAddress = serverAddress
        self.usesPhotos = usesPhotos
        self.usesBackups = usesBackups
        self.usesExports = usesExports
        self.connectAtLaunch = connectAtLaunch
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The location's folder while its volume is mounted.
    public func rootURL(on volume: Volume) -> URL? {
        guard volume.isOnline, let mount = volume.mountPath else { return nil }
        let base = URL(fileURLWithPath: mount, isDirectory: true)
        return rootPath.isEmpty ? base : base.appendingPathComponent(rootPath, isDirectory: true)
    }
}

/// What the Storage pane and the sidebar say about a location.
public enum StorageLocationStatus: Equatable, Sendable {
    case connected
    case offline
    /// A share added whose volume Atelier hasn't seen mounted yet.
    case notConnectedYet

    public var word: String {
        switch self {
        case .connected: return "Connected"
        case .offline: return "Offline"
        case .notConnectedYet: return "Not Connected"
        }
    }
}

/// A location with its volume and photo count, for the Storage pane.
public struct StorageLocationInfo: Identifiable, Hashable, Sendable {
    public var location: StorageLocation
    public var volume: Volume?
    public var photoCount: Int

    public var id: Int64 { location.id ?? -1 }

    public var status: StorageLocationStatus {
        guard let volume else { return .notConnectedYet }
        return volume.isOnline ? .connected : .offline
    }

    /// The word beside the status dot. A cloud drive folder whose provider folder is gone (the app
    /// signed out or removed) is "Signed Out" rather than "Offline".
    public var statusWord: String {
        location.kind == .cloudFolder && status == .offline ? "Signed Out" : status.word
    }

    /// The grey second line: "Network share · megham.local/Photos", "Drive · Photos SSD/Portfolio".
    public var detailLine: String {
        let kind: String
        switch location.kind {
        case .drive: kind = "Drive"
        case .networkShare: kind = "Network share"
        case .cloudFolder: kind = "Cloud drive folder"
        case .objectStorage: kind = "Object storage"
        }
        if let address = location.serverAddress, let shown = ServerAddress.display(address) {
            return location.rootPath.isEmpty ? "\(kind) · \(shown)" : "\(kind) · \(shown)/\(location.rootPath)"
        }
        let base = volume?.name ?? location.name
        return location.rootPath.isEmpty ? "\(kind) · \(base)" : "\(kind) · \(base)/\(location.rootPath)"
    }

    public var rootURL: URL? { volume.flatMap { location.rootURL(on: $0) } }
}

/// Share addresses: stripped of credentials, compared without case or a trailing ".local".
public enum ServerAddress {
    /// "smb://user:pw@Megham.local/Photos/" -> "smb://megham.local/Photos". Nil if not a URL with a host.
    public static func normalized(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "smb://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.host = host.lowercased()
        components.scheme = (components.scheme ?? "smb").lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Key for matching one server reached two ways: "megham.local" and "megham" are the same.
    public static func matchKey(_ text: String) -> String? {
        guard let normalized = normalized(text), let components = URLComponents(string: normalized),
              var host = components.host else { return nil }
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        let share = components.path.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        return host + "/" + share
    }

    /// "megham.local/Photos" for the Storage pane's second line.
    public static func display(_ text: String) -> String? {
        guard let normalized = normalized(text), let components = URLComponents(string: normalized),
              let host = components.host else { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return host + path
    }
}

extension Catalog {
    static func registerStorageLocationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-storage-locations") { db in
            try db.create(table: "storageLocation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("volumeId", .integer).indexed().references("volume", onDelete: .setNull)
                t.column("rootPath", .text).notNull().defaults(to: "")
                t.column("serverAddress", .text)
                t.column("usesPhotos", .boolean).notNull().defaults(to: true)
                t.column("usesBackups", .boolean).notNull().defaults(to: false)
                t.column("usesExports", .boolean).notNull().defaults(to: false)
                t.column("connectAtLaunch", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            // Every volume already in the catalog becomes a location with its name, rooted at the
            // volume root, so nothing has to be set up again and every photo stays linked.
            for volume in try Volume.fetchAll(db) {
                var location = Self.defaultLocation(for: volume)
                try location.insert(db)
            }
        }
    }

    static func defaultLocation(for volume: Volume) -> StorageLocation {
        var address: String?
        if volume.identityKey.hasPrefix("net:") {
            address = ServerAddress.normalized(String(volume.identityKey.dropFirst(4)))
        }
        return StorageLocation(name: volume.name, kind: StorageLocationKind(volume.kind),
                               volumeId: volume.id, serverAddress: address)
    }

    /// A volume the importer just added gets its location, as the migration did for old ones.
    static func ensureLocation(for volume: Volume, _ db: Database) throws {
        guard let id = volume.id,
              try StorageLocation.filter(Column("volumeId") == id).fetchCount(db) == 0 else { return }
        var location = defaultLocation(for: volume)
        try location.insert(db)
        try db.execute(sql: "UPDATE storageLocation SET makesSmartPreviews = ? WHERE id = ?",
                       arguments: [makesSmartPreviewsByDefault(location.kind), location.id])
    }

    /// Settings > Storage's list, in the order the locations were added.
    public func storageLocations() throws -> [StorageLocationInfo] {
        try writer.read { db in try Self.fetchStorageLocations(db) }
    }

    /// For observations (the sidebar and Settings > Storage update when a share mounts).
    /// Photo counts come from one pass over the catalog, grouped by folder, then summed per
    /// location, so the cost doesn't grow with the number of locations.
    public static func fetchStorageLocations(_ db: Database) throws -> [StorageLocationInfo] {
        let volumes = Dictionary(uniqueKeysWithValues: try Volume.fetchAll(db).compactMap { v in v.id.map { ($0, v) } })
        let locations = try StorageLocation.order(Column("createdAt"), Column("id")).fetchAll(db)
        var folderCounts: [Int64: [(path: String, count: Int)]] = [:]
        if locations.contains(where: { $0.volumeId != nil }) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT folder.volumeId AS volumeId, folder.relativePath AS path, COUNT(*) AS n
                FROM asset JOIN folder ON folder.id = asset.folderId
                WHERE asset.virtualCopyOf IS NULL
                GROUP BY asset.folderId
                """)
            for row in rows {
                folderCounts[row["volumeId"], default: []].append((row["path"], row["n"]))
            }
        }
        return locations.map { location in
            let volume = location.volumeId.flatMap { volumes[$0] }
            return StorageLocationInfo(location: location, volume: volume,
                                       photoCount: photoCount(in: location, folders: folderCounts))
        }
    }

    /// Photos in the location's folder and the folders inside it (never a sibling such as
    /// "PortfolioOld" for "Portfolio").
    static func photoCount(in location: StorageLocation, folders: [Int64: [(path: String, count: Int)]]) -> Int {
        guard let volumeId = location.volumeId, let onVolume = folders[volumeId] else { return 0 }
        let root = location.rootPath
        if root.isEmpty { return onVolume.reduce(0) { $0 + $1.count } }
        let prefix = root + "/"
        return onVolume.reduce(0) { total, folder in
            folder.path == root || folder.path.hasPrefix(prefix) ? total + folder.count : total
        }
    }

    /// Adds the folder `folder` (a volume root or any folder on it) as a location. The volume's
    /// record is found by identity or added; existing folder paths on it are never changed. Adding
    /// the same place twice returns the location already there.
    @discardableResult
    public func addStorageLocation(folder: URL, on mounted: MountedVolume, name: String? = nil,
                                   kind: StorageLocationKind? = nil, connectAtLaunch: Bool = false,
                                   makesSmartPreviews: Bool? = nil) throws -> StorageLocation {
        let root = VolumeIdentity.relativePath(of: folder, inVolumeAt: mounted.rootURL)
        let resolvedKind = kind ?? StorageLocationKind(mounted.kind)
        return try writer.write { db in
            var volume = try Volume.filter(Column("identityKey") == mounted.identityKey).fetchOne(db)
                ?? Volume(id: nil, identityKey: mounted.identityKey, name: mounted.name, kind: mounted.kind,
                          mountPath: nil, lastSeen: nil, isOnline: true)
            volume.mountPath = mounted.rootURL.path
            volume.lastSeen = Date()
            volume.isOnline = true
            try volume.save(db)
            if let existing = try StorageLocation
                .filter(Column("volumeId") == volume.id! && Column("rootPath") == root).fetchOne(db) {
                return existing
            }
            let address = mounted.serverAddress
            // A share added by address before it was ever mounted is the same location.
            if let key = address.flatMap(ServerAddress.matchKey), root.isEmpty,
               var pending = try StorageLocation.filter(Column("volumeId") == nil && Column("kind") != StorageLocationKind.objectStorage.rawValue).fetchAll(db)
                .first(where: { $0.serverAddress.flatMap(ServerAddress.matchKey) == key }) {
                pending.volumeId = volume.id
                try pending.update(db)
                return pending
            }
            let defaultName = root.isEmpty ? mounted.name : (root as NSString).lastPathComponent
            var location = StorageLocation(name: (name?.isEmpty == false ? name! : defaultName), kind: resolvedKind,
                                           volumeId: volume.id, rootPath: root, serverAddress: address,
                                           connectAtLaunch: connectAtLaunch)
            try location.insert(db)
            try db.execute(sql: "UPDATE storageLocation SET makesSmartPreviews = ? WHERE id = ?", arguments: [
                makesSmartPreviews ?? Catalog.makesSmartPreviewsByDefault(resolvedKind), location.id])
            return location
        }
    }

    /// Settings > Storage > the location's details.
    public func updateStorageLocation(_ location: StorageLocation) throws {
        _ = try writer.write { db in try location.update(db) }
    }

    /// Remove Location…: only the location goes. Its photos stay in the catalog under their
    /// volume (offline while it isn't mounted); no file is touched.
    public func removeStorageLocation(_ id: Int64) throws {
        _ = try writer.write { db in try StorageLocation.deleteOne(db, key: id) }
    }

    /// Links share locations added by address to the volume once it is mounted, and adds the
    /// volume's record if the catalog has none yet. Called from `refreshVolumes`.
    static func linkPendingLocations(_ mounted: [MountedVolume], _ db: Database) throws {
        // Object storage has an endpoint, never a volume.
        let pending = try StorageLocation.filter(Column("volumeId") == nil && Column("serverAddress") != nil
                                                 && Column("kind") != StorageLocationKind.objectStorage.rawValue).fetchAll(db)
        guard !pending.isEmpty else { return }
        for volume in mounted {
            guard let key = volume.serverAddress.flatMap(ServerAddress.matchKey) else { continue }
            for var location in pending where location.serverAddress.flatMap(ServerAddress.matchKey) == key {
                var record = try Volume.filter(Column("identityKey") == volume.identityKey).fetchOne(db)
                    ?? Volume(id: nil, identityKey: volume.identityKey, name: volume.name, kind: volume.kind,
                              mountPath: volume.rootURL.path, lastSeen: Date(), isOnline: true)
                if record.id == nil { try record.insert(db) }
                location.volumeId = record.id
                try location.update(db)
            }
        }
    }
}

// MARK: - Sidebar

extension StorageLocation {
    /// Whether the folder at `path` (relative to the volume root) is this location's folder or
    /// inside it. Never a sibling: "PortfolioOld" is not in "Portfolio".
    public func contains(folderPath path: String, onVolume volumeId: Int64) -> Bool {
        guard self.volumeId == volumeId else { return false }
        return rootPath.isEmpty || path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

/// The sidebar's Locations section (AT-079a): one row per location, each with the folders it holds.
public struct SidebarLocation: Identifiable, Hashable, Sendable {
    public var info: StorageLocationInfo
    /// The folder at the location's own root, when the catalog has one: selecting the row selects it.
    /// Nil for a whole-volume location (the row selects the volume) or a folder nothing was imported from.
    public var rootFolder: Folder?
    /// Folders inside the location, excluding `rootFolder` and any folder a more specific location holds.
    public var folders: [Folder]

    public var id: Int64 { info.id }

    /// Groups `folders` under `locations`. A folder goes under the most specific location that holds
    /// it, so a drive and a folder on it never list the same folder twice. Locations keep their order.
    public static func make(locations: [StorageLocationInfo], folders: [Folder]) -> [SidebarLocation] {
        var rows = locations.map { SidebarLocation(info: $0, rootFolder: nil, folders: []) }
        for folder in folders {
            var best: Int?
            for (index, row) in rows.enumerated()
            where row.info.location.contains(folderPath: folder.relativePath, onVolume: folder.volumeId) {
                if let current = best, rows[current].info.location.rootPath.count >= row.info.location.rootPath.count {
                    continue
                }
                best = index
            }
            guard let best else { continue }
            let root = rows[best].info.location.rootPath
            if !root.isEmpty, folder.relativePath == root {
                rows[best].rootFolder = folder
            } else {
                rows[best].folders.append(folder)
            }
        }
        return rows
    }
}
