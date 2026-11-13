import Foundation

public extension AgentGrant {
    /// What this stored decision allows for `client` now: the granted profile, or less when the
    /// helper asked for less. Asking for more (`--profile everything`) never raises it.
    func authorization(for client: AgentClient, appName: String) -> AgentAuthorization {
        guard let profile else {
            return .denied("\(appName) doesn't allow \(client.name). To change that, open \(appName) > Settings… > Agents.")
        }
        if let requested = client.requestedProfile, requested < profile { return .allowed(requested) }
        return .allowed(profile)
    }
}

/// The grants, one per checked client id, kept in user defaults (Settings > Agents edits them).
public final class AgentGrantStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "agents.grants") {
        self.defaults = defaults
        self.key = key
    }

    /// Every grant, most recently seen first.
    public var all: [AgentGrant] {
        lock.withLock { load() }.sorted { ($0.lastSeen ?? $0.decidedAt) > ($1.lastSeen ?? $1.decidedAt) }
    }

    public func grant(for clientID: String) -> AgentGrant? {
        lock.withLock { load().first { $0.clientID == clientID } }
    }

    /// Adds or replaces the grant for its client.
    public func save(_ grant: AgentGrant) {
        lock.withLock {
            var grants = load().filter { $0.clientID != grant.clientID }
            grants.append(grant)
            store(grants)
        }
    }

    public func remove(clientID: String) {
        lock.withLock { store(load().filter { $0.clientID != clientID }) }
    }

    /// Records that a client connected, so Settings can say when each was last used.
    public func touch(clientID: String, at date: Date = Date()) {
        lock.withLock {
            var grants = load()
            guard let index = grants.firstIndex(where: { $0.clientID == clientID }) else { return }
            grants[index].lastSeen = date
            store(grants)
        }
    }

    private func load() -> [AgentGrant] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentGrant].self, from: data)) ?? []
    }

    private func store(_ grants: [AgentGrant]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(grants) { defaults.set(data, forKey: key) }
    }
}

/// One line of the activity log in Settings > Agents.
public struct AgentActivity: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case connected, disconnected, allowed, denied, call, failed }

    public let id: UUID
    public let date: Date
    public let clientName: String
    public let kind: Kind
    /// "search_photos", "Allowed as Look", the error text…
    public let text: String

    public init(date: Date = Date(), clientName: String, kind: Kind, text: String) {
        self.id = UUID()
        self.date = date
        self.clientName = clientName
        self.kind = kind
        self.text = text
    }
}

/// The newest `capacity` activity lines, newest first.
public struct AgentActivityLog: Sendable {
    public private(set) var entries: [AgentActivity] = []
    public let capacity: Int

    public init(capacity: Int = 200) { self.capacity = capacity }

    public mutating func add(_ activity: AgentActivity) {
        entries.insert(activity, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    public mutating func clear() { entries.removeAll() }
}
