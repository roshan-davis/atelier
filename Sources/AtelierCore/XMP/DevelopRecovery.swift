import Foundation

/// Portable current edits only. Keys are exact filenames, including extensions, because
/// Adobe-style sidecars are shared by same-stem RAW/JPEG originals.
enum DevelopRecovery {
    static let path = "atelier:DevelopRecovery"

    struct Packet: Codable {
        var formatVersion = 1
        var files: [String: String] = [:]
    }

    static func packet(_ json: String) throws -> Packet {
        let packet = try JSONDecoder().decode(Packet.self, from: Data(json.utf8))
        guard packet.formatVersion == 1 else { throw RecoveryError.unsupported }
        return packet
    }

    static func settings(_ json: String) throws -> DevelopSettings {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int,
              (1...DevelopSettings.currentSchemaVersion).contains(version) else {
            throw RecoveryError.unsupported
        }
        // Catalog decoding deliberately tolerates unreadable masks; recovery must never
        // silently claim success after dropping them.
        if let masks = object["masks"] {
            _ = try JSONDecoder().decode([DevelopSettings.Mask].self,
                                         from: JSONSerialization.data(withJSONObject: masks, options: .fragmentsAllowed))
        }
        if let profile = object["profile"] {
            _ = try JSONDecoder().decode(DevelopSettings.Profile.self,
                from: JSONSerialization.data(withJSONObject: profile, options: .fragmentsAllowed))
        }
        if let upright = object["upright"] {
            _ = try JSONDecoder().decode(DevelopSettings.Upright.self,
                from: JSONSerialization.data(withJSONObject: upright, options: .fragmentsAllowed))
        }
        return try DevelopSettings.decoded(from: json)
    }

    enum RecoveryError: LocalizedError {
        case unsupported, invalidSidecar, invalidRecovery, inconsistentHistory
        var errorDescription: String? {
            switch self {
            case .inconsistentHistory: return "The saved Lightfast history does not match the current edits. The sidecar was preserved."
            case .unsupported: return "Unsupported Lightfast XMP recovery version. The sidecar was preserved."
            case .invalidRecovery: return "The Lightfast XMP recovery data cannot be read. The sidecar was preserved."
            case .invalidSidecar: return "The existing XMP sidecar cannot be read. It was preserved."
            }
        }
    }
}
