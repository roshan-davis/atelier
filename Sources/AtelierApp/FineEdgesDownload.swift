import AtelierCore
import SwiftUI

/// The Fine Edges model's download, shared by the mask panel and Settings > AI, so both show the
/// same progress and either can start or remove it.
@MainActor
final class FineEdgesDownload: ObservableObject {
    static let shared = FineEdgesDownload()

    @Published private(set) var installed = FineEdges.isInstalled
    /// 0...1 while downloading, nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    /// Downloads the model; `then` runs once it is in place (the mask panel turns Fine Edges on).
    func download(then: (() -> Void)? = nil) {
        guard task == nil, !installed else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try await FineEdges.install { value in
                    Task { @MainActor in
                        if FineEdgesDownload.shared.progress != nil { FineEdgesDownload.shared.progress = value }
                    }
                }
                installed = FineEdges.isInstalled
                then?()
            } catch {
                // Cancel already cleared the state, and a new download may have started since.
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    func remove() {
        do {
            try FineEdges.remove()
            installed = false
            DeleteFeedback.play(.remove)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The Fine Edges switch under an AI selection's edge sliders: a checkbox once the model is
/// downloaded, otherwise a Get button with its size, then a progress bar.
struct FineEdgesControl: View {
    @Binding var isOn: Bool
    @ObservedObject private var download = FineEdgesDownload.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if download.installed {
                Toggle("Fine Edges", isOn: $isOn)
                    .help("Redraws the edge with the Fine Edges model: single hairs, fur, lace")
                if isOn, let failure = FineEdges.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if let progress = download.progress {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { download.cancel() }.controlSize(.small)
                }
                .help("Downloading the Fine Edges model (\(FineEdges.downloadSize))")
            } else {
                HStack {
                    Text("Fine Edges")
                    Spacer()
                    Button("Get (\(FineEdges.downloadSize))") {
                        let binding = $isOn
                        download.download { binding.wrappedValue = true }
                    }
                    .controlSize(.small)
                }
                .help("Downloads the Fine Edges model (BiRefNet, MIT license) once; it then runs on this Mac")
                if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
