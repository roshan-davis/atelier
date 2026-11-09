import AppKit
import SwiftUI

/// A segmented control of icons (or short text) with a tooltip on each segment, for the bars
/// under the photo: Before and After, and Fit / Fill / 100% / 200%. SwiftUI's segmented Picker
/// can't show a tooltip per segment, and an icon without one is a guess.
struct IconSegmentedControl<Value: Hashable>: NSViewRepresentable {
    struct Segment {
        let value: Value
        /// An SF Symbol; when nil, `text` is shown instead.
        var symbol: String?
        var text: String?
        /// The tooltip, which is also the icon's VoiceOver name.
        let help: String
    }

    let segments: [Segment]
    /// A value that matches no segment (a free zoom level) leaves every segment unselected.
    @Binding var selection: Value

    func makeCoordinator() -> IconSegmentedCoordinator { IconSegmentedCoordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(IconSegmentedCoordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let segments = self.segments
        let selection = $selection
        context.coordinator.select = { index in
            guard segments.indices.contains(index), selection.wrappedValue != segments[index].value else { return }
            selection.wrappedValue = segments[index].value
        }
        if control.segmentCount != segments.count { control.segmentCount = segments.count }
        for (index, segment) in segments.enumerated() {
            if let symbol = segment.symbol {
                control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: segment.help), forSegment: index)
                control.setLabel("", forSegment: index)
            } else {
                control.setImage(nil, forSegment: index)
                control.setLabel(segment.text ?? "", forSegment: index)
            }
            control.setToolTip(segment.help, forSegment: index)
        }
        control.selectedSegment = segments.firstIndex { $0.value == self.selection } ?? -1
        control.isEnabled = context.environment.isEnabled
        control.controlSize = Self.controlSize(context.environment.controlSize)
    }

    private static func controlSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: return .mini
        case .small: return .small
        case .large: return .large
        case .extraLarge: return .extraLarge
        default: return .regular
        }
    }
}

/// Kept outside the generic control so its action method is a plain Objective-C selector.
final class IconSegmentedCoordinator: NSObject {
    var select: ((Int) -> Void)?

    @objc func changed(_ sender: NSSegmentedControl) {
        select?(sender.selectedSegment)
    }
}
