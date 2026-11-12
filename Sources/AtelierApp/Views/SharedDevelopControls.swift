import AppKit
import AtelierCore
import QuartzCore
import SwiftUI

@MainActor enum PanelHelp {
    static var hasTopic: (String) -> Bool = { _ in false }
    static var show: ((String) -> Void)?
}

/// A group's name inside a panel. With `reset`, double-clicking it resets the group (as
/// double-clicking a slider's name resets the slider), and while ⌥ is held it reads
/// "Reset Tone" and a click resets, as in Lightroom.
struct GroupHeading: View {
    let title: String
    var reset: (() -> Void)?
    @ObservedObject private var keys = ModifierKeys.shared

    var body: some View {
        if let reset {
            Text(keys.option ? "Reset \(title)" : title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(keys.option ? Color.accentColor : Color.secondary)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reset() }
                .onTapGesture { if NSEvent.modifierFlags.contains(.option) { reset() } }
                .help("Double-click to reset \(title), or ⌥-click")
        } else {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

/// A collapsible Develop panel, with the same header band as the left column's sections.
struct PanelSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @Binding var soloMode: Bool
    var isModified = false
    var reset: (() -> Void)?
    /// The panel's on/off switch, for every panel but Basic. While off, the panel's controls
    /// are dimmed but still work; moving one turns the panel back on.
    var isOn: Binding<Bool>? = nil
    let expandAll: () -> Void
    let collapseAll: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SectionBand(title: title, isExpanded: $isExpanded, isModified: isModified) { hovering in
                // The switch sits last, so it stays in one column whether or not a reset shows.
                HStack(spacing: 4) {
                    if isModified, let reset {
                        Button(action: reset) {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(SidebarIconButtonStyle())
                        .opacity(hovering ? 1 : 0.6)
                        .help("Reset \(title)")
                    }
                    if let isOn {
                        Toggle(title, isOn: isOn)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help(isOn.wrappedValue ? "Turn \(title) off to compare; its settings are kept"
                                                    : "Turn \(title) back on")
                    }
                }
            }
            // A Tab stop, so a closed panel can be opened from the keyboard (Rosh, Nov 9, 2026):
            // Return or Space opens or closes it, → opens, ← closes.
            .modifier(KeyboardControl { press in
                let open: Bool
                switch press.key {
                case .enter, .space: open = !isExpanded
                case .right: open = true
                case .left: open = false
                default: return false
                }
                if open != isExpanded { withAnimation(.easeInOut(duration: 0.18)) { isExpanded = open } }
                return true
            })
            .contextMenu {
                Toggle("Solo Mode", isOn: $soloMode)
                Divider()
                Button("Expand All Panels", action: expandAll)
                Button("Collapse All Panels", action: collapseAll)
                if let show = PanelHelp.show, PanelHelp.hasTopic(title) {
                    Divider()
                    Button("\(title) Help") { show(title) }
                }
            }
            if isExpanded {
                content()
                    // If a panel's controls ever need more width than the column has, they
                    // overflow to the right (the value end) instead of being centered and
                    // cutting off the names on the left.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .opacity(isOn?.wrappedValue == false ? 0.45 : 1)
            }
            Divider()
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Where the track's fill starts, and what a reset goes back to unless `reset` says otherwise.
    var origin: Double = 0
    var gradient: [Color]?
    var logarithmic = false
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var valueWidth: CGFloat = 44
    var labelWidth: CGFloat = 78
    var reset: (() -> Void)?
    var auto: (() -> Void)?
    var trackHelp = ""
    var onOption: ((Bool) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    @State private var editing = false
    @State private var draft = 0.0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if NSEvent.modifierFlags.contains(.shift), let auto {
                        auto()
                    } else if let reset {
                        reset()
                    } else {
                        value = origin
                    }
                }
                .help(auto != nil ? "Double-click to reset; Shift-double-click for Auto" : "Double-click to reset")
            DevelopSlider(value: $value, range: range, step: step, origin: origin, gradient: gradient,
                          logarithmic: logarithmic, name: label, onOption: onOption, onEditingChanged: onEditingChanged)
                .help(trackHelp)
            Group {
                if editing {
                    TextField("Value", value: $draft, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onChange(of: fieldFocused) { if !fieldFocused { commit() } }
                        .onExitCommand { editing = false }
                        .accessibilityIdentifier("develop-slider-field-\(label)")
                } else {
                    Text(format(value))
                        .monospacedDigit()
                        .foregroundStyle(value == origin ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = value
                            editing = true
                            fieldFocused = true
                        }
                        .help("Click to type a value")
                        .accessibilityIdentifier("develop-slider-value-\(label)")
                }
            }
            .frame(width: valueWidth)
        }
        .font(.callout)
        .frame(height: 20)
        // Click, drag or Tab to focus; the arrow keys then move it (⇧ for bigger steps).
        .modifier(KeyboardSlider(value: $value, range: range, step: step, logarithmic: logarithmic))
    }

    private func commit() {
        guard editing else { return }
        value = min(max(draft, range.lowerBound), range.upperBound)
        editing = false
    }
}

/// Atelier's one slider, used for every slider in the app (Develop, Masking, Presets Amount,
/// Export, Cull, Match Look, the grid's thumbnail size and the HDR app): a thin track (colored
/// where Lightroom colors it), a mark at the default, the change from the default filled in,
/// and a 13 pt round knob. The sizes and the press rules are `SliderGeometry`'s: a press within
/// the knob's 20 pt grab zone picks it up where it is, a press elsewhere on the track jumps it
/// there. The pointer is a left-right arrow over the knob and during every drag (Rosh, Nov 10,
/// 2026). Never use SwiftUI's `Slider`; add an option here instead.
struct DevelopSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Where the fill starts: the parameter's default (the low end for a plain slider).
    let origin: Double
    let gradient: [Color]?
    /// Temperature moves in equal steps of perceived warmth rather than Kelvin.
    var logarithmic = false
    /// The slider's name for VoiceOver.
    var name = ""
    /// Told while dragging whether Option is held, and false when the drag ends, for the
    /// slider's Option-drag view.
    var onOption: ((Bool) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    /// Set while dragging: how far the knob sits from the pointer (0 when the press jumped it).
    @State private var grabOffset: Double?
    @Environment(\.developFrameHUD) private var frameHUD
    @Environment(\.takeKeyboardFocus) private var takeKeyboardFocus
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let width = Double(geometry.size.width)
            let midY = Double(geometry.size.height) / 2
            let knob = SliderGeometry.x(fraction: SliderGeometry.fraction(of: value, in: range, logarithmic: logarithmic),
                                        width: width)
            let start = SliderGeometry.x(fraction: SliderGeometry.fraction(of: origin, in: range, logarithmic: logarithmic),
                                         width: width)
            let inset = SliderGeometry.trackInset, length = SliderGeometry.trackLength(width: width)
            let track = SliderGeometry.trackHeight
            ZStack(alignment: .topLeading) {
                Group {
                    if let gradient {
                        Capsule().fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Color.secondary.opacity(0.28))
                    }
                }
                .frame(width: length, height: track)
                .offset(x: inset, y: midY - track / 2)
                if gradient == nil {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: abs(knob - start), height: track)
                        .offset(x: min(knob, start), y: midY - track / 2)
                }
                if start > inset + 1, start < width - inset - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1, height: 7)
                        .offset(x: start - 0.5, y: midY - 3.5)
                }
                SliderKnob()
                    .offset(x: knob - SliderGeometry.knobDiameter / 2, y: midY - SliderGeometry.knobDiameter / 2)
            }
            // The ZStack is only as big as its widest and tallest child (the inset track and the
            // knob), so without this frame the right end and the bottom of the slider took no
            // clicks and no cursor: a knob at the maximum could only be caught on its left half.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let hud = frameHUD?.active == true ? frameHUD : nil
                    let began = hud == nil ? 0 : CACurrentMediaTime()
                    var changed = false
                    if grabOffset == nil { hud?.begin(name, value: value) }
                    defer { hud?.recordTick(from: began, changed: changed) }
                    let offset: Double
                    if let held = grabOffset {
                        offset = held
                    } else {
                        offset = SliderGeometry.grabOffset(start: Double(drag.startLocation.x), knobX: knob)
                        grabOffset = offset
                        takeKeyboardFocus?()
                        onEditingChanged?(true)
                    }
                    onOption?(NSEvent.modifierFlags.contains(.option))
                    guard length > 0 else { return }
                    let newValue = SliderGeometry.value(at: SliderGeometry.fraction(x: Double(drag.location.x) + offset, width: width),
                                                        in: range, step: step, logarithmic: logarithmic)
                    if newValue != value {
                        changed = true
                        value = newValue
                    }
                }
                .onEnded { _ in
                    frameHUD?.end(name)
                    onOption?(false); grabOffset = nil; onEditingChanged?(false)
                })
            // Same hit test as the press: left-right arrow over the knob, and through any drag.
            .cursor(whileDragging: .slide) { point in
                isEnabled && SliderGeometry.isOnKnob(Double(point.x), knobX: knob) ? .slide : .arrow
            }
        }
        .frame(height: SliderGeometry.height)
        .opacity(isEnabled ? 1 : 0.5)
        .onReceive(ModifierKeys.shared.$option) { held in
            if grabOffset != nil { onOption?(held) }
        }
        .onDisappear {
            if grabOffset != nil {
                frameHUD?.end(name)
                onOption?(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(Text(value.formatted(.number.precision(.fractionLength(0...2)))))
        .accessibilityAdjustableAction { direction in
            let sign: Int
            switch direction {
            case .increment: sign = 1
            case .decrement: sign = -1
            @unknown default: return
            }
            value = SliderNudge.value(from: value, range: range, step: step, logarithmic: logarithmic,
                                      direction: sign, large: false)
        }
    }
}

/// Every slider's knob (`DevelopSlider`, both ends of `HueRangeSlider`).
struct SliderKnob: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .frame(width: SliderGeometry.knobDiameter, height: SliderGeometry.knobDiameter)
    }
}
