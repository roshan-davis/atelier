import AppKit
import AtelierCore
import Combine
import SwiftUI

/// The window's areas, in ⌃Tab order: the left column, the right panels, then the photos.
/// `photo` is where ← → move between photos; it is outlined on the Filmstrip when the
/// Filmstrip is showing (that's where the arrows visibly act), else on the photo.
enum KeyboardFocusArea: Int, CaseIterable {
    case leftPanel, rightPanel, photo
}

/// Keyboard focus in Develop, shared by every control that takes keys (sliders, the Presets
/// list) and the window's key handler in `LibraryModel`, which routes keys here.
///
/// Focus is kept here, not in SwiftUI's focus system: SwiftUI only moves focus while its
/// hosting view is the window's first responder, which the photo view takes on a click, so a
/// slider "focused" from ⌃Tab could show its mark while ← → still changed photo (Rosh's test,
/// Nov 9, 2026). Here the window's key handler asks this object first, so what shows the mark
/// is always what gets the keys.
///
/// A control with focus takes the arrow keys, Return, Space and Esc; Tab and ⇧Tab move to the
/// next or previous control in the same area, top to bottom. With none (the photos have focus),
/// ← and → move between photos. ⌃Tab and ⌃⇧Tab (changeable in Settings > Keyboard) move
/// between the areas.
@MainActor
final class KeyboardFocus {
    static let shared = KeyboardFocus()

    struct Target: Hashable {
        let area: KeyboardFocusArea
        let id: String
    }

    /// A key a focused control can take.
    enum Key {
        case left, right, up, down, enter, space, escape
    }

    struct Press {
        let key: Key
        let shift: Bool
    }

    private struct Entry {
        var handler: (Press) -> Bool
        /// Where the control is on screen, for Tab order and the first control of an area.
        var minY: CGFloat
    }

    private var entries: [Target: Entry] = [:]
    /// The control with focus; nil while the photos have it.
    private(set) var current: Target?
    /// The area ⌃Tab counts from: where it last moved to, or the focused control's area.
    private(set) var activeArea: KeyboardFocusArea = .photo
    /// The control last focused in each area, to come back to on ⌃Tab.
    private var lastInArea: [KeyboardFocusArea: String] = [:]
    /// Tells controls which one has focus now, so each shows or hides its mark. A subject rather
    /// than a published value, so a change never redraws every slider.
    let changes = PassthroughSubject<Target?, Never>()
    /// The area ⌃Tab just moved to, for its brief ring (`AreaFocusFlash`).
    let arrivals = PassthroughSubject<KeyboardFocusArea, Never>()

    func register(_ target: Target, handler: @escaping (Press) -> Bool) {
        entries[target] = Entry(handler: handler, minY: entries[target]?.minY ?? .greatestFiniteMagnitude)
    }

    func unregister(_ target: Target) {
        entries.removeValue(forKey: target)
        if current == target {
            current = nil
            changes.send(nil)
        }
    }

    func setPosition(_ target: Target, minY: CGFloat) {
        entries[target]?.minY = minY
    }

    /// Gives a control focus: a click or drag on it, Tab, or ⌃Tab.
    func focus(_ target: Target) {
        guard entries[target] != nil else { return }
        current = target
        activeArea = target.area
        lastInArea[target.area] = target.id
        changes.send(target)
    }

    /// Gives the arrow keys back to the photos: Esc, a click on the photo, or ⌃Tab to the photos.
    func release() {
        current = nil
        activeArea = .photo
        changes.send(nil)
    }

    /// An area's controls, top to bottom.
    private func targets(in area: KeyboardFocusArea) -> [Target] {
        entries.filter { $0.key.area == area }
            .sorted { $0.value.minY < $1.value.minY }
            .map(\.key)
    }

    /// Focuses the control last used in an area, or its top one.
    func focus(_ area: KeyboardFocusArea) {
        let candidates = targets(in: area)
        guard area != .photo, let first = candidates.first else {
            release()
            return
        }
        let last = lastInArea[area].map { Target(area: area, id: $0) }
        focus(last.flatMap { candidates.contains($0) ? $0 : nil } ?? first)
    }

    /// ⌃Tab and ⌃⇧Tab: the next area with something to focus, wrapping around. Every press
    /// moves on, so holding ⌃ and tapping Tab walks the areas in turn.
    func cycle(forward: Bool) {
        let areas = KeyboardFocusArea.allCases
        var index = areas.firstIndex(of: current?.area ?? activeArea) ?? areas.count - 1
        for _ in areas.indices {
            index = (index + (forward ? 1 : areas.count - 1)) % areas.count
            let area = areas[index]
            if area == .photo || !targets(in: area).isEmpty {
                focus(area)
                arrivals.send(area)
                return
            }
        }
    }

    /// Tab and ⇧Tab: the next or previous control in the focused control's area, wrapping
    /// around. False when nothing has focus.
    func step(forward: Bool) -> Bool {
        guard let current else { return false }
        let ordered = targets(in: current.area)
        guard let index = ordered.firstIndex(of: current), ordered.count > 1 else { return true }
        focus(ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count])
        return true
    }

    /// Hands a key to the focused control. Esc always lets go afterwards.
    func handle(_ press: Press) -> Bool {
        guard let current, let entry = entries[current] else { return false }
        let handled = entry.handler(press)
        if press.key == .escape {
            release()
            return true
        }
        return handled
    }
}

