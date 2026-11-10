import SwiftUI

/// Redraws its content when the open photo's histogram or color scope changes, and nothing else
/// (AT-039 D2). The counts arrive with every render during a drag; on `DevelopController`
/// itself each one updated every view that watches the controller, which is the whole Develop
/// window. Wrap only what draws them: the histogram, the curve backdrops and the wheels' scope.
struct MeasuresReader<Content: View>: View {
    @ObservedObject var measures: DevelopMeasures
    @ViewBuilder let content: (DevelopMeasures) -> Content

    init(_ measures: DevelopMeasures, @ViewBuilder content: @escaping (DevelopMeasures) -> Content) {
        self.measures = measures
        self.content = content
    }

    var body: some View { content(measures) }
}
