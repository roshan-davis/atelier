import Foundation

/// One change an agent made, with each item's state before and after, so the change can be
/// undone later without overwriting anything done since. The app decides what "state" is (for
/// Atelier: a photo's rating, flag, label, keywords, title, caption and collections; for Easel:
/// a layer's properties). See Docs/Atelier-Agent-Actions.md, "Targets, waiting and undo".
public struct AgentChange<TargetID: Hashable & Sendable & CustomStringConvertible, State: Equatable & Sendable>: Sendable {
    /// "c-17": what the agent passes to `undo_change`.
    public let id: String
    public let clientID: String
    public let clientName: String
    /// What it did, as the person reads it: "Rate 3 stars".
    public let title: String
    public let date: Date
    /// In the order the call named them.
    public let targets: [TargetID]
    public let before: [TargetID: State]
    public let after: [TargetID: State]
    /// Why `undo_change` can't undo this change (it made new items, say), or nil.
    public let cantUndo: String?
    public internal(set) var undone: Bool

    /// True when nothing in the states changed (the photos already had that rating).
    public var changedNothing: Bool { before == after }
}

/// Why an undo was refused, in words for the agent and the person.
public enum AgentUndoRefusal: Error, Hashable, Sendable {
    case unknown(String)
    case notYours(String, owner: String)
    case alreadyUndone(String)
    case cantUndo(String, reason: String)
    /// A later change (the agent's own or another app's) touched the same items.
    case laterChange(String, later: String)
    /// Someone changed these items since, by hand or another way.
    case changedSince(String, items: [String])
    case gone(String, items: [String])

    public var message: String {
        switch self {
        case .unknown(let id):
            return "There is no change \(id). Changes are kept until the app quits."
        case .notYours(let id, let owner):
            return "Change \(id) was made by \(owner). An app can undo only its own changes."
        case .alreadyUndone(let id):
            return "Change \(id) is already undone."
        case .cantUndo(let id, let reason):
            return "Change \(id) can't be undone this way: \(reason)"
        case .laterChange(let id, let later):
            return "Change \(later) came after \(id) on the same items. Undo \(later) first."
        case .changedSince(let id, let items):
            return "Change \(id) is no longer the latest on \(Self.list(items)): they were changed since, so undoing "
                + "it would overwrite that work. Nothing was undone."
        case .gone(let id, let items):
            return "Change \(id) can't be undone: \(Self.list(items)) no longer exist."
        }
    }

    private static func list(_ items: [String]) -> String {
        let shown = items.prefix(10).joined(separator: ", ")
        return items.count > 10 ? "\(shown) and \(items.count - 10) more" : shown
    }
}

/// The changes agents made while the app runs, newest last. Undo works only while a change is
/// still the latest on its items: no later change touched them and their state is still what
/// the change left.
public struct AgentChangeLog<TargetID: Hashable & Sendable & CustomStringConvertible, State: Equatable & Sendable>: Sendable {
    public typealias Change = AgentChange<TargetID, State>

    public private(set) var changes: [Change] = []
    public let capacity: Int
    private var counter = 0

    public init(capacity: Int = 200) { self.capacity = capacity }

    /// Records a change and gives it the next id.
    @discardableResult
    public mutating func record(clientID: String, clientName: String, title: String, targets: [TargetID],
                                before: [TargetID: State], after: [TargetID: State], cantUndo: String? = nil,
                                date: Date = Date()) -> Change {
        counter += 1
        let change = Change(id: "c-\(counter)", clientID: clientID, clientName: clientName, title: title, date: date,
                            targets: targets, before: before, after: after, cantUndo: cantUndo, undone: false)
        changes.append(change)
        if changes.count > capacity { changes.removeFirst(changes.count - capacity) }
        return change
    }

    public func change(_ id: String) -> Change? { changes.first { $0.id == id } }

    /// The states to restore to undo `id`, or why not. `clientID` nil is the person (the toast's
    /// Undo button), who may undo any agent's change. `current` holds each item's state now;
    /// items missing from it are gone.
    public func undoPlan(_ id: String, clientID: String?, current: [TargetID: State]) -> Result<[TargetID: State], AgentUndoRefusal> {
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return .failure(.unknown(id)) }
        let change = changes[index]
        if let clientID, change.clientID != clientID { return .failure(.notYours(id, owner: change.clientName)) }
        if change.undone { return .failure(.alreadyUndone(id)) }
        if let reason = change.cantUndo { return .failure(.cantUndo(id, reason: reason)) }
        let items = Set(change.after.keys)
        if let later = changes[(index + 1)...].first(where: { !$0.undone && !items.isDisjoint(with: $0.after.keys) }) {
            return .failure(.laterChange(id, later: later.id))
        }
        let ordered = change.targets.filter { change.after[$0] != nil }
            + change.after.keys.filter { !change.targets.contains($0) }.sorted { $0.description < $1.description }
        let gone = ordered.filter { current[$0] == nil }
        if !gone.isEmpty { return .failure(.gone(id, items: gone.map(\.description))) }
        let edited = ordered.filter { current[$0] != change.after[$0] }
        if !edited.isEmpty { return .failure(.changedSince(id, items: edited.map(\.description))) }
        return .success(change.before.filter { items.contains($0.key) })
    }

    /// Marks a change undone once its states were restored.
    public mutating func markUndone(_ id: String) {
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return }
        changes[index].undone = true
    }
}
