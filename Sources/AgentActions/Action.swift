import Foundation

/// An action's stable id, such as `library.grid`: lowercase dotted words.
public struct ActionID: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: ActionID, rhs: ActionID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Two or more dot-separated words, each starting with a lowercase letter, letters and
    /// digits only: `photo.setRating`.
    public var isWellFormed: Bool {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
            return part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        }
    }
}

/// What an action's resolved ids refer to. Each app names its own (Atelier: photos; Easel:
/// documents, layers).
public struct TargetKind: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A menu key equivalent, independent of AppKit and SwiftUI.
public struct KeyShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// One character ("i", "=", "[") or a function key name ("F6").
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// As the Mac shows it: ⌃⌥⇧⌘ then the key, as in "⇧⌘I".
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key)
    }
}

/// Everything an agent, a menu or a test needs to know about an action, without its handler.
public struct ActionDescriptor: Hashable, Sendable {
    public let id: ActionID
    /// The menu title, as the person sees it.
    public let title: String
    /// Where the person finds it, in the app's own names: "Library > Grid", "Photo menu", "Key Y".
    public let place: String
    /// One sentence for agents on what it does.
    public let summary: String
    public let kind: ActionKind
    /// What the ids it acts on refer to; nil when it acts on the app, not on items.
    public let targets: TargetKind?
    public let parameters: ParameterSchema
    public let shortcut: KeyShortcut?
    /// Why agents may not use it; nil (the default) means it is exposed under its kind's tier.
    public let hiddenReason: String?
    /// Raised when the parameters or the meaning change, so agents can tell.
    public let version: Int

    public var tier: AgentTier { kind.tier }
    public var isExposed: Bool { hiddenReason == nil && tier != .never }
}

/// A typed action: its descriptor and its parameter type. Apps declare these as static constants
/// (`AtelierAction.grid`), and typed agent tools name them, so removing one is a build error.
public struct Action<P: ActionParameters>: Hashable, Sendable {
    public let descriptor: ActionDescriptor
    public var id: ActionID { descriptor.id }

    public init(_ id: ActionID, _ title: String, place: String, summary: String, kind: ActionKind,
                targets: TargetKind? = nil, shortcut: KeyShortcut? = nil, hidden reason: String? = nil,
                version: Int = 1, parameters: P.Type = P.self) {
        descriptor = ActionDescriptor(id: id, title: title, place: place, summary: summary, kind: kind,
                                      targets: targets, parameters: .of(P.self), shortcut: shortcut,
                                      hiddenReason: reason, version: version)
    }

    public static func == (lhs: Action, rhs: Action) -> Bool { lhs.descriptor == rhs.descriptor }
    public func hash(into hasher: inout Hasher) { hasher.combine(descriptor) }
}
