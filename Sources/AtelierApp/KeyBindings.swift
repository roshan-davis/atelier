import AppKit
import AtelierCore
import Foundation

/// Keyboard commands, Lightroom-style. Each has a default key (a single key, or one with ⌃ ⌥ ⇧)
/// that can be changed in Settings > Keyboard; overrides are stored in user defaults.
/// Navigation keys (arrows, Tab, Return, Esc, Delete) are fixed, as macOS expects.
enum KeyAction: String, CaseIterable, Identifiable {
    case rating0, rating1, rating2, rating3, rating4, rating5
    case labelRed, labelYellow, labelGreen, labelBlue
    case pick, reject, unflag
    case grid, loupe, develop
    case beforeAfter, compareMode, zoom, crop, treatment, whiteBalance
    case linearGradient, brush, maskOverlay, clipping
    case masking, radialGradient, guidedUpright
    case nextArea, previousArea

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
        case .reject: return "Flag as rejected (in the crop tool: switch landscape and portrait)"
        case .unflag: return "Remove flag"
        case .grid: return "Grid view"
        case .loupe: return "Loupe view"
        case .develop: return "Develop"
        case .beforeAfter: return "Show before (toggle)"
        case .compareMode: return "Before and after: off, side by side, slider"
        case .zoom: return "Zoom: fit and 100%"
        case .crop: return "Crop & Straighten"
        case .treatment: return "Black & White treatment (toggle)"
        case .whiteBalance: return "White Balance Selector"
        case .linearGradient: return "Masking: Linear Gradient (Shift for Radial Gradient)"
        case .brush: return "Masking: Brush"
        case .maskOverlay: return "Masking: show overlay (toggle)"
        case .clipping: return "Show clipping on the photo (toggle)"
        case .masking: return "Masking: open or close"
        case .radialGradient: return "Masking: Radial Gradient"
        case .guidedUpright: return "Transform: Guided Upright"
        case .nextArea: return "Focus: next area (Presets, photo, right panel)"
        case .previousArea: return "Focus: previous area"
        }
    }

    var section: String {
        switch self {
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5: return "Rating"
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: return "Color labels"
        case .pick, .reject, .unflag: return "Flags"
        case .grid, .loupe, .develop, .zoom: return "Views"
        case .beforeAfter, .compareMode, .crop, .treatment, .whiteBalance, .linearGradient, .brush, .maskOverlay, .clipping,
             .masking, .radialGradient, .guidedUpright: return "Develop"
        case .nextArea, .previousArea: return "Keyboard focus"
        }
    }

    /// Lightroom's keys, and the Mac's ⌃Tab for moving between areas.
    var defaultCombo: KeyCombo? { KeyCombo(stored: defaultKey) }

    /// The default as stored text (see `KeyCombo`).
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
        case .crop: return "r"
        case .treatment: return "v"
        case .whiteBalance: return "w"
        case .linearGradient: return "m"
        case .brush: return "k"
        case .maskOverlay: return "o"
        case .clipping: return "j"
        case .masking: return "⇧w"
        case .radialGradient: return "⇧m"
        case .guidedUpright: return "⇧t"
        case .nextArea: return "⌃" + KeyCombo.tab
        case .previousArea: return "⌃⇧" + KeyCombo.tab
        }
    }
}

enum KeyBindings {
    private static func defaultsKey(_ action: KeyAction) -> String { "keys.\(action.rawValue)" }

    /// The stored key for an action (see `KeyCombo`); empty when the user removed it.
    static func key(for action: KeyAction) -> String {
        UserDefaults.standard.string(forKey: defaultsKey(action)) ?? action.defaultKey
    }

    static func combo(for action: KeyAction) -> KeyCombo? { KeyCombo(stored: key(for: action)) }

    static func action(for combo: KeyCombo) -> KeyAction? {
        KeyCombo.command(for: combo, in: KeyAction.allCases.map { ($0, self.combo(for: $0)) })
    }

    /// A plain key with no modifiers, for callers that only handle single keys.
    static func action(for key: String) -> KeyAction? { action(for: KeyCombo(key)) }

    /// The command for a key press, or nil. ⌘ presses belong to the menus.
    static func action(for event: NSEvent) -> KeyAction? {
        combo(from: event).flatMap { action(for: $0) }
    }

    /// Assigns a key, taking it away from any other action that had it.
    static func set(_ key: String, for action: KeyAction) {
        let combo = KeyCombo(stored: key)
        if combo != nil {
            for other in KeyAction.allCases where other != action && self.combo(for: other) == combo {
                UserDefaults.standard.set("", forKey: defaultsKey(other))
            }
        }
        let stored = combo?.stored ?? ""
        if stored == action.defaultKey {
            UserDefaults.standard.removeObject(forKey: defaultsKey(action))
        } else {
            UserDefaults.standard.set(stored, forKey: defaultsKey(action))
        }
    }

    static func resetAll() {
        for action in KeyAction.allCases { UserDefaults.standard.removeObject(forKey: defaultsKey(action)) }
    }

    /// How a stored key is shown: "⇧W", "⌃Tab", "F6", "—" when removed.
    static func display(_ key: String) -> String {
        KeyCombo(stored: key)?.display ?? "—"
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The combo a key press makes, or nil for ⌘ presses and keys that can't be assigned:
    /// arrows, Return, Esc, Delete and plain Tab stay as they are. Tab counts only with ⌃ or ⌥,
    /// since plain Tab and ⇧Tab move between controls.
    static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return nil }
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if event.keyCode == 48 {  // Tab
            guard !modifiers.isDisjoint(with: [.control, .option]) else { return nil }
            return KeyCombo(KeyCombo.tab, modifiers: modifiers)
        }
        if let name = functionKeys[event.keyCode] {
            // Plain F6 is View > Show Filmstrip, as in Lightroom.
            if name == "F6", modifiers.isEmpty { return nil }
            return KeyCombo(name, modifiers: modifiers)
        }
        // With ⌥ the typed character changes (⌥W types ∑), so read the key without it.
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value < 0xF700, scalar.value != 0x7F else { return nil }
        // ⇧ changes a digit or symbol into another character (⇧1 is !), which then counts as
        // its own key; ⇧ with a letter stays a modifier, so ⇧W reads as ⇧ + W.
        if modifiers.contains(.shift), characters.lowercased() == characters.uppercased() {
            modifiers.remove(.shift)
        }
        return KeyCombo(characters, modifiers: modifiers)
    }

    /// Whether a press can be assigned to a command in Settings.
    static func isAssignable(_ event: NSEvent) -> Bool { combo(from: event) != nil }
}
