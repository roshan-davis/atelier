import AtelierCore
import SwiftUI

/// The Fine Edges models' downloads and which one runs, shared by the mask panel and
/// Settings > AI, so both show the same progress and either can start, remove or pick one.
@MainActor
final class FineEdgesDownload: ObservableObject {
    static let shared = FineEdgesDownload()

    @Published private(set) var installed: Set<FineEdges.Model> = []
    /// The model that runs when both are downloaded.
    @Published private(set) var chosen = FineEdges.chosen
    /// The model being downloaded (one at a time), and its progress 0...1.
    @Published private(set) var downloading: FineEdges.Model?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    /// The last run's result (model, time, foreground share) or why it failed, from `FineEdges`.
    @Published private(set) var lastRun: String?
    @Published private(set) var runFailure: String?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    /// Whether either model is downloaded.
    var anyInstalled: Bool { !installed.isEmpty }
    /// The model Fine Edges runs (see `FineEdges.active`).
    var active: FineEdges.Model? { installed.contains(chosen) ? chosen : FineEdges.Model.allCases.first { installed.contains($0) } }

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: FineEdges.statusChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastRun = FineEdges.lastRun
                self?.runFailure = FineEdges.failure
                self?.chosen = FineEdges.chosen
            }
        }
    }

    private func refresh() {
        installed = Set(FineEdges.Model.allCases.filter(\.isInstalled))
        chosen = FineEdges.chosen
    }

    /// Picks the model that runs when both are downloaded.
    func choose(_ model: FineEdges.Model) {
        FineEdges.chosen = model
        chosen = model
    }

    /// Downloads `model` and picks it; `then` runs once it is in place (the mask panel turns Fine
    /// Edges on).
    func download(_ model: FineEdges.Model, then: (() -> Void)? = nil) {
        guard task == nil, !installed.contains(model) else { return }
        error = nil
        downloading = model
        progress = 0
        task = Task {
            do {
                try await FineEdges.install(model) { value in
                    Task { @MainActor in
                        if FineEdgesDownload.shared.progress != nil { FineEdgesDownload.shared.progress = value }
                    }
                }
                refresh()
                then?()
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

    func remove(_ model: FineEdges.Model) {
        do {
            try FineEdges.remove(model)
            refresh()
            DeleteFeedback.play(.remove)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The Fine Edges switch under an AI selection's edge sliders: a checkbox once a model is
/// downloaded (with a Fast / Hair Detail choice when both are), otherwise a Get menu with each
/// model's size, then a progress bar.
struct FineEdgesControl: View {
    @Binding var isOn: Bool
    @ObservedObject private var download = FineEdgesDownload.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if download.anyInstalled {
                HStack {
                    Toggle("Fine Edges", isOn: $isOn)
                        .help("Redraws the edge with the Fine Edges model: single hairs, fur, lace")
                    Spacer()
                    if download.installed.count > 1 {
                        Picker("Model", selection: Binding(get: { download.active ?? download.chosen },
                                                           set: { download.choose($0) })) {
                            ForEach(FineEdges.Model.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .controlSize(.small)
                        .help("Which Fine Edges model runs, for every selection: Fast takes seconds, Hair Detail about half a minute for finer hair")
                    } else if let active = download.active {
                        Text(active.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isOn, let failure = download.runFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if isOn, let lastRun = download.lastRun {
                    Text(lastRun)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let progress = download.progress, let model = download.downloading {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { download.cancel() }.controlSize(.small)
                }
                .help("Downloading the Fine Edges \(model.name) model (\(model.downloadSize))")
            } else {
                HStack {
                    Text("Fine Edges")
                    Spacer()
                    Menu("Get") {
                        ForEach(FineEdges.Model.allCases) { model in
                            Button("\(model.name) (\(model.downloadSize))") {
                                let binding = $isOn
                                download.download(model) { binding.wrappedValue = true }
                            }
                            .help(model.detail)
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)
                }
                .help("Downloads a Fine Edges model once (BiRefNet, MIT license); it then runs on this Mac. Fast takes seconds; Hair Detail about half a minute for finer hair. Settings > AI can get the other one later.")
                if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
