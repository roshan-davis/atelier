import SwiftUI

/// The divider between two side-by-side panes; drag it to resize the one on `panel`'s side.
/// Use it instead of `HSplitView`, which lays its panes out at their ideal width and clips
/// them when the window is narrower.
struct PanelResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// The side of the handle the resized panel is on.
    var panel: HorizontalEdge
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? width
                            startWidth = start
                            let delta = panel == .leading ? value.translation.width : -value.translation.width
                            width = min(range.upperBound, max(range.lowerBound, start + delta))
                        }
                        .onEnded { _ in startWidth = nil })
                    .cursor(.columnResize)
            )
            .help("Drag to resize the panel")
    }
}
