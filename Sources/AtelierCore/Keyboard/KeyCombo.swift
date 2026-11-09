import Foundation

/// A key with optional ⌃ ⌥ ⇧ modifiers, for the commands in Settings > Keyboard.
///
/// Stored as text: the modifier symbols in the order ⌃ ⌥ ⇧, then the key ("t", "⇥" for Tab,
/// "F6"). A plain single character, the only format older settings used, reads as that key
/// with no modifiers, so existing customizations keep working. ⌘ is never part of a combo:
/// ⌘ shortcuts belong to the menus.
public struct KeyCombo: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
    }

    /// The Tab key's name in a stored combo.
    public static let tab = "⇥"

    public var modifiers: Modifiers
    /// A lowercased character, `KeyCombo.tab`, or a function key "F1" … "F12".
    public var key: String

    public init(_ key: String, modifiers: Modifiers = []) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    private static let symbols: [(Character, Modifiers)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift)]

    /// Reads a stored combo; nil for "" (a command with its key removed).
    public init?(stored: String) {
        var modifiers: Modifiers = []
        var rest = Substring(stored)
        // A key is never a modifier symbol, so a lone symbol is a key, not a modifier.
        while rest.count > 1, let first = rest.first, let match = Self.symbols.first(where: { $0.0 == first }) {
            modifiers.insert(match.1)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        self.init(String(rest), modifiers: modifiers)
    }

    public var stored: String {
        Self.symbols.filter { modifiers.contains($0.1) }.map { String($0.0) }.joined() + key
    }

    /// How Settings and Help show it: "⌃Tab", "⇧W", "F6", "Space".
    public var display: String {
        let name: String
        switch key {
        case Self.tab: name = "Tab"
        case " ": name = "Space"
        default: name = key.uppercased()
        }
        return Self.symbols.filter { modifiers.contains($0.1) }.map { String($0.0) }.joined() + name
    }

    /// The command bound to a pressed combo. An exact match wins. Failing that, a press with
    /// only ⇧ also finds the plain key's command, as single keys always have (⇧P still picks).
    public static func command<Command>(for pressed: KeyCombo, in bindings: [(Command, KeyCombo?)]) -> Command? {
        if let exact = bindings.first(where: { $0.1 == pressed }) { return exact.0 }
        guard pressed.modifiers == .shift else { return nil }
        let plain = KeyCombo(pressed.key)
        return bindings.first(where: { $0.1 == plain })?.0
    }
}
