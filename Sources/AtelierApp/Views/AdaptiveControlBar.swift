import SwiftUI

/// Keeps one interactive layout mounted. Measure the alternatives once per sizing key,
/// then use the width offered to the bar itself to select a layout.
struct AdaptiveControlBar<SizingKey: Hashable, Wide: View, Compact: View, Minimum: View>: View {
    let sizingKey: SizingKey
    @ViewBuilder let wide: () -> Wide
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let minimum: () -> Minimum

    @State private var availableWidth: CGFloat = 0
    @State private var wideMeasurement: Measurement?
    @State private var compactMeasurement: Measurement?

    private struct Measurement: Equatable {
        let key: SizingKey
        let width: CGFloat
    }

    var body: some View {
        Group {
            if let wideMeasurement, wideMeasurement.key == sizingKey, availableWidth >= wideMeasurement.width {
                wide()
            } else if let compactMeasurement, compactMeasurement.key == sizingKey, availableWidth >= compactMeasurement.width {
                compact()
            } else {
                minimum()
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
        .overlay(alignment: .topLeading) {
            if wideMeasurement?.key != sizingKey {
                measurement(wide(), result: $wideMeasurement)
            }
        }
        .overlay(alignment: .topLeading) {
            if compactMeasurement?.key != sizingKey {
                measurement(compact(), result: $compactMeasurement)
            }
        }
    }

    private func measurement<Content: View>(_ content: Content, result: Binding<Measurement?>) -> some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                if width > 0 { result.wrappedValue = Measurement(key: sizingKey, width: width.rounded(.up)) }
            }
            .id(sizingKey)
    }

}
