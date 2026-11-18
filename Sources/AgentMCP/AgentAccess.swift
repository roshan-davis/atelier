import AgentActions
import Foundation

/// How much a chat app may do in the app. A ceiling: the app grants one per client, and every
/// list and every run is checked against it. See Docs/Atelier-Agent-Actions.md, "Which commands
/// an agent can see".
public enum AgentProfile: String, CaseIterable, Codable, Comparable, Sendable {
    /// Read only.
    case look
    /// Adds library and cull changes (and changing what's on screen).
    case organize
    /// Adds editing (Develop, presets, masks).
    case edit
    /// Adds the actions that ask first: export, other apps, AI jobs.
    case everything

    public var title: String {
        switch self {
        case .look: return "Look"
        case .organize: return "Organize"
        case .edit: return "Edit"
        case .everything: return "Everything"
        }
    }

    public var summary: String {
        switch self {
        case .look: return "Reads the library. Changes nothing."
        case .organize: return "Also rates, flags, labels, collects and culls."
        case .edit: return "Also edits in Develop."
        case .everything: return "Also exports, opens other apps and runs AI, each after you allow it."
        }
    }

    public static func < (lhs: AgentProfile, rhs: AgentProfile) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The lowest profile that may use an action, or nil when no agent may. `editProfile` says
    /// which profile an app's `edit` actions need (library edits: organize; Develop: edit).
    public static func minimum(for action: ActionDescriptor,
                               editProfile: (ActionDescriptor) -> AgentProfile) -> AgentProfile? {
        guard action.isExposed else { return nil }
        switch action.kind {
        case .reads: return .look
        case .view: return .organize
        case .edit: return editProfile(action)
        case .writesFiles, .opensApp: return .everything
        case .deletes: return nil
        }
    }
}

/// Who is connecting, as the app checked it (never as the client names itself).
public struct AgentClient: Hashable, Sendable {
    /// Stable id for grants: the launching app's bundle id and signing team, such as
    /// `com.anthropic.claudefordesktop#Q6L2SF6YDW`.
    public var id: String
    /// The launching app's name: "Claude", "Cherry Studio", "Terminal".
    public var name: String
    /// The launching app's path, for Settings.
    public var path: String?
    /// The helper process that connected.
    public var pid: Int32
    /// The profile the helper asked for (`--profile`); only a request.
    public var requestedProfile: AgentProfile?
    /// What the client called itself in `initialize` (unchecked, shown for information).
    public var clientInfo: String?
    /// A paired phone over the HTTP listener (AT-050f), not a helper on this Mac: nobody may be at
    /// the Mac, so the app must never raise a sheet for it.
    public var isRemote: Bool

    public init(id: String, name: String, path: String? = nil, pid: Int32, requestedProfile: AgentProfile? = nil,
                clientInfo: String? = nil, isRemote: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.pid = pid
        self.requestedProfile = requestedProfile
        self.clientInfo = clientInfo
        self.isRemote = isRemote
    }
}

/// A stored decision about one client.
public struct AgentGrant: Codable, Hashable, Sendable, Identifiable {
    public var id: String { clientID }
    public var clientID: String
    public var name: String
    public var path: String?
    /// nil: don't allow.
    public var profile: AgentProfile?
    public var decidedAt: Date
    public var lastSeen: Date?

    public init(clientID: String, name: String, path: String? = nil, profile: AgentProfile?, decidedAt: Date = Date(),
                lastSeen: Date? = nil) {
        self.clientID = clientID
        self.name = name
        self.path = path
        self.profile = profile
        self.decidedAt = decidedAt
        self.lastSeen = lastSeen
    }
}

/// The answer to "may this client use the app now?".
public enum AgentAuthorization: Hashable, Sendable {
    case allowed(AgentProfile)
    case denied(String)
}
