import AppKit
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
                          logarithmic: logarithmic, onOption: onOption, onEditingChanged: onEditingChanged)
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
                }
            }
            .frame(width: valueWidth)
        }
        .font(.callout)
        .frame(height: 20)
    }

    private func commit() {
        guard editing else { return }
        value = min(max(draft, range.lowerBound), range.upperBound)
        editing = false
    }
}

/// A slim Lightroom-style slider: thin track (colored where Lightroom colors it), a mark at the
/// default, the change from the default filled in, and a small round knob.
struct DevelopSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Where the fill starts: the parameter's default.
    let origin: Double
    let gradient: [Color]?
    /// Temperature moves in equal steps of perceived warmth rather than Kelvin.
    var logarithmic = false
    /// Told while dragging whether Option is held, and false when the drag ends, for the
    /// slider's Option-drag view.
    var onOption: ((Bool) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    @State private var isDragging = false

    private func fraction(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        if logarithmic {
            return (log(clamped) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound))
        }
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(at fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        let raw = logarithmic
            ? exp(log(range.lowerBound) + f * (log(range.upperBound) - log(range.lowerBound)))
            : range.lowerBound + f * (range.upperBound - range.lowerBound)
        return (raw / step).rounded() * step
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let midY = geometry.size.height / 2
            let knob = fraction(value) * width
            let start = fraction(origin) * width
            ZStack(alignment: .topLeading) {
                Group {
                    if let gradient {
                        Capsule().fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Color.secondary.opacity(0.28))
                    }
                }
                .frame(width: width, height: 3)
                .offset(y: midY - 1.5)
                if gradient == nil {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: abs(knob - start), height: 3)
                        .offset(x: min(knob, start), y: midY - 1.5)
                }
                if start > 1, start < width - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1, height: 7)
                        .offset(x: start - 0.5, y: midY - 3.5)
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 11, height: 11)
                    .offset(x: knob - 5.5, y: midY - 5.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    #if !ATELIER_HDR_APP
                    DevelopTrace.input("slider", eventTime: drag.time)
                    #endif
                    if !isDragging { isDragging = true; onEditingChanged?(true) }
                    onOption?(NSEvent.modifierFlags.contains(.option))
                    guard width > 0 else { return }
                    let newValue = value(at: Double(drag.location.x / width))
                    if newValue != value { value = newValue }
                }
                .onEnded { _ in
                    onOption?(false); isDragging = false; onEditingChanged?(false)
                })
        }
        .frame(height: 16)
    }
}
