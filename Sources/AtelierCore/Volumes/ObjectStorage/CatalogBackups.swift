import Foundation
import GRDB

/// A file in a backup destination.
public struct BackupFile: Sendable, Equatable {
    public var name: String
    public var size: Int64
}

/// Where catalog backups go (AT-079e): a folder on a drive, share or cloud drive folder, or a
/// bucket. Both keep the same layout, `Atelier Backups/<catalog name>/catalog-<date>.sqlite`, so a
/// backup can be restored by copying the file back, without Atelier.
public protocol BackupDestination: Sendable {
    func put(_ file: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func list() async throws -> [BackupFile]
    func remove(_ name: String) async throws
}

/// The folder of a location: written as a hidden partial file, then renamed, so a backup that
/// stops halfway never looks like one.
public struct FolderBackupDestination: BackupDestination {
    public let folder: URL

    public init(root: URL, catalogName: String) {
        folder = root.appendingPathComponent(CatalogBackups.folderName, isDirectory: true)
            .appendingPathComponent(catalogName, isDirectory: true)
    }

    public func put(_ file: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(name).partial")
        try? manager.removeItem(at: partial)
        try manager.copyItem(at: file, to: partial)
        try Task.checkCancellation()
        let destination = folder.appendingPathComponent(name)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: partial, to: destination)
        progress(1)
    }

    public func list() async throws -> [BackupFile] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return files.map { BackupFile(name: $0.lastPathComponent, size: Int64((try? $0.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)) }
    }

    public func remove(_ name: String) async throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}

/// A bucket's folder. A multipart upload that stops is aborted, so no partial object is left.
public struct S3BackupDestination: BackupDestination {
    public let client: S3Client
    let folderKey: String

    public init(client: S3Client, catalogName: String) {
        self.client = client
        folderKey = client.bucket.key(CatalogBackups.folderName + "/" + catalogName) + "/"
    }

    public func put(_ file: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.upload(file, to: folderKey + name, contentType: "application/vnd.sqlite3", progress: progress)
    }

    public func list() async throws -> [BackupFile] {
        try await client.list(prefix: folderKey).compactMap { object in
            let name = String(object.key.dropFirst(folderKey.count))
            return name.isEmpty || name.contains("/") ? nil : BackupFile(name: name, size: object.size)
        }
    }

    public func remove(_ name: String) async throws {
        try await client.delete(folderKey + name)
    }
}

public enum CatalogBackups {
    public static let folderName = "Atelier Backups"

    public struct Result: Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        /// Older backups removed to keep the newest `keep`.
        public var removed: Int
    }

    /// The name a catalog's backups are kept under: its package's name ("Atelier Catalog").
    public static func catalogName(_ catalog: Catalog) -> String {
        catalog.packageURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Catalog"
    }

    /// "catalog-2026-11-17T213000.sqlite", in UTC so names sort by time on every Mac.
    public static func backupName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return "catalog-\(formatter.string(from: date)).sqlite"
    }

    static func isBackup(_ name: String) -> Bool {
        name.hasPrefix("catalog-") && name.hasSuffix(".sqlite")
    }

    /// Backs the catalog up to `destination`: a consistent copy of the database (SQLite's backup,
    /// so edits can go on meanwhile) made in a temporary file, sent, then the oldest removed so
    /// the newest `keep` stay. Only Atelier's own `catalog-*.sqlite` files are ever removed.
    public static func run(_ catalog: Catalog, to destination: BackupDestination, keep: Int = 10,
                           date: Date = Date(),
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let name = backupName(date)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBackup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try catalog.copyDatabase(to: temporary)
        let bytes = Int64((try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0)
        try Task.checkCancellation()
        try await destination.put(temporary, name: name, progress: progress)
        var removed = 0
        let old = try await destination.list().map(\.name).filter(isBackup).sorted(by: >).dropFirst(max(keep, 1))
        for file in old where file != name {
            try await destination.remove(file)
            removed += 1
        }
        return Result(name: name, bytes: bytes, removed: removed)
    }
}

extension Catalog {
    /// A consistent copy of the database at `url` (SQLite's online backup).
    func copyDatabase(to url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try writer.backup(to: destination)
        try destination.close()
    }
}
