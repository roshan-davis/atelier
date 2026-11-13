import Foundation

/// What an action does, which every action must say. An agent's tier follows from it by fixed
/// rules (`tier`), so a new action is usable by agents as soon as it exists, with the right
/// safety. See Docs/Atelier-Agent-Actions.md, "Always in sync".
public enum ActionKind: String, CaseIterable, Sendable {
    /// Looks only: nothing in the library or on screen changes.
    case reads
    /// Changes only what is on screen: a mode, the zoom, a tool or an overlay.
    case view
    /// Changes the library or a document's settings, in a way that can be undone.
    case edit
    /// Writes files outside the library (export, sidecars, saves) or starts a long job.
    case writesFiles
    /// Hands files to another app.
    case opensApp
    /// Removes items, files or records.
    case deletes

    /// How an agent may run an action of this kind.
    public var tier: AgentTier {
        switch self {
        case .reads, .view: return .runs
        case .edit: return .undoable
        case .writesFiles, .opensApp: return .asksFirst
        case .deletes: return .never
        }
    }

    public var summary: String {
        switch self {
        case .reads: return "Looks only."
        case .view: return "Changes only what is on screen."
        case .edit: return "Changes the library or a document's settings; can be undone."
        case .writesFiles: return "Writes files or starts a long job."
        case .opensApp: return "Hands files to another app."
        case .deletes: return "Removes items, files or records."
        }
    }
}

/// How an agent may run an action. Enforced by the app (AT-050b onward), never by the chat client.
public enum AgentTier: String, CaseIterable, Sendable {
    /// Runs freely.
    case runs
    /// Runs as one named undo step, with a notice in the window.
    case undoable
    /// The person allows it first, in the app's own window.
    case asksFirst
    /// Never listed or runnable by an agent.
    case never
}
