import Foundation
import GRDB
import XCTest
@testable import AtelierCore

/// AT-079e: S3-compatible backups. Signatures match botocore's for the same requests; the keys
/// stay out of the catalog; backups keep the newest N. With `ATELIER_S3_TEST_ENDPOINT` (a MinIO
/// on this Mac), the whole thing against a real bucket.
final class ObjectStorageTests: XCTestCase {
    private let credentials = S3Credentials(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    private let noon = Date(timeIntervalSince1970: 1_794_916_800) // 2026-11-17 12:00:00 UTC

    /// Expected signatures from botocore 1.44.5's S3SigV4Auth, same keys, time and requests.
    func testSignaturesMatchBotocore() throws {
        let cases: [(String, String, String, String, String)] = [
            ("GET", "http://localhost:9000/atelier-test?list-type=2&prefix=Atelier%20Backups%2F", "", "us-east-1",
             "92791a189dba59d7509280f8652a6c5c4e8ac71b53a3b11f11eb80f3da294cf5"),
            ("PUT", "https://s3.eu-west-2.amazonaws.com/my-bucket/Atelier%20Backups/My%20Catalog/catalog-2026-11-17T120000.sqlite",
             "hello", "eu-west-2", "7287951add67d743b3398a1912f9fc7f50d83ae9415d6dccdd259b208d1986c3"),
            ("POST", "http://localhost:9000/atelier-test/a%2Bb.sqlite?uploads=", "", "us-east-1",
             "d62cf3572dcf8a36bb8f44f1b7c8037c9553f176cba5d3b94fa9d28ebf51943c"),
            ("PUT", "http://localhost:9000/atelier-test/a.sqlite?uploadId=abc%2Fdef&partNumber=2", "part", "us-east-1",
             "ca74dde651165204240787d0a1d165d6d8addba9abf8407c353f12244b7758ac"),
        ]
        for (method, url, body, region, signature) in cases {
            var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
            request.httpMethod = method
            S3Signer(credentials: credentials, region: region)
                .sign(&request, payloadHash: S3Signer.sha256Hex(Data(body.utf8)), date: noon)
            let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261117/\(region)/s3/aws4_request, "
                                                  + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "), authorization)
            XCTAssertTrue(authorization.hasSuffix("Signature=" + signature), "\(method) \(url): \(authorization)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20261117T120000Z")
        }
    }

    func testBucketURLs() throws {
        let minio = S3Bucket(endpoint: try XCTUnwrap(URL(string: "http://localhost:9000")), region: "",
                             bucket: "atelier-test", prefix: "/Mac/")
        XCTAssertEqual(minio.region, "us-east-1")
        XCTAssertEqual(minio.key("Atelier Backups/x.sqlite"), "Mac/Atelier Backups/x.sqlite")
        XCTAssertEqual(minio.url(key: "Mac/a b+c.sqlite")?.absoluteString, "http://localhost:9000/atelier-test/Mac/a%20b%2Bc.sqlite")
        XCTAssertEqual(minio.url(key: nil, query: [("list-type", "2"), ("prefix", "Mac/")])?.absoluteString,
                       "http://localhost:9000/atelier-test?list-type=2&prefix=Mac%2F")
        let aws = S3Bucket(endpoint: try XCTUnwrap(URL(string: "https://s3.eu-west-2.amazonaws.com")), region: "eu-west-2",
                           bucket: "photos", pathStyle: false)
        XCTAssertEqual(aws.url(key: "a.sqlite", query: [("uploads", "")])?.absoluteString,
                       "https://photos.s3.eu-west-2.amazonaws.com/a.sqlite?uploads=")
    }

    func testListingAndErrorsFromXML() {
        let listing = S3XML.listing(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name><Prefix>p/</Prefix>
            <KeyCount>2</KeyCount><IsTruncated>true</IsTruncated><NextContinuationToken>tok==</NextContinuationToken>
            <Contents><Key>p/catalog-1.sqlite</Key><LastModified>2026-11-17T12:00:00.000Z</LastModified><Size>1024</Size></Contents>
            <Contents><Key>p/catalog-2.sqlite</Key><LastModified>2026-11-17T13:00:00Z</LastModified><Size>2048</Size></Contents>
            </ListBucketResult>
            """.utf8))
        XCTAssertEqual(listing.objects.map(\.key), ["p/catalog-1.sqlite", "p/catalog-2.sqlite"])
        XCTAssertEqual(listing.objects.map(\.size), [1024, 2048])
        XCTAssertNotNil(listing.objects.last?.lastModified)
        XCTAssertTrue(listing.truncated)
        XCTAssertEqual(listing.nextToken, "tok==")
        let error = Data("<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature…</Message></Error>".utf8)
        XCTAssertEqual(S3XML.firstValue("Code", in: error), "SignatureDoesNotMatch")
        XCTAssertEqual(S3Error(code: "SignatureDoesNotMatch", message: "", status: 403).errorDescription,
                       "The secret key doesn't match the access key.")
        XCTAssertEqual(S3XML.escape("\"etag\"&<"), "&quot;etag&quot;&amp;&lt;")
    }

    /// The keys go to the secret store; the catalog file holds only a random reference.
    func testObjectStorageKeepsKeysOutOfTheCatalog() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("S3Catalog-\(UUID().uuidString).atelier")
        defer { try? FileManager.default.removeItem(at: package) }
        let secrets = MemorySecrets()
        let bucket = S3Bucket(endpoint: try XCTUnwrap(URL(string: "http://localhost:9000")), region: "us-east-1",
                              bucket: "atelier-test", prefix: "Mac")
        do {
            let catalog = try Catalog(packageURL: package)
            let location = try catalog.addObjectStorageLocation(name: "MinIO", bucket: bucket, credentials: credentials, secrets: secrets)
            let id = try XCTUnwrap(location.id)
            XCTAssertEqual(location.kind, .objectStorage)
            XCTAssertTrue(location.usesBackups)
            XCTAssertFalse(location.usesPhotos)
            let stored = try XCTUnwrap(catalog.objectStorage(id))
            XCTAssertEqual(stored.bucket, bucket)
            XCTAssertEqual(secrets.credentials(stored.keychainItem), credentials)
            XCTAssertEqual(secrets.label(stored.keychainItem), "Atelier: MinIO")
            XCTAssertNotNil(try catalog.s3Client(for: id, secrets: secrets))
            XCTAssertFalse(try catalog.makesSmartPreviews(id))
            // Adding it again replaces the keys, not the location.
            let newKeys = S3Credentials(accessKey: "AK2", secretKey: "SK2")
            XCTAssertEqual(try catalog.addObjectStorageLocation(name: "", bucket: bucket, credentials: newKeys, secrets: secrets).id, id)
            XCTAssertEqual(secrets.credentials(stored.keychainItem), newKeys)
            XCTAssertEqual(try catalog.storageLocations().count, 1)
            // A bucket is never taken for a share waiting for its volume.
            XCTAssertNil(try catalog.storageLocations().first?.volume)
        }
        var bytes = Data()
        for file in ["catalog.sqlite", "catalog.sqlite-wal"] {
            bytes += (try? Data(contentsOf: package.appendingPathComponent(file))) ?? Data()
        }
        for secret in [credentials.secretKey, credentials.accessKey, "SK2", "AK2"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) must not be in the catalog")
        }
        let catalog = try Catalog(packageURL: package)
        let id = try XCTUnwrap(catalog.storageLocations().first?.id)
        let reference = try XCTUnwrap(catalog.objectStorage(id)?.keychainItem)
        try catalog.removeObjectStorageLocation(id, secrets: secrets)
        XCTAssertNil(secrets.read(reference))
        XCTAssertEqual(try catalog.storageLocations(), [])
    }

    /// The newest `keep` stay; nothing but Atelier's own backups is removed.
    func testBackupsToAFolderKeepTheNewest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Catalog()
        let destination = FolderBackupDestination(root: root, catalogName: "Atelier Catalog")
        try FileManager.default.createDirectory(at: destination.folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: destination.folder.appendingPathComponent("notes.txt"))
        for hour in 0..<4 {
            let result = try await CatalogBackups.run(catalog, to: destination, keep: 2, date: noon.addingTimeInterval(Double(hour) * 3600))
            XCTAssertGreaterThan(result.bytes, 0)
        }
        let names = try await destination.list().map(\.name).sorted()
        XCTAssertEqual(names, ["catalog-2026-11-17T140000.sqlite", "catalog-2026-11-17T150000.sqlite", "notes.txt"])
        // A backup is a database that opens.
        let queue = try DatabaseQueue(path: destination.folder.appendingPathComponent(names[1]).path)
        let tables = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table'") } ?? 0
        XCTAssertGreaterThan(tables, 0)
    }

    /// Against a real bucket (MinIO): Test Connection, a multipart upload, backups kept, wrong keys.
    func testABucketOnMinIO() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["ATELIER_S3_TEST_ENDPOINT"].flatMap(URL.init(string:)),
              let access = environment["ATELIER_S3_TEST_ACCESS_KEY"], let secret = environment["ATELIER_S3_TEST_SECRET_KEY"] else {
            throw XCTSkip("Set ATELIER_S3_TEST_ENDPOINT, _ACCESS_KEY, _SECRET_KEY (and _BUCKET)")
        }
        let bucket = S3Bucket(endpoint: endpoint, region: "us-east-1",
                              bucket: environment["ATELIER_S3_TEST_BUCKET"] ?? "atelier-test", prefix: "run-\(UUID().uuidString.prefix(8))")
        let client = S3Client(bucket: bucket, credentials: S3Credentials(accessKey: access, secretKey: secret))
        try await client.testConnection()

        // 40 MB: three parts.
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("S3Big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: big) }
        var bytes = Data(count: 40 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { buffer in for i in stride(from: 0, to: buffer.count, by: 4096) { buffer[i] = UInt8(i / 4096 % 251) } }
        try bytes.write(to: big)
        let started = Date()
        let sent = try await client.upload(big, to: bucket.key("big.bin"))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(sent, Int64(bytes.count))
        let listed = try await client.list(prefix: bucket.key(""))
        XCTAssertEqual(listed.first { $0.key == bucket.key("big.bin") }?.size, Int64(bytes.count))
        print("S3 multipart 40 MB in \(Int(seconds * 1000)) ms (\(String(format: "%.0f", 40 / seconds)) MB/s)")

        let catalog = try Catalog()
        let destination = S3BackupDestination(client: client, catalogName: "Atelier Catalog")
        for hour in 0..<3 {
            _ = try await CatalogBackups.run(catalog, to: destination, keep: 2, date: noon.addingTimeInterval(Double(hour) * 3600))
        }
        let kept = try await destination.list().map(\.name).sorted()
        XCTAssertEqual(kept, ["catalog-2026-11-17T130000.sqlite", "catalog-2026-11-17T140000.sqlite"])

        let wrong = S3Client(bucket: bucket, credentials: S3Credentials(accessKey: access, secretKey: "not-the-secret"))
        do {
            try await wrong.testConnection()
            XCTFail("wrong keys connected")
        } catch let error as S3Error {
            XCTAssertEqual(error.code, "SignatureDoesNotMatch")
        }

        for object in try await client.list(prefix: bucket.key("")) { try await client.delete(object.key) }
        let left = try await client.list(prefix: bucket.key(""))
        XCTAssertEqual(left, [])
    }
}
