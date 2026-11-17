import AtelierCore
import SwiftUI

/// The depth model's download, shared by the Depth Range settings and Settings > AI, so both
/// show the same progress and either can start or remove it. The download itself is
/// `ModelDownloadState`'s, as Fine Edges' is.
final class DepthModelDownload: ModelDownloadState<DepthModel> {
    /// The one shared download; don't make another.
    static let shared = DepthModelDownload()

    @Published private(set) var installed = DepthMap.isInstalled
    /// Why the model last failed to run, from `DepthMap`.
    @Published private(set) var runFailure: String?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: DepthMap.ready, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installed = DepthMap.isInstalled
                self?.runFailure = DepthMap.failure
            }
        }
    }

    func download() {
        guard !installed else { return }
        startDownload(.depthAnythingV2Small, install: { try await DepthMap.install(progress: $0) },
                      finished: { [weak self] in self?.installed = DepthMap.isInstalled })
    }

    func remove() {
        remove({ try DepthMap.remove() }, finished: { installed = DepthMap.isInstalled })
    }
}

/// The depth models Atelier can download: one today.
enum DepthModel: Hashable, Sendable { case depthAnythingV2Small }

/// Shows `content` (the Depth Range, Select Sky or Lens Blur controls) once the depth model is
/// downloaded; before that, what it needs and a Download button, then a progress bar.
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
                ModelDownloadProgress(progress: progress, help: "Downloading the depth model (\(DepthMap.downloadSize))",
                                      cancel: download.cancel)
            } else {
                Text("Depth Range, Select Sky and Lens Blur find how far away each part of the photo is with a depth model (\(DepthMap.modelName), Apache 2.0 license). Download it once; it then runs on this Mac.")
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
