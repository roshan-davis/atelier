import AppKit
import AtelierCore
import Combine
import SwiftUI

/// The window's areas, in ⌃Tab order: left to right.
enum KeyboardFocusArea: Int, CaseIterable {
    case leftPanel, photo, rightPanel
}

/// Keyboard focus in Develop, shared by every control that takes keys (sliders, the Presets
/// list) and the window's key handler in `LibraryModel`.
///
/// A control with focus takes the arrow keys, Return and Esc; with none (the photo has focus),
/// ← and → move between photos. Tab and ⇧Tab move between controls in SwiftUI's own order;
/// ⌃Tab and ⌃⇧Tab (changeable in Settings > Keyboard) move between the areas.
@MainActor
final class KeyboardFocus {
    static let shared = KeyboardFocus()

    struct Target: Hashable {
        let area: KeyboardFocusArea
        let id: String
    }

    /// A request for one control to take focus, or, with no target, for every control to let go.
    struct Request {
        let target: Target?
    }

    /// The control with focus; nil while the photo has it.
    private(set) var current: Target?
    /// Controls listen for requests rather than observing an object, so a request never
    /// redraws every slider.
    let requests = PassthroughSubject<Request, Never>()
    /// The controls on screen in each area, roughly in the order they appeared.
    private var registered: [KeyboardFocusArea: [String]] = [:]
    /// The control last focused in each area, to come back to on ⌃Tab.
    private var lastInArea: [KeyboardFocusArea: String] = [:]

    func register(_ target: Target) {
        if !registered[target.area, default: []].contains(target.id) {
            registered[target.area, default: []].append(target.id)
        }
    }

    func unregister(_ target: Target) {
        registered[target.area]?.removeAll { $0 == target.id }
        didBlur(target)
    }

    func didFocus(_ target: Target) {
        current = target
        lastInArea[target.area] = target.id
    }

    func didBlur(_ target: Target) {
        if current == target { current = nil }
    }

    /// Gives the arrow keys back to the photo: Esc, a click on the photo, or ⌃Tab to the photo.
    func release() {
        current = nil
        requests.send(Request(target: nil))
    }

    /// Focuses the control last used in an area, or its first one.
    func focus(_ area: KeyboardFocusArea) {
        guard area != .photo, let ids = registered[area], let first = ids.first else {
            release()
            return
        }
        let id = lastInArea[area].flatMap { ids.contains($0) ? $0 : nil } ?? first
        requests.send(Request(target: Target(area: area, id: id)))
    }

    /// The area ⌃Tab just moved to, for its brief outline (`AreaFocusFlash`).
    let arrivals = PassthroughSubject<KeyboardFocusArea, Never>()

    /// ⌃Tab and ⌃⇧Tab: the next area with something to focus, wrapping around.
    func cycle(forward: Bool) {
        let areas = KeyboardFocusArea.allCases
        var index = areas.firstIndex(of: current?.area ?? .photo) ?? 1
        for _ in areas.indices {
            index = (index + (forward ? 1 : areas.count - 1)) % areas.count
            let area = areas[index]
            if area == .photo || !(registered[area] ?? []).isEmpty {
                focus(area)
                arrivals.send(area)
                return
            }
        }
    }
}

private struct KeyboardFocusAreaKey: EnvironmentKey {
    static let defaultValue = KeyboardFocusArea.rightPanel
}

private struct TakeKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct SidebarScrollKey: EnvironmentKey {
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

    /// The left column's scroll view, so the Presets list can keep its keyboard row in view.
    var sidebarScroll: ScrollViewProxy? {
        get { self[SidebarScrollKey.self] }
        set { self[SidebarScrollKey.self] = newValue }
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

/// Makes a slider row take keyboard focus (click, drag or Tab) and the arrow keys: each press
/// moves 1/200 of the track, ⇧ five times that. Esc lets go and gives the arrows back to the
/// photo. Every Develop slider gets it through `SliderRow`.
struct KeyboardSlider: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var logarithmic = false

    @FocusState private var focused: Bool
    @State private var id = UUID().uuidString
    @Environment(\.keyboardFocusArea) private var area

    private var target: KeyboardFocus.Target { KeyboardFocus.Target(area: area, id: id) }

    func body(content: Content) -> some View {
        content
            .environment(\.takeKeyboardFocus, { focused = true })
            .keyboardFocusHighlight(focused)
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let up = press.key == .rightArrow || press.key == .upArrow
                value = SliderNudge.value(from: value, range: range, step: step, logarithmic: logarithmic,
                                          direction: up ? 1 : -1, large: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.escape) {
                focused = false
                KeyboardFocus.shared.release()
                return .handled
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    KeyboardFocus.shared.didFocus(target)
                } else {
                    KeyboardFocus.shared.didBlur(target)
                }
            }
            .onAppear { KeyboardFocus.shared.register(target) }
            .onDisappear { KeyboardFocus.shared.unregister(target) }
            .onReceive(KeyboardFocus.shared.requests) { request in
                if let wanted = request.target {
                    if wanted == target { focused = true }
                } else if focused {
                    focused = false
                }
            }
    }
}

/// A thin accent outline around an area that ⌃Tab just moved to, fading out after about half
/// a second, so you can see where focus went (Rosh, Nov 9, 2026). With Reduce Motion it shows
/// and hides without fading.
struct AreaFocusFlash: ViewModifier {
    let area: KeyboardFocusArea
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onReceive(KeyboardFocus.shared.arrivals) { arrived in
                hideTask?.cancel()
                guard arrived == area else {
                    visible = false
                    return
                }
                visible = true
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 600 : 250))
                    guard !Task.isCancelled else { return }
                    if reduceMotion {
                        visible = false
                    } else {
                        withAnimation(.easeOut(duration: 0.4)) { visible = false }
                    }
                }
            }
            .onDisappear { hideTask?.cancel() }
    }
}

extension View {
    /// Outlines this area briefly when ⌃Tab moves focus to it.
    func areaFocusFlash(_ area: KeyboardFocusArea) -> some View {
        modifier(AreaFocusFlash(area: area))
    }
}
