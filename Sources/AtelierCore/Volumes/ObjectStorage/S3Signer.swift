import CryptoKit
import Foundation

/// The access key pair of an S3-compatible bucket. Only ever held in memory and in the Keychain
/// (`StorageKeychain`); never in the catalog, its backups, logs or anything an agent sees.
public struct S3Credentials: Sendable, Equatable, Codable {
    public var accessKey: String
    public var secretKey: String

    public init(accessKey: String, secretKey: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
    }
}

/// AWS Signature Version 4 for S3 (AT-079e), which every S3-compatible service accepts (AWS,
/// Backblaze B2, Cloudflare R2, Wasabi, MinIO). Signs the host, `x-amz-date`,
/// `x-amz-content-sha256` and any other header already on the request.
public struct S3Signer: Sendable {
    public var credentials: S3Credentials
    public var region: String
    public var service = "s3"

    public init(credentials: S3Credentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    /// The SHA-256 of an empty body, for requests without one.
    public static let emptyPayloadHash = sha256Hex(Data())

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` to `request`.
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        let (amzDate, day) = Self.timestamps(date)
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        guard let url = request.url else { return }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["host"] = Self.hostHeader(url)
        let canonical = Self.canonicalRequest(method: request.httpMethod ?? "GET", url: url,
                                              headers: headers, payloadHash: payloadHash)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonical.request.utf8))].joined(separator: "\n")
        let signature = signingKey(day: day).authenticationCode(for: toSign).s3Hex
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), "
                         + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    func signingKey(day: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(credentials.secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return key
    }

    // MARK: Canonical form

    static func timestamps(_ date: Date) -> (amzDate: String, day: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    /// `host` or `host:port` when the port isn't the scheme's default.
    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let standard = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return standard ? host : "\(host):\(port)"
    }

    static func canonicalRequest(method: String, url: URL, headers: [String: String],
                                 payloadHash: String) -> (request: String, signedHeaders: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The path as sent (already percent-encoded once, as S3 wants; S3 doesn't encode twice).
        let path = components?.percentEncodedPath ?? url.path
        let query = canonicalQuery(components?.percentEncodedQuery)
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            lowered[name.lowercased()] = trimmed
        }
        let names = lowered.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lowered[$0]!)\n" }.joined()
        let signed = names.joined(separator: ";")
        let request = [method, path.isEmpty ? "/" : path, query, canonicalHeaders, signed, payloadHash].joined(separator: "\n")
        return (request, signed)
    }

    /// Query pairs decoded, encoded again the SigV4 way, and sorted by name then value.
    static func canonicalQuery(_ encoded: String?) -> String {
        guard let encoded, !encoded.isEmpty else { return "" }
        let pairs = encoded.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return (uriEncode(name), uriEncode(value))
        }
        return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// RFC 3986 encoding: everything but A–Z a–z 0–9 - _ . ~ (and `/` when `keepSlash`).
    static func uriEncode(_ text: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).s3Hex
    }
}

private extension SymmetricKey {
    func authenticationCode(for text: String) -> HashedAuthenticationCode<SHA256> {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: self)
    }
}

extension Sequence where Element == UInt8 {
    var s3Hex: String { map { String(format: "%02x", $0) }.joined() }
}
