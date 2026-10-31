import Foundation
import GRDB

public enum CatalogError: Error, LocalizedError {
    case notFound(String)
    case missingDatabase(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "\(what) not found in the catalog."
        case .missingDatabase(let url): return "The catalog database is missing at \(url.path). Use Show in Finder to check the Backups folder inside this catalog. Atelier does not restore backups automatically."
        }
    }
}

/// The catalog: one SQLite database (WAL mode) inside a `.atelier` package on the local SSD.
///
/// Package layout:
///   catalog.sqlite   the database
///   Previews/        sharded 256 px and 2560 px JPEG previews
///   Backups/         snapshots taken on quit (last 10 kept)
public final class Catalog: Sendable {
    public let writer: any DatabaseWriter
    public let packageURL: URL?

    public var previewsURL: URL? { packageURL?.appendingPathComponent("Previews", isDirectory: true) }

    /// Opens or creates the catalog package at `packageURL`.
    public init(packageURL: URL) throws {
        let databaseURL = packageURL.appendingPathComponent("catalog.sqlite")
        // An interrupted first launch can leave an empty directory (or Finder's .DS_Store).
        // Any other contents may belong to a damaged/incompletely restored library; preserve them.
        if FileManager.default.fileExists(atPath: packageURL.path),
           !FileManager.default.fileExists(atPath: databaseURL.path) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: packageURL, includingPropertiesForKeys: nil)
            let hasCatalogContents = try contents.contains { url in
                guard url.lastPathComponent == ".DS_Store" else { return true }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return attributes[.type] as? FileAttributeType != .typeRegular
            }
            if hasCatalogContents { throw CatalogError.missingDatabase(databaseURL) }
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let dbPath = databaseURL.path
        var config = Configuration()
        config.foreignKeysEnabled = true
        // DatabasePool runs SQLite in WAL mode.
        self.writer = try DatabasePool(path: dbPath, configuration: config)
        self.packageURL = packageURL
        try Self.migrator.migrate(writer)
    }

    /// In-memory catalog for tests.
    public init() throws {
        self.writer = try DatabaseQueue()
        self.packageURL = nil
        try Self.migrator.migrate(writer)
    }

    /// Default location: ~/Pictures/Atelier/Atelier Catalog.atelier
    public static var defaultPackageURL: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier", isDirectory: true)
            .appendingPathComponent("Atelier Catalog.atelier", isDirectory: true)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "volume") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identityKey", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("mountPath", .text)
                t.column("lastSeen", .datetime)
                t.column("isOnline", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("volumeId", .integer).notNull().indexed()
                    .references("volume", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.uniqueKey(["volumeId", "relativePath"])
            }
            try db.create(table: "asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull().indexed()
                    .references("folder", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime)
                t.column("contentHash", .text).notNull().indexed()
                t.column("perceptualHash", .text)
                t.column("captureTime", .datetime).indexed()
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("lens", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("orientation", .integer)
                t.column("uti", .text)
                t.column("importedAt", .datetime).notNull()
                t.uniqueKey(["folderId", "filename"])
            }
            try db.create(table: "metadata") { t in
                t.column("assetId", .integer).primaryKey()
                    .references("asset", onDelete: .cascade)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("flag", .integer).notNull().defaults(to: 0)
                t.column("colorLabel", .text)
                t.column("title", .text)
                t.column("caption", .text)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("xmpDirty", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "keyword") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().indexed()
                t.column("parentId", .integer).references("keyword", onDelete: .cascade)
            }
            try db.create(table: "assetKeyword") { t in
                t.column("assetId", .integer).notNull().references("asset", onDelete: .cascade)
                t.column("keywordId", .integer).notNull().indexed()
                    .references("keyword", onDelete: .cascade)
                t.primaryKey(["assetId", "keywordId"])
            }
            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("parentId", .integer).references("collection", onDelete: .cascade)
                t.column("isSet", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "collectionAsset") { t in
                t.column("collectionId", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("assetId", .integer).notNull().indexed()
                    .references("asset", onDelete: .cascade)
                t.primaryKey(["collectionId", "assetId"])
            }
        }
        migrator.registerMigration("v2-import-groups") { db in
            try db.create(table: "importGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "importGroupAsset") { t in
                t.column("importGroupId", .integer).notNull()
                    .references("importGroup", onDelete: .cascade)
                t.column("assetId", .integer).notNull().indexed()
                    .references("asset", onDelete: .cascade)
                t.primaryKey(["importGroupId", "assetId"])
            }
        }
        registerDevelopMigration(&migrator)
        registerStackMigration(&migrator)
        registerCullMigration(&migrator)
        registerVirtualCopyMigration(&migrator)
        registerPairMigration(&migrator)
        registerProcessorMigration(&migrator)
        return migrator
    }
}

// MARK: - Backups

extension Catalog {
    /// Copies the database into Backups/ and keeps the newest `keep` snapshots.
    @discardableResult
    public func snapshot(keep: Int = 10) throws -> URL? {
        guard let packageURL else { return nil }
        let dir = packageURL.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let url = dir.appendingPathComponent("catalog-\(formatter.string(from: Date())).sqlite")
        let destination = try DatabaseQueue(path: url.path)
        try writer.backup(to: destination)

        let snapshots = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in snapshots.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }
}