private struct KeyboardFocusAreaKey: EnvironmentKey {
    static let defaultValue = KeyboardFocusArea.rightPanel
}

private struct TakeKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct KeyboardScrollKey: EnvironmentKey {
    static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    /// Which area the controls below belong to, for ⌃Tab. Sliders default to the right panel.
    var keyboardFocusArea: KeyboardFocusArea {
        get { self[KeyboardFocusAreaKey.self] }
        set { self[KeyboardFocusAreaKey.self] = newValue }
    }

    /// Set by a keyboard-focusable row so a control inside it (a slider's track) can take
    /// focus when it is clicked or dragged.
    var takeKeyboardFocus: (() -> Void)? {
        get { self[TakeKeyboardFocusKey.self] }
        set { self[TakeKeyboardFocusKey.self] = newValue }
    }

    /// The column's scroll view, so a control (or the Presets list's row) that gets keyboard
    /// focus can scroll itself into view.
    var keyboardScroll: ScrollViewProxy? {
        get { self[KeyboardScrollKey.self] }
        set { self[KeyboardScrollKey.self] = newValue }
    }
}

/// The quiet focus mark every keyboard-focusable control uses instead of the system's thick
/// ring: a faint tint and a thin accent bar at the leading edge, faded in over 0.15 s
/// (shown at once with Reduce Motion).
struct KeyboardFocusHighlight: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fade: Animation? { reduceMotion ? nil : .easeOut(duration: 0.15) }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isOn ? 0.1 : 0))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
                    .animation(fade, value: isOn)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 2)
                    .offset(x: -7)
                    .opacity(isOn ? 1 : 0)
                    .animation(fade, value: isOn)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func keyboardFocusHighlight(_ isOn: Bool) -> some View {
        modifier(KeyboardFocusHighlight(isOn: isOn))
    }
}

/// Makes a slider row take keyboard focus (click, drag, Tab or ⌃Tab) and the arrow keys: each
/// press moves 1/200 of the track, ⇧ five times that. Esc lets go and gives the arrows back to
/// the photos. Every Develop slider gets it through `SliderRow`.
struct KeyboardSlider: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var logarithmic = false

    /// The latest binding and range, read by the key handler (registered once) on each press.
    private final class Config {
        var value: Binding<Double>?
        var range: ClosedRange<Double> = 0...1
        var step = 1.0
        var logarithmic = false
    }

    @State private var id = UUID().uuidString
    @State private var config = Config()
    @State private var focused = false
    @Environment(\.keyboardFocusArea) private var area
    @Environment(\.keyboardScroll) private var scroll

    private var target: KeyboardFocus.Target { KeyboardFocus.Target(area: area, id: id) }

    func body(content: Content) -> some View {
        // Not state: the handler reads these when a key comes, never during a redraw.
        config.value = $value
        config.range = range
        config.step = step
        config.logarithmic = logarithmic
        let target = self.target
        let config = self.config
        return content
            .environment(\.takeKeyboardFocus, { KeyboardFocus.shared.focus(target) })
            .keyboardFocusHighlight(focused)
            .id(target.id)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { minY in
                KeyboardFocus.shared.setPosition(target, minY: minY)
            }
            .onAppear {
                KeyboardFocus.shared.register(target) { press in
                    guard let binding = config.value else { return false }
                    let direction: Int
                    switch press.key {
                    case .right, .up: direction = 1
                    case .left, .down: direction = -1
                    default: return false
                    }
                    binding.wrappedValue = SliderNudge.value(from: binding.wrappedValue, range: config.range,
                                                             step: config.step, logarithmic: config.logarithmic,
                                                             direction: direction, large: press.shift)
                    return true
                }
                focused = KeyboardFocus.shared.current == target
            }
            .onDisappear { KeyboardFocus.shared.unregister(target) }
            .onReceive(KeyboardFocus.shared.changes) { now in
                let isMe = now == target
                if isMe != focused { focused = isMe }
                if isMe { scroll?.scrollTo(target.id, anchor: nil) }
            }
    }
}

/// An accent ring with a soft glow around the area ⌃Tab just moved to: it eases in (settling
/// from slightly larger), holds about 0.65 s and fades out, so you can see where focus went
/// (Rosh, Nov 9, 2026). With Reduce Motion it shows and hides without moving or fading.
struct AreaFocusFlash: ViewModifier {
    let area: KeyboardFocusArea
    var enabled = true
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                // An accent ring with a soft inner glow and a faint wash: clear at a glance,
                // gone in under a second.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 7)
                            .blur(radius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    )
                    .padding(2)
                    .scaleEffect(visible || reduceMotion ? 1 : 1.015)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onReceive(KeyboardFocus.shared.arrivals) { arrived in
                hideTask?.cancel()
                guard enabled, arrived == area else {
                    visible = false
                    return
                }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { visible = true }
                }
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 800 : 650))
                    guard !Task.isCancelled else { return }
                    if reduceMotion {
                        visible = false
                    } else {
                        withAnimation(.easeInOut(duration: 0.5)) { visible = false }
                    }
                }
            }
            .onDisappear { hideTask?.cancel() }
    }
}

extension View {
    /// Outlines this area briefly when ⌃Tab moves focus to it.
    func areaFocusFlash(_ area: KeyboardFocusArea, enabled: Bool = true) -> some View {
        modifier(AreaFocusFlash(area: area, enabled: enabled))
    }
}
