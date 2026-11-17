import AtelierCore
import SwiftUI

/// The Fine Edges models' downloads and which one runs, shared by the mask panel and
/// Settings > AI, so both show the same progress and either can start, remove or pick one. The
/// download itself is `ModelDownloadState`'s, as the depth model's is.
final class FineEdgesDownload: ModelDownloadState<FineEdges.Model> {
    /// The one shared download; don't make another.
    static let shared = FineEdgesDownload()

    @Published private(set) var installed: Set<FineEdges.Model> = []
    /// The model that runs when both are downloaded.
    @Published private(set) var chosen = FineEdges.chosen
    /// The last run's result (model, time, foreground share) or why it failed, from `FineEdges`.
    @Published private(set) var lastRun: String?
    @Published private(set) var runFailure: String?
    private var observer: NSObjectProtocol?

    /// Whether either model is downloaded.
    var anyInstalled: Bool { !installed.isEmpty }
    /// The model Fine Edges runs (see `FineEdges.active`).
    var active: FineEdges.Model? { installed.contains(chosen) ? chosen : FineEdges.Model.allCases.first { installed.contains($0) } }

    override init() {
        super.init()
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
        guard !installed.contains(model) else { return }
        startDownload(model, install: { try await FineEdges.install(model, progress: $0) },
                      finished: { [weak self] in
                          self?.refresh()
                          then?()
                      })
    }

    func remove(_ model: FineEdges.Model) {
        remove({ try FineEdges.remove(model) }, finished: { refresh() })
    }
}

/// The Fine Edges switch under an AI selection's edge sliders: a checkbox once a model is
/// downloaded, with a menu beside it naming the model that runs (pick another, or get the one not
/// downloaded yet, with a progress bar under the row), otherwise a Get menu with each model's
/// size, then a progress bar.
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
                    if let active = download.active {
                        modelMenu(active: active)
                    }
                }
                if let progress = download.progress, let model = download.downloading {
                    downloadProgress(progress, model: model)
                } else if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if isOn, let failure = download.runFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if isOn, let lastRun = download.lastRun {
                    Text(lastRun)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let progress = download.progress, let model = download.downloading {
                downloadProgress(progress, model: model)
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
                .help("Downloads a Fine Edges model once (BiRefNet, MIT license); it then runs on this Mac. Fast takes seconds; Hair Detail about half a minute for finer hair. The menu beside Fine Edges (or Settings > AI) can get the other one later.")
                if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Which model runs, as a menu beside the checkbox: the downloaded models to pick from
    /// (ticked: the one that runs, for every selection), and a Get item for each one not
    /// downloaded yet, which downloads it here and then picks it (Rosh, Nov 16, 2026: nothing in
    /// the panel said a second model existed; before, it was only in Settings > AI).
    private func modelMenu(active: FineEdges.Model) -> some View {
        Menu {
            ForEach(Self.menuItems(installed: download.installed, active: active,
                                   downloading: download.downloading)) { item in
                if item.isGet {
                    Button(item.title) { download.download(item.model) }
                        .disabled(!item.isEnabled)
                        .help(item.model.detail)
                } else {
                    Toggle(item.title, isOn: Binding(get: { item.isTicked },
                                                     set: { if $0 { download.choose(item.model) } }))
                        .help(item.model.detail)
                }
            }
        } label: {
            Text(active.name)
        }
        .fixedSize()
        .controlSize(.small)
        .help("Which Fine Edges model runs, for every selection: Fast takes seconds, Hair Detail about half a minute for finer hair. A model not downloaded yet can be got from here.")
    }

    /// One line of the model menu: a downloaded model to pick (ticked when it runs), or Get for
    /// one not downloaded (disabled while another download runs).
    struct MenuItem: Identifiable, Equatable {
        let model: FineEdges.Model
        let title: String
        let isGet: Bool
        let isTicked: Bool
        let isEnabled: Bool
        var id: FineEdges.Model { model }
    }

    /// The model menu's lines, in the models' order (worked out apart from the view so tests can
    /// read them: SwiftUI fills a menu only when it opens on screen).
    nonisolated static func menuItems(installed: Set<FineEdges.Model>, active: FineEdges.Model,
                                      downloading: FineEdges.Model?) -> [MenuItem] {
        FineEdges.Model.allCases.map { model in
            installed.contains(model)
                ? MenuItem(model: model, title: model.name, isGet: false, isTicked: model == active, isEnabled: true)
                : MenuItem(model: model, title: "Get \(model.name) (\(model.downloadSize))", isGet: true,
                           isTicked: false, isEnabled: downloading == nil)
        }
    }

    private func downloadProgress(_ progress: Double, model: FineEdges.Model) -> some View {
        ModelDownloadProgress(progress: progress, help: "Downloading the Fine Edges \(model.name) model (\(model.downloadSize))",
                              cancel: download.cancel)
    }
}
