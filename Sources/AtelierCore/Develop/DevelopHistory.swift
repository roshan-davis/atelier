import Foundation

/// A photo's edit history and snapshots, stored with its develop settings.
///
/// Steps are named like Lightroom's ("Exposure +0.60", "Crop & Straighten"); `position` is the
/// step the photo currently shows, so undo and redo move it, and a new edit after undoing
/// drops the steps after it.
public struct DevelopHistory: Codable, Hashable, Sendable {
    public struct Step: Codable, Hashable, Sendable {
        public var name: String
        public var date: Date
        public var settings: DevelopSettings

        public init(name: String, date: Date = Date(), settings: DevelopSettings) {
            self.name = name
            self.date = date
            self.settings = settings
        }
    }

    public struct Snapshot: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var date: Date
        public var settings: DevelopSettings

        public init(id: UUID = UUID(), name: String, date: Date = Date(), settings: DevelopSettings) {
            self.id = id
            self.name = name
            self.date = date
            self.settings = settings
        }
    }

    /// Steps kept per photo; the oldest go first.
    public static let maximumSteps = 500

    public var steps: [Step] = []
    public var position = -1
    public var snapshots: [Snapshot] = []

    public init() {}

    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position >= 0 && position < steps.count - 1 }

    /// Adds a step for `settings`. `previous` is what the photo looked like before, recorded
    /// as the first step when the history is empty.
    public mutating func record(_ name: String, settings: DevelopSettings, previous: DevelopSettings) {
        if steps.isEmpty {
            steps = [Step(name: previous.isNeutral ? "Import" : "Earlier Edits", settings: previous)]
            position = 0
        }
        if position < steps.count - 1 { steps.removeSubrange((position + 1)...) }
        // Nothing changed: no new step.
        guard steps.last?.settings != settings else { return }
        steps.append(Step(name: name, settings: settings))
        if steps.count > Self.maximumSteps {
            // Keep the first step so the photo's starting point is never lost.
            steps.remove(at: 1)
        }
        position = steps.count - 1
    }

    /// Keeps only the current state as a single step.
    public mutating func clear() {
        guard position >= 0, position < steps.count else { return }
        let current = steps[position]
        steps = [Step(name: "History Cleared", date: current.date, settings: current.settings)]
        position = 0
    }

    // MARK: Storage

    private enum CodingKeys: String, CodingKey { case steps, position, snapshots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? steps.count - 1
        snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
        position = min(max(steps.isEmpty ? -1 : 0, position), steps.count - 1)
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Reads stored history; anything unreadable (including the empty list older catalogs
    /// stored) starts a fresh history.
    public static func decoded(from json: String) -> DevelopHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DevelopHistory.self, from: Data(json.utf8))) ?? DevelopHistory()
    }
}
