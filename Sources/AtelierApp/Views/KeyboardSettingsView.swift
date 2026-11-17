import AppKit
import AtelierCore
import SwiftUI

/// Settings > Keyboard: a map of the keyboard showing which command each key runs (like Final Cut
/// Pro's Command Editor), then every command, grouped, with its key drawn as key caps. Click a
/// command's key and press a new one; click a key on the map to find its command.
struct KeyboardSettings: View {
    @State private var recording: KeyAction?
    @State private var monitor: Any?
    /// Bumped after every change so the map and rows re-read their keys.
    @State private var revision = 0
    @State private var query = ""
    @State private var layer: KeyCombo.Modifiers = []
    @State private var highlighted: KeyAction?

    private var sections: [(title: String, actions: [KeyAction])] {
        var result: [(title: String, actions: [KeyAction])] = []
        for action in KeyAction.allCases where matches(action) {
            if result.last?.title == action.section {
                result[result.count - 1].actions.append(action)
            } else {
                result.append((action.section, [action]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    if query.isEmpty {
                        SettingsSection("Keyboard Map") {
                            KeyboardMap(layer: $layer, highlighted: highlighted, revision: revision) { action in
                                highlighted = action
                                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(action, anchor: .center) }
                            }
                        } footer: {
                            Text("Each key shows the command it runs; hover for its name, click to find it below. Choose ⇧, ⌃ or ⌥ to see the keys used with them. Arrows, Tab, Return, Esc, Delete, F6 and ⌘ shortcuts stay fixed; menu shortcuts like ⌘E are in Help > Keyboard Shortcuts (⌘/).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sections, id: \.title) { section in
                        if query.isEmpty {
                            SettingsSection(section.title, id: "keys." + section.title) {
                                rows(section.actions)
                            }
                        } else {
                            // While searching, every match shows, even in a closed section.
                            Section(section.title) { rows(section.actions) }
                        }
                    }
                    if sections.isEmpty {
                        Text("No command matches “\(query)”.").foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commands or keys", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear the search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 240, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                Spacer()
                Button("Restore Defaults") {
                    KeyBindings.resetAll()
                    revision += 1
                }
                .help("Back to Lightroom's keys for every command")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onDisappear(perform: stopRecording)
    }

    @ViewBuilder private func rows(_ actions: [KeyAction]) -> some View {
        ForEach(actions) { action in
            KeyCommandRow(action: action, isRecording: recording == action, isHighlighted: highlighted == action,
                          revision: revision,
                          record: { startRecording(action) },
                          reset: {
                              KeyBindings.set(action.defaultKey, for: action)
                              revision += 1
                          })
                .id(action)
        }
    }

    private func matches(_ action: KeyAction) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return action.title.localizedCaseInsensitiveContains(text)
            || action.section.localizedCaseInsensitiveContains(text)
            || KeyBindings.display(KeyBindings.key(for: action)).caseInsensitiveCompare(text) == .orderedSame
    }

    private func startRecording(_ action: KeyAction) {
        stopRecording()
        recording = action
        highlighted = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // NSEvent isn't Sendable, so the main-actor part says only whether to keep it.
            let keep = MainActor.assumeIsolated { () -> Bool in
                guard let action = recording else { return true }
                switch event.keyCode {
                case 53:  // Escape cancels
                    break
                case 51, 117:  // Delete removes the key
                    KeyBindings.set("", for: action)
                default:
                    guard let combo = KeyBindings.combo(from: event) else {
                        NSSound.beep()
                        return false
                    }
                    KeyBindings.set(combo.stored, for: action)
                }
                stopRecording()
                revision += 1
                return false
            }
            return keep ? event : nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

/// One command: its glyph and name on the left, its key as key caps on the right.
private struct KeyCommandRow: View {
    let action: KeyAction
    let isRecording: Bool
    let isHighlighted: Bool
    /// Changes after every key change, so the row re-reads its key.
    let revision: Int
    let record: () -> Void
    let reset: () -> Void

    var body: some View {
        let stored = KeyBindings.key(for: action)
        LabeledContent {
            HStack(spacing: 6) {
                if stored != action.defaultKey {
                    Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(SidebarIconButtonStyle())
                        .help("Back to \(KeyBindings.display(action.defaultKey))")
                }
                Button(action: record) {
                    if isRecording {
                        KeyCap(text: "Press a key…", recording: true)
                    } else if let combo = KeyCombo(stored: stored) {
                        KeyComboCaps(combo: combo)
                    } else {
                        KeyCap(text: "None", dimmed: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Click, then press the new key, with ⌃, ⌥ or ⇧ if you like. Esc cancels, Delete removes it.")
            }
        } label: {
            HStack(spacing: 10) {
                KeyActionGlyph(action: action, size: 14)
                    .frame(width: 44)
                Text(action.title)
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : 0))
            .padding(.horizontal, -6))
    }
}

/// A combo as separate key caps: ⌃ ⇧ Tab.
struct KeyComboCaps: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                KeyCap(text: part)
            }
        }
    }

    private var parts: [String] {
        var result: [String] = []
        if combo.modifiers.contains(.control) { result.append("⌃") }
        if combo.modifiers.contains(.option) { result.append("⌥") }
        if combo.modifiers.contains(.shift) { result.append("⇧") }
        result.append(KeyCombo(combo.key).display)
        return result
    }
}

/// One key cap: a raised, rounded key like the ones on a Mac keyboard.
struct KeyCap: View {
    let text: String
    var recording = false
    var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: recording ? 1.5 : 1))
            .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 1)
    }
}

/// The keyboard drawn as key caps, each showing the command it runs in the chosen layer
/// (no modifier, ⇧, ⌃ or ⌥). Hover a key for its command; click it to find the command.
private struct KeyboardMap: View {
    @Binding var layer: KeyCombo.Modifiers
    let highlighted: KeyAction?
    let revision: Int
    let select: (KeyAction) -> Void

