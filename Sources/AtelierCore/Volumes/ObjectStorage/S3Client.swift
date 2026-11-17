import Foundation

/// Where an S3-compatible bucket is: endpoint, region, bucket and a folder (key prefix) inside
/// it. Holds no secret; the keys come from the Keychain (`StorageKeychain`).
public struct S3Bucket: Sendable, Equatable, Codable {
    /// "https://s3.eu-west-2.amazonaws.com", "https://<account>.r2.cloudflarestorage.com",
    /// "http://localhost:9000" (MinIO).
    public var endpoint: URL
    public var region: String
    public var bucket: String
    /// The folder inside the bucket, without leading or trailing "/"; "" for the bucket's root.
    public var prefix: String
    /// `endpoint/bucket/key` (MinIO, most S3-compatible services) or `bucket.endpoint/key` (AWS).
    public var pathStyle: Bool

    public init(endpoint: URL, region: String, bucket: String, prefix: String = "", pathStyle: Bool = true) {
        self.endpoint = endpoint
        self.region = region.isEmpty ? "us-east-1" : region
        self.bucket = bucket
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.pathStyle = pathStyle
    }

    /// The key of `name` inside the folder.
    public func key(_ name: String) -> String {
        prefix.isEmpty ? name : prefix + "/" + name
    }

    /// The URL of an object (`key` nil: the bucket), with `query` as given (names and values
    /// unencoded; empty values are sent as `name=`).
    func url(key: String?, query: [(String, String)] = []) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let encodedKey = key.map { "/" + S3Signer.uriEncode($0, keepSlash: true) } ?? ""
        if pathStyle {
            let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.percentEncodedPath = (base.isEmpty ? "" : "/" + base) + "/" + S3Signer.uriEncode(bucket) + encodedKey
        } else {
            components.host = bucket + "." + (components.host ?? "")
            components.percentEncodedPath = encodedKey.isEmpty ? "/" : encodedKey
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(S3Signer.uriEncode($0.0))=\(S3Signer.uriEncode($0.1))" }
                .joined(separator: "&")
        }
        return components.url
    }
}

/// An object in a bucket, from a listing.
public struct S3Object: Sendable, Equatable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
}

/// What went wrong talking to a bucket, in plain words for Settings and the status bar.
public struct S3Error: LocalizedError, Sendable, Equatable {
    /// S3's error code ("AccessDenied", "NoSuchBucket", "SignatureDoesNotMatch"), or "Network".
    public var code: String
    public var message: String
    public var status: Int

    public var errorDescription: String? {
        switch code {
        case "InvalidAccessKeyId": return "The access key isn't known to this service."
        case "SignatureDoesNotMatch": return "The secret key doesn't match the access key."
        case "AccessDenied": return "These keys aren't allowed to use this bucket."
        case "NoSuchBucket": return "There is no bucket with this name."
        case "AuthorizationHeaderMalformed", "IllegalLocationConstraintException", "PermanentRedirect":
            return "The bucket is in another region. Check the Region."
        case "Network": return message
        default: return message.isEmpty ? "The service answered \(status) (\(code))." : message
        }
    }
}

/// A small S3 client for catalog backups (AT-079e): Test Connection, upload a file (multipart
/// above `multipartThreshold`, one part in memory at a time), list a folder, delete. Plain
/// URLSession and SigV4; no SDK. Cancelling the task cancels the request.
public struct S3Client: Sendable {
    public var bucket: S3Bucket
    var signer: S3Signer
    var session: URLSession

    /// Parts of 16 MB: S3's minimum is 5 MB and its maximum 10,000 parts (160 GB here).
    public static let partSize = 16 * 1024 * 1024
    public static let multipartThreshold = partSize

    public init(bucket: S3Bucket, credentials: S3Credentials, session: URLSession = .shared) {
        self.bucket = bucket
        self.signer = S3Signer(credentials: credentials, region: bucket.region)
        self.session = session
    }

    /// Settings' Test Connection: lists one key in the folder. Throws an `S3Error` in plain words.
    public func testConnection() async throws {
        _ = try await list(prefix: bucket.key(""), limit: 1)
    }

