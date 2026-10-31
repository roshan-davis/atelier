import Foundation

/// History is separate from the v1 current-settings packet so older sidecars stay readable.
/// The settings binding detects a stale history packet left by an older Lightfast writer.
enum HistoryRecovery {
    static let path = "atelier:HistoryRecovery"

    struct Entry: Codable {
        var settings: String
        var history: String
    }

    struct Packet: Codable {
        var formatVersion = 1
        var files: [String: Entry] = [:]
    }

    static func packet(_ json: String) throws -> Packet {
        let packet = try JSONDecoder().decode(Packet.self, from: Data(json.utf8))
        guard packet.formatVersion == 1 else { throw DevelopRecovery.RecoveryError.unsupported }
        return packet
    }

    static func history(_ entry: Entry, settings: DevelopSettings) throws -> DevelopHistory {
        guard try DevelopRecovery.settings(entry.settings) == settings else {
            throw DevelopRecovery.RecoveryError.inconsistentHistory
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(entry.history.utf8)) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]],
              let snapshots = object["snapshots"] as? [[String: Any]],
              let position = object["position"] as? Int,
              (steps.isEmpty ? position == -1 : steps.indices.contains(position)) else {
            throw DevelopRecovery.RecoveryError.invalidRecovery
        }
        // Catalog decoding is intentionally forgiving. Portable recovery must validate all
        // historical settings before decoding, including masks in unselected steps/snapshots.
        for item in steps + snapshots {
            guard let value = item["settings"] else { throw DevelopRecovery.RecoveryError.invalidRecovery }
            let data = try JSONSerialization.data(withJSONObject: value)
            _ = try DevelopRecovery.settings(String(decoding: data, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode(DevelopHistory.self, from: Data(entry.history.utf8))
        guard Set(history.snapshots.map(\.id)).count == history.snapshots.count else {
            throw DevelopRecovery.RecoveryError.invalidRecovery
        }
        guard history.steps.isEmpty || history.steps[position].settings == settings else {
            throw DevelopRecovery.RecoveryError.inconsistentHistory
        }
        return history
    }

    static func catalogHistory(_ json: String, settingsJSON: String) throws -> DevelopHistory {
        // v3 catalogs used [] for history before named steps were introduced.
        let historyJSON = json.trimmingCharacters(in: .whitespacesAndNewlines) == "[]"
            ? try DevelopHistory().encoded() : json
        return try history(.init(settings: settingsJSON, history: historyJSON),
                           settings: DevelopRecovery.settings(settingsJSON))
    }
}
