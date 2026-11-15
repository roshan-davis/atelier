import AtelierCore
import SwiftUI

/// The line under Detail > Noise Reduction > AI Denoise: a spinner while the photo's noise is
/// being found, then how long it took, or why it didn't run (AT-067).
struct AIDenoiseStatus: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        if let text = develop.aiDenoiseStatus {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if develop.isAIDenoising { ProgressView().controlSize(.mini) }
                Text(text)
                    .foregroundStyle(text.hasPrefix("AI Denoise didn't run") ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }
}
