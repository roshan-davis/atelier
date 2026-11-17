import Foundation
import Security

/// Where a location's secret lives. Atelier's is the macOS Keychain (`KeychainSecrets`); tests
/// use `MemorySecrets`. The catalog keeps only the item's random reference, never the secret.
public protocol SecretStore: Sendable {
    func read(_ reference: String) -> Data?
    func write(_ secret: Data, reference: String, label: String) throws
    func delete(_ reference: String)
}

/// The login Keychain: one generic password per location, service "Atelier Storage", account
/// the location's reference, labelled "Atelier: <location name>" (PRD) so it reads plainly in
/// Keychain Access.
public struct KeychainSecrets: SecretStore {
    public static let service = "Atelier Storage"

    public init() {}

    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: reference]
    }

    public func read(_ reference: String) -> Data? {
        var lookup = query(reference)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ secret: Data, reference: String, label: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: secret, kSecAttrLabel as String: label]
        var status = SecItemUpdate(query(reference) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(reference)
            item.merge(attributes) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The Keychain didn't save the keys: \(reason)"])
        }
    }

    public func delete(_ reference: String) {
        SecItemDelete(query(reference) as CFDictionary)
    }
}

/// Secrets in memory, for tests.
public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (Data, String)] = [:]

    public init() {}

    public func read(_ reference: String) -> Data? { lock.withLock { items[reference]?.0 } }
    public func label(_ reference: String) -> String? { lock.withLock { items[reference]?.1 } }
    public func write(_ secret: Data, reference: String, label: String) throws {
        lock.withLock { items[reference] = (secret, label) }
    }
    public func delete(_ reference: String) { lock.withLock { _ = items.removeValue(forKey: reference) } }
}

extension SecretStore {
    public func credentials(_ reference: String) -> S3Credentials? {
        read(reference).flatMap { try? JSONDecoder().decode(S3Credentials.self, from: $0) }
    }

    public func save(_ credentials: S3Credentials, reference: String, locationName: String) throws {
        try write(JSONEncoder().encode(credentials), reference: reference, label: "Atelier: \(locationName)")
    }
}
