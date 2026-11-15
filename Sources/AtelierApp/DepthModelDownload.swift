import AtelierCore
import SwiftUI

/// The depth model's download, shared by the Depth Range settings and Settings > AI, so both
/// show the same progress and either can start or remove it (as `FineEdgesDownload` does for
/// Fine Edges).
@MainActor
final class DepthModelDownload: ObservableObject {
    static let shared = DepthModelDownload()

    @Published private(set) var installed = DepthMap.isInstalled
    /// 0...1 while downloading.
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    /// Why the model last failed to run, from `DepthMap`.
    @Published private(set) var runFailure: String?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: DepthMap.ready, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installed = DepthMap.isInstalled
                self?.runFailure = DepthMap.failure
            }
        }
    }

    func download() {
        guard task == nil, !installed else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try await DepthMap.install { value in
                    Task { @MainActor in
                        if DepthModelDownload.shared.progress != nil { DepthModelDownload.shared.progress = value }
                    }
                }
                installed = DepthMap.isInstalled
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
            try DepthMap.remove()
            installed = DepthMap.isInstalled
            DeleteFeedback.play(.remove)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shows `content` (the Depth Range sliders) once the depth model is downloaded; before that,
/// what Depth Range needs and a Download button, then a progress bar.
struct DepthModelGate<Content: View>: View {
    @ObservedObject private var download = DepthModelDownload.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if download.installed {
                content()
                if let failure = download.runFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if let progress = download.progress {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { download.cancel() }.controlSize(.small)
                }
                .help("Downloading the depth model (\(DepthMap.downloadSize))")
            } else {
                Text("Depth Range finds how far away each part of the photo is with a depth model (\(DepthMap.modelName), Apache 2.0 license). Download it once; it then runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Download Depth Model (\(DepthMap.downloadSize))") { download.download() }
                    .controlSize(.small)
                if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