    /// Uploads `file` to `key`; returns the bytes sent. `progress` gets the fraction done.
    @discardableResult
    public func upload(_ file: URL, to key: String, contentType: String = "application/octet-stream",
                       progress: @Sendable (Double) -> Void = { _ in }) async throws -> Int64 {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
        if size <= Int64(Self.multipartThreshold) {
            let data = try Data(contentsOf: file)
            _ = try await send("PUT", key: key, body: data, headers: ["Content-Type": contentType])
            progress(1)
            return size
        }
        let created = try await send("POST", key: key, query: [("uploads", "")], headers: ["Content-Type": contentType])
        guard let uploadID = S3XML.firstValue("UploadId", in: created) else {
            throw S3Error(code: "InvalidResponse", message: "The service didn't start the upload.", status: 0)
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var parts: [(Int, String)] = []
            var sent: Int64 = 0
            var number = 1
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Self.partSize) ?? Data()
                if chunk.isEmpty { break }
                let (_, response) = try await sendWithResponse("PUT", key: key, query: [
                    ("partNumber", String(number)), ("uploadId", uploadID)], body: chunk)
                guard let etag = response.value(forHTTPHeaderField: "ETag") else {
                    throw S3Error(code: "InvalidResponse", message: "The service didn't confirm part \(number).", status: response.statusCode)
                }
                parts.append((number, etag))
                sent += Int64(chunk.count)
                progress(Double(sent) / Double(max(size, 1)))
                number += 1
            }
            let body = "<CompleteMultipartUpload>" + parts.map {
                "<Part><PartNumber>\($0.0)</PartNumber><ETag>\(S3XML.escape($0.1))</ETag></Part>"
            }.joined() + "</CompleteMultipartUpload>"
            let completed = try await send("POST", key: key, query: [("uploadId", uploadID)], body: Data(body.utf8),
                                           headers: ["Content-Type": "application/xml"])
            // S3 can answer 200 with an error inside when completing fails.
            if let code = S3XML.firstValue("Code", in: completed) {
                throw S3Error(code: code, message: S3XML.firstValue("Message", in: completed) ?? "", status: 200)
            }
            return sent
        } catch {
            // Don't leave parts behind (they cost storage until aborted).
            _ = try? await send("DELETE", key: key, query: [("uploadId", uploadID)])
            throw error
        }
    }

    /// The objects whose keys start with `prefix`, every page (or the first `limit`).
    public func list(prefix: String, limit: Int? = nil) async throws -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let limit { query.append(("max-keys", String(limit))) }
            if let token { query.append(("continuation-token", token)) }
            let data = try await send("GET", key: nil, query: query)
            let page = S3XML.listing(data)
            objects += page.objects
            token = page.truncated ? page.nextToken : nil
            if let limit, objects.count >= limit { break }
        } while token != nil
        return objects
    }

    public func delete(_ key: String) async throws {
        _ = try await send("DELETE", key: key)
    }

    // MARK: Requests

    @discardableResult
    func send(_ method: String, key: String?, query: [(String, String)] = [], body: Data = Data(),
              headers: [String: String] = [:]) async throws -> Data {
        try await sendWithResponse(method, key: key, query: query, body: body, headers: headers).0
    }

    func sendWithResponse(_ method: String, key: String?, query: [(String, String)] = [], body: Data = Data(),
                          headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = bucket.url(key: key, query: query) else {
            throw S3Error(code: "InvalidEndpoint", message: "The endpoint isn't a valid address.", status: 0)
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        signer.sign(&request, payloadHash: S3Signer.sha256Hex(body))
        let result: (Data, URLResponse)
        do {
            if method == "PUT" || method == "POST" {
                result = try await session.upload(for: request, from: body)
            } else {
                result = try await session.data(for: request)
            }
        } catch let error as URLError where error.code != .cancelled {
            throw S3Error(code: "Network", message: Self.describe(error), status: 0)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw S3Error(code: "InvalidResponse", message: "The service didn't answer over HTTP.", status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error(code: S3XML.firstValue("Code", in: data) ?? "HTTP\(http.statusCode)",
                          message: S3XML.firstValue("Message", in: data) ?? "", status: http.statusCode)
        }
        return (data, http)
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: return "The endpoint's server can't be found. Check the address."
        case .cannotConnectToHost: return "The endpoint's server isn't answering."
        case .notConnectedToInternet, .networkConnectionLost: return "This Mac isn't connected to the internet."
        case .timedOut: return "The service took too long to answer."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
            return "The endpoint's secure connection couldn't be checked."
        default: return error.localizedDescription
        }
    }
}

/// The few bits of S3's XML that Atelier reads.
enum S3XML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func firstValue(_ element: String, in data: Data) -> String? {
        elements(in: data).first { $0.name == element }?.text
    }

    struct Listing {
        var objects: [S3Object] = []
        var truncated = false
        var nextToken: String?
    }

    static func listing(_ data: Data) -> Listing {
        var listing = Listing()
        var current: S3Object?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for element in elements(in: data) {
            switch (element.name, element.path.last) {
            case ("Key", "Contents"): current = S3Object(key: element.text, size: 0, lastModified: nil)
            case ("Size", "Contents"): current?.size = Int64(element.text) ?? 0
            case ("LastModified", "Contents"):
                current?.lastModified = formatter.date(from: element.text) ?? plain.date(from: element.text)
            case ("Contents", _): if let current { listing.objects.append(current) }; current = nil
            case ("IsTruncated", _): listing.truncated = element.text == "true"
            case ("NextContinuationToken", _): listing.nextToken = element.text
            default: break
            }
        }
        return listing
    }

    struct Element {
        var name: String
        /// The enclosing elements, outermost first.
        var path: [String]
        var text: String
    }

    /// Every element as it closes (children before their parent), with its text.
    static func elements(in data: Data) -> [Element] {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.elements
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        var stack: [(String, String)] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append((name, ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].1 += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let (open, text) = stack.popLast() else { return }
            elements.append(Element(name: open, path: stack.map(\.0), text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
}
