import Foundation
import GRDB

/// S3-compatible object storage locations (AT-079e), for catalog backups only. The catalog keeps
/// where the bucket is (endpoint in `serverAddress`, the folder in `rootPath`, and the bucket,
/// region and addressing in columns of their own) and a random reference to the Keychain item
/// that holds the keys; never the keys.
extension Catalog {
    static func registerObjectStorageMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15-object-storage") { db in
            try db.alter(table: StorageLocation.databaseTableName) { t in
                t.add(column: "bucket", .text)
                t.add(column: "region", .text)
                t.add(column: "pathStyle", .boolean).notNull().defaults(to: true)
                t.add(column: "keychainItem", .text)
            }
        }
    }

    /// Add Location… > Object Storage (S3): saves the keys in `secrets` (the Keychain) first, then
    /// the location, used for backups. The same bucket and folder twice is the same location
    /// (its keys are replaced).
    @discardableResult
    public func addObjectStorageLocation(name: String, bucket: S3Bucket, credentials: S3Credentials,
                                         secrets: SecretStore = KeychainSecrets()) throws -> StorageLocation {
        let endpoint = bucket.endpoint.absoluteString
        if let existing = try objectStorageLocations().first(where: { $0.bucket == bucket }) {
            try secrets.save(credentials, reference: existing.keychainItem, locationName: existing.location.name)
            return existing.location
        }
        let reference = UUID().uuidString
        let shownName = name.trimmingCharacters(in: .whitespaces).isEmpty ? bucket.bucket : name
        try secrets.save(credentials, reference: reference, locationName: shownName)
        do {
            return try writer.write { db in
                var location = StorageLocation(name: shownName, kind: .objectStorage, volumeId: nil,
                                               rootPath: bucket.prefix, serverAddress: endpoint,
                                               usesPhotos: false, usesBackups: true)
                try location.insert(db)
                try db.execute(sql: """
                    UPDATE storageLocation SET bucket = ?, region = ?, pathStyle = ?, keychainItem = ?,
                        makesSmartPreviews = 0 WHERE id = ?
                    """, arguments: [bucket.bucket, bucket.region, bucket.pathStyle, reference, location.id])
                return location
            }
        } catch {
            secrets.delete(reference)
            throw error
        }
    }

    /// An object storage location's bucket and Keychain reference.
    public struct ObjectStorageLocation: Sendable, Equatable {
        public var location: StorageLocation
        public var bucket: S3Bucket
        public var keychainItem: String
    }

    public func objectStorageLocations() throws -> [ObjectStorageLocation] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM storageLocation WHERE kind = ? AND keychainItem IS NOT NULL ORDER BY id
                """, arguments: [StorageLocationKind.objectStorage.rawValue]).compactMap { row in
                let location = try StorageLocation(row: row)
                guard let endpoint = location.serverAddress.flatMap(URL.init(string:)),
                      let bucket: String = row["bucket"], let reference: String = row["keychainItem"] else { return nil }
                let pathStyle = (row["pathStyle"] as Bool?) ?? true
                return ObjectStorageLocation(
                    location: location,
                    bucket: S3Bucket(endpoint: endpoint, region: (row["region"] as String?) ?? "", bucket: bucket,
                                     prefix: location.rootPath, pathStyle: pathStyle),
                    keychainItem: reference)
            }
        }
    }

    public func objectStorage(_ locationID: Int64) throws -> ObjectStorageLocation? {
        try objectStorageLocations().first { $0.location.id == locationID }
    }

    /// A client for the location, with its keys from `secrets`; nil when it isn't object storage
    /// or its Keychain item is gone ("Sign In Again…").
    public func s3Client(for locationID: Int64, secrets: SecretStore = KeychainSecrets()) throws -> S3Client? {
        guard let storage = try objectStorage(locationID),
              let credentials = secrets.credentials(storage.keychainItem) else { return nil }
        return S3Client(bucket: storage.bucket, credentials: credentials)
    }

    /// Remove Location… on object storage: the location and its Keychain item (Atelier's own).
    public func removeObjectStorageLocation(_ locationID: Int64, secrets: SecretStore = KeychainSecrets()) throws {
        let reference = try objectStorage(locationID)?.keychainItem
        try removeStorageLocation(locationID)
        if let reference { secrets.delete(reference) }
    }
}
