import AtelierCore
import SwiftUI

/// What every optional model download shares (AT-076 R2): which model is downloading, its
/// progress, the last error, Cancel, and Remove with its sound. `DepthModelDownload` and
/// `FineEdgesDownload` add what is their own (installed models, the chosen one, the last run).
/// One download at a time per kind of model.
@MainActor
class ModelDownloadState<Model: Hashable & Sendable>: ObservableObject {
    /// The model being downloaded, and its progress 0...1.
    @Published private(set) var downloading: Model?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    /// Downloads `model` with `install`, which reports progress 0...1, then runs `finished`.
    /// Does nothing while another download runs.
    func startDownload(_ model: Model,
                       install: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void,
                       finished: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        error = nil
        downloading = model
        progress = 0
        task = Task {
            do {
                try await install { [weak self] value in
                    Task { @MainActor in
                        if self?.progress != nil { self?.progress = value }
                    }
                }
                finished()
            } catch {
                // Cancel already cleared the state, and a new download may have started since.
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            downloading = nil
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        downloading = nil
        progress = nil
    }

    /// Runs `delete`, then `finished`, and plays the remove sound; a failure shows as `error`.
    func remove(_ delete: () throws -> Void, finished: () -> Void) {
        do {
            try delete()
            finished()
            DeleteFeedback.play(.remove)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A download's progress bar with its percentage and Cancel, as the panels show it.
struct ModelDownloadProgress: View {
    let progress: Double
    let help: String
    let cancel: () -> Void

    var body: some View {
        HStack {
            ProgressView(value: progress)
            Text("\(Int((progress * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button("Cancel", action: cancel).controlSize(.small)
        }
        .help(help)
    }
}
