import AppKit
import Foundation

/// Single-key commands, Lightroom-style. Each has a default key that can be changed in
/// Settings > Keyboard; overrides are stored in user defaults.
enum KeyAction: String, CaseIterable, Identifiable {
    case rating0, rating1, rating2, rating3, rating4, rating5
    case labelRed, labelYellow, labelGreen, labelBlue
    case pick, reject, unflag
    case grid, loupe, develop
    case beforeAfter, compareMode, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rating0: return "Clear rating"
        case .rating1, .rating2, .rating3, .rating4, .rating5:
            let stars = Int(String(rawValue.last!))!
            return "Rate \(stars) star\(stars == 1 ? "" : "s")"
        case .labelRed: return "Red label"
        case .labelYellow: return "Yellow label"
        case .labelGreen: return "Green label"
        case .labelBlue: return "Blue label"
        case .pick: return "Flag as picked"
        case .reject: return "Flag as rejected"
        case .unflag: return "Remove flag"
        case .grid: return "Grid view"
        case .loupe: return "Loupe view"
        case .develop: return "Develop"
        case .beforeAfter: return "Show before (toggle)"
        case .compareMode: return "Before and after: off, side by side, slider"
        case .zoom: return "Zoom: fit and 100%"
        }
    }

    var section: String {
        switch self {
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5: return "Rating"
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: return "Color labels"
        case .pick, .reject, .unflag: return "Flags"
        case .grid, .loupe, .develop, .zoom: return "Views"
        case .beforeAfter, .compareMode: return "Develop"
        }
    }

    /// Lightroom's keys.
    var defaultKey: String {
        switch self {
        case .rating0: return "0"
        case .rating1: return "1"
        case .rating2: return "2"
        case .rating3: return "3"
        case .rating4: return "4"
        case .rating5: return "5"
        case .labelRed: return "6"
        case .labelYellow: return "7"
        case .labelGreen: return "8"
        case .labelBlue: return "9"
        case .pick: return "p"
        case .reject: return "x"
        case .unflag: return "u"
        case .grid: return "g"
        case .loupe: return "e"
        case .develop: return "d"
        case .beforeAfter: return "\\"
        case .compareMode: return "y"
        case .zoom: return "z"
        }
    }
}

enum KeyBindings {
    private static func defaultsKey(_ action: KeyAction) -> String { "keys.\(action.rawValue)" }

    /// The key for an action; empty when the user removed it.
    static func key(for action: KeyAction) -> String {
        UserDefaults.standard.string(forKey: defaultsKey(action)) ?? action.defaultKey
    }

    static func action(for key: String) -> KeyAction? {
        KeyAction.allCases.first { self.key(for: $0) == key }
    }

    /// Assigns a key, taking it away from any other action that had it.
    static func set(_ key: String, for action: KeyAction) {
        if !key.isEmpty {
            for other in KeyAction.allCases where other != action && self.key(for: other) == key {
                UserDefaults.standard.set("", forKey: defaultsKey(other))
            }
        }
        if key == action.defaultKey {
            UserDefaults.standard.removeObject(forKey: defaultsKey(action))
        } else {
            UserDefaults.standard.set(key, forKey: defaultsKey(action))
        }
    }

    static func resetAll() {
        for action in KeyAction.allCases { UserDefaults.standard.removeObject(forKey: defaultsKey(action)) }
    }

    /// How a key is shown: letters in capitals, symbols as typed.
    static func display(_ key: String) -> String {
        switch key {
        case "": return "—"
        case " ": return "Space"
        default: return key.uppercased()
        }
    }

    /// Keys reserved for navigation, which can't be assigned.
    static func isAssignable(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let scalar = characters.unicodeScalars.first else { return false }
        // Arrows, Return, Escape, Tab, Delete and function keys stay as they are.
        return scalar.value >= 0x20 && scalar.value < 0xF700 && scalar.value != 0x7F
    }
}
