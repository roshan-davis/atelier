import Foundation
import GRDB

/// A mounted volume as seen right now.
public struct MountedVolume: Sendable, Hashable {
    public var identityKey: String
    public var name: String
    public var kind: VolumeKind
    public var rootURL: URL
}

/// Photos point at files by volume identity plus relative path, so remounting a drive or the
/// NAS under a different path (for example /Volumes/megham-1) does not break links.
public enum VolumeIdentity {
    static let rootKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeURLForRemountingKey, .volumeNameKey, .volumeIsLocalKey,
    ]

    /// The volume that holds `url`.
    public static func volume(containing url: URL) throws -> MountedVolume {
        let values = try url.resourceValues(forKeys: [.volumeURLKey])
        guard let root = values.volume else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try volume(atRoot: root)
    }

    /// Identity is always computed from the volume root URL so import and refresh agree.
    public static func volume(atRoot root: URL) throws -> MountedVolume {
        let values = try root.resourceValues(forKeys: rootKeys)
        let name = values.volumeName ?? root.lastPathComponent
        let key: String
        if let uuid = values.volumeUUIDString {
            key = "uuid:" + uuid
        } else if let remount = values.volumeURLForRemounting {
            key = "net:" + stripCredentials(remount)
        } else {
            key = "name:" + name
        }
        return MountedVolume(identityKey: key, name: name,
                             kind: (values.volumeIsLocal ?? true) ? .local : .nas,
                             rootURL: root)
    }

    public static func mountedVolumes() -> [MountedVolume] {
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(rootKeys)) ?? []
        return roots.compactMap { try? volume(atRoot: $0) }
    }

    /// Path of `url` relative to `root`, without leading or trailing slashes.
    ///
    /// The boot volume's Data partition is mounted at /System/Volumes/Data but its files are
    /// reached through firmlinks such as /Users. In that case the path relative to / is also
    /// the path relative to the Data volume root.
    public static func relativePath(of url: URL, inVolumeAt root: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let relative: Substring
        if rootPath == "/" {
            relative = path.dropFirst()
        } else if path == rootPath {
            relative = ""
        } else if path.hasPrefix(rootPath + "/") {
            relative = path.dropFirst(rootPath.count + 1)
        } else {
            relative = path.dropFirst()
        }
        return String(relative).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func stripCredentials(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.string ?? url.absoluteString
    }
}

extension Catalog {
    /// Marks each known volume online or offline and records where it is mounted now.
    public func refreshVolumes() throws {
        let mounted = VolumeIdentity.mountedVolumes()
        let byKey = Dictionary(mounted.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
        try writer.write { db in
            for var volume in try Volume.fetchAll(db) {
                if let match = byKey[volume.identityKey] {
                    volume.isOnline = true
                    volume.mountPath = match.rootURL.path
                    volume.lastSeen = Date()
                } else {
                    volume.isOnline = false
                }
                try volume.update(db)
            }
        }
    }

    static func fileURL(volume: Volume, folder: Folder, filename: String) -> URL? {
        guard volume.isOnline, let mountPath = volume.mountPath else { return nil }
        var url = URL(fileURLWithPath: mountPath, isDirectory: true)
        if !folder.relativePath.isEmpty {
            url.appendPathComponent(folder.relativePath, isDirectory: true)
        }
        return url.appendingPathComponent(filename, isDirectory: false)
    }
}
