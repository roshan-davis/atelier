import Foundation

/// An app's whole list of actions. Menus, keys and agents all read from it; the committed JSON
/// copy (`json`) shows in each PR's diff which agent commands changed.
public struct ActionCatalog: Sendable {
    /// Bumped when the catalog file's own layout changes.
    public static let formatVersion = 1

    public let app: String
    public let actions: [ActionDescriptor]

    public init(app: String, actions: [ActionDescriptor]) {
        self.app = app
        self.actions = actions
    }

    public func descriptor(_ id: ActionID) -> ActionDescriptor? {
        actions.first { $0.id == id }
    }

    public func contains(_ id: ActionID) -> Bool { descriptor(id) != nil }

    /// Everything wrong with the list: repeated ids, badly formed ids, missing titles or
    /// summaries, opt-outs without a reason, parameter types whose schema can't be read.
    public var problems: [String] {
        var problems: [String] = []
        var seen: Set<ActionID> = []
        for action in actions {
            let id = action.id.rawValue
            if !seen.insert(action.id).inserted { problems.append("\(id): two actions share this id") }
            if !action.id.isWellFormed { problems.append("\(id): ids are lowercase dotted words, like library.grid") }
            if action.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(id): no title") }
            if action.place.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(id): no place") }
            if action.summary.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(id): no summary") }
            if let reason = action.hiddenReason, reason.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(id): hidden from agents without a reason")
            }
            if action.version < 1 { problems.append("\(id): versions start at 1") }
            problems += action.parameters.problems.map { "\(id): \($0)" }
        }
        // Shortcuts may repeat: an app can give one key to two actions that are never enabled
        // together (Atelier's ⌘S saves in HDR and writes XMP elsewhere).
        return problems
    }

    /// The catalog as JSON, actions in id order.
    public var json: JSONValue {
        .object([
            "app": .string(app),
            "format": .int(Self.formatVersion),
            "tiers": .object(Dictionary(uniqueKeysWithValues: ActionKind.allCases.map {
                ($0.rawValue, .string($0.tier.rawValue))
            })),
            "actions": .array(actions.sorted { $0.id < $1.id }.map(\.json)),
        ])
    }
}

public extension ActionDescriptor {
    var json: JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "title": .string(title),
            "place": .string(place),
            "summary": .string(summary),
            "kind": .string(kind.rawValue),
            "tier": .string(tier.rawValue),
            "exposed": .bool(isExposed),
            "version": .int(version),
            "parameters": parameters.json,
        ]
        if let targets { members["targets"] = .string(targets.rawValue) }
        if let shortcut { members["shortcut"] = .string(shortcut.display) }
        if let hiddenReason { members["hiddenReason"] = .string(hiddenReason) }
        return .object(members)
    }
}