    static let keySize: CGFloat = 38
    static let gap: CGFloat = 4

    /// A US layout's character keys, with each row's indent in key widths.
    private static let rows: [(indent: CGFloat, keys: [String])] = [
        (0, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]),
        (0.5, ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"]),
        (0.75, ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"]),
        (1.25, ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"]),
    ]

    var body: some View {
        let bindings: [(KeyCombo, KeyAction)] = KeyAction.allCases.compactMap { action in
            guard let combo = KeyBindings.combo(for: action) else { return nil }
            return (combo, action)
        }
        VStack(alignment: .leading, spacing: 10) {
            Picker("Show keys used with", selection: $layer) {
                Text("No modifier").tag(KeyCombo.Modifiers())
                Text("⇧ Shift").tag(KeyCombo.Modifiers.shift)
                Text("⌃ Control").tag(KeyCombo.Modifiers.control)
                Text("⌥ Option").tag(KeyCombo.Modifiers.option)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Self.gap) {
                        ForEach(row.keys, id: \.self) { key in
                            mapKey(key, bindings: bindings)
                        }
                    }
                    .padding(.leading, row.indent * (Self.keySize + Self.gap))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .id(revision)
    }

    private func mapKey(_ key: String, bindings: [(KeyCombo, KeyAction)]) -> MapKey {
        let combo = KeyCombo(key, modifiers: layer)
        let bound: KeyAction? = bindings.first(where: { $0.0 == combo })?.1
        let isHighlighted = bound != nil && bound == highlighted
        return MapKey(key: key, action: bound, isHighlighted: isHighlighted, combo: combo, select: select)
    }
}

private struct MapKey: View {
    let key: String
    let action: KeyAction?
    let isHighlighted: Bool
    let combo: KeyCombo
    let select: (KeyAction) -> Void
    @State private var hovering = false

    // Split into small typed pieces: as one expression it was too much for the type checker.
    var body: some View {
        face
            .padding(4)
            .frame(width: KeyboardMap.keySize, height: KeyboardMap.keySize)
            .background(capShape.fill(fill))
            .overlay(capShape.strokeBorder(border, lineWidth: isHighlighted ? 2 : 1))
            .shadow(color: Color.black.opacity(action == nil ? 0.08 : 0.2), radius: 0, x: 0, y: 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: tapped)
            .help(description)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
    }

    private var face: some View {
        VStack(spacing: 0) {
            Text(KeyCombo(key).display)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            glyph
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var glyph: some View {
        if let action {
            KeyActionGlyph(action: action, size: 13)
        }
    }

    private var capShape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    private var labelColor: Color {
        action == nil ? Color.secondary.opacity(0.6) : Color.secondary
    }

    private var fill: Color {
        guard let action else { return Color.primary.opacity(0.04) }
        return action.tint.opacity(hovering ? 0.26 : 0.15)
    }

    private var border: Color {
        if isHighlighted { return Color.accentColor }
        return Color.primary.opacity(action == nil ? 0.08 : 0.18)
    }

    private var description: String {
        guard let action else { return combo.display + ": not used" }
        return combo.display + ": " + action.title
    }

    private func tapped() {
        if let action { select(action) }
    }
}

/// A small picture of what a command does: stars for ratings, the label's color, a flag, or a symbol.
struct KeyActionGlyph: View {
    let action: KeyAction
    var size: CGFloat = 13

    var body: some View {
        switch action {
        case .rating1, .rating2, .rating3, .rating4, .rating5:
            let stars = Int(String(action.rawValue.last!)) ?? 1
            HStack(spacing: 0) {
                ForEach(0..<stars, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: size * (stars > 3 ? 0.5 : 0.62)))
                }
            }
            .foregroundStyle(action.tint)
        case .labelRed, .labelYellow, .labelGreen, .labelBlue:
            Circle().fill(action.tint).frame(width: size * 0.85, height: size * 0.85)
        default:
            Image(systemName: action.symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(action.tint)
        }
    }
}

extension KeyAction {
    /// The SF Symbol shown for the command on the keyboard map and in the list.
    var symbol: String {
        switch self {
        case .rating0: return "star.slash"
        case .rating1, .rating2, .rating3, .rating4, .rating5: return "star.fill"
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: return "circle.fill"
        case .pick: return "flag.fill"
        case .reject: return "flag.slash.fill"
        case .unflag: return "flag"
        case .grid: return "square.grid.3x3"
        case .loupe: return "rectangle"
        case .develop: return "slider.horizontal.3"
        case .zoom: return "plus.magnifyingglass"
        case .beforeAfter: return "square.split.2x1"
        case .compareMode: return "rectangle.split.2x1"
        case .crop: return "crop"
        case .treatment: return "circle.lefthalf.filled"
        case .whiteBalance: return "eyedropper"
        case .linearGradient: return "rectangle.bottomhalf.filled"
        case .brush: return "paintbrush.pointed"
        case .maskOverlay: return "eye"
        case .clipping: return "exclamationmark.triangle"
        case .masking: return "circle.dashed"
        case .radialGradient: return "circle.circle"
        case .colorRange: return "eyedropper.halffull"
        case .guidedUpright: return "perspective"
        case .remove: return "bandage"
        case .visualizeSpots: return "circle.dotted"
        case .nextArea: return "arrow.right.to.line"
        case .previousArea: return "arrow.left.to.line"
        }
    }

    /// Its color, from the soft Settings palette: the label's own color, amber stars, one color per group.
    var tint: Color {
        switch self {
        case .labelRed: return SettingsPalette.coral
        case .labelYellow: return SettingsPalette.butter
        case .labelGreen: return SettingsPalette.sage
        case .labelBlue: return SettingsPalette.sky
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5: return SettingsPalette.amber
        case .pick, .reject, .unflag: return .primary
        case .grid, .loupe, .develop, .zoom: return SettingsPalette.sky
        case .nextArea, .previousArea: return SettingsPalette.slate
        default: return SettingsPalette.lavender
        }
    }
}
