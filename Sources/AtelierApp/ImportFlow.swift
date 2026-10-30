import AppKit
import AtelierCore
import Combine
import Foundation

/// The Import dialog's state, from choosing photos to the last file copied. The dialog's views
/// only show it; the steps, the chosen sources and what was found in them, and the options all
/// live here so every step works from one source of truth.
@MainActor
final class ImportFlow: ObservableObject {
    enum Step: Int, CaseIterable {
        case choose, cull, importing
    }

    /// A folder or file chosen to import, with what was found in it.
    struct Source: Identifiable, Equatable {
        let url: URL
        /// The photos found (a RAW and its JPEG once), nil while the folder is being listed.
        var photos: [URL]?
        /// Every file, a RAW's JPEG included, and their total size.
        var fileCount = 0
        var bytes: Int64 = 0
        var id: URL { url }
    }

    @Published private(set) var step = Step.choose
    @Published private(set) var sources: [Source] = []
    /// The Cull step, made on Continue to Culling.
    @Published private(set) var cull: CullModel?

    // Options, remembered between imports where the user would expect it.
    @Published var copyFiles = UserDefaults.standard.bool(forKey: "import.copy") {
        didSet { UserDefaults.standard.set(copyFiles, forKey: "import.copy") }
    }
    @Published var destinationPath = UserDefaults.standard.string(forKey: "import.destination") ?? ImportFlow.defaultLibrary {
        didSet { UserDefaults.standard.set(destinationPath, forKey: "import.destination") }
    }
    @Published var presetID = UserDefaults.standard.string(forKey: "import.developPreset") ?? "" {
        didSet { UserDefaults.standard.set(presetID, forKey: "import.developPreset") }
    }
    @Published var cullFirst = UserDefaults.standard.bool(forKey: "import.cull") {
        didSet { UserDefaults.standard.set(cullFirst, forKey: "import.cull") }
    }
    /// Settings > Import's default library folder.
    static var defaultLibrary: String {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier Library").path
    }
    /// nil is a new import entry.
    @Published var existingGroup: Int64?
    @Published var keywords = ""
    /// The new entry's name. It starts as the first folder's name, as real text the user can
    /// add to or change; it follows the sources until the user edits it.
    @Published private(set) var name = ""
    private var nameEdited = false

    private weak var model: LibraryModel?
    /// Copies the files to the library while the user culls; handed to the import on Import.
    private var stager: ImportStager?
    private var watch: AnyCancellable?
    /// The photos the copy step shows behind its figures: the culled photos with their
    /// thumbnails, or the photos chosen.
    @Published private(set) var wall: [ImportWallPhoto] = []

    init(model: LibraryModel) {
        self.model = model
        existingGroup = model.pendingImportGroup
        add(model.pendingImportSources)
    }

    // MARK: Sources

    var isScanning: Bool { sources.contains { $0.photos == nil } }
    /// Every photo found, in source order.
    var photos: [URL] { sources.flatMap { $0.photos ?? [] } }
    var photoCount: Int { sources.reduce(0) { $0 + ($1.photos?.count ?? 0) } }
    var bytes: Int64 { sources.reduce(0) { $0 + $1.bytes } }

    func add(_ urls: [URL]) {
        for url in urls where !sources.contains(where: { $0.url == url }) {
            sources.append(Source(url: url))
            Task.detached(priority: .userInitiated) { [weak self] in
                let files = Importer.collectFiles(from: [url])
                let photos = FilePairs.pairs(files).map(\.primary)
                let bytes = files.reduce(Int64(0)) {
                    $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                await MainActor.run {
                    guard let self, let index = self.sources.firstIndex(where: { $0.url == url }) else { return }
                    self.sources[index].photos = photos
                    self.sources[index].fileCount = files.count
                    self.sources[index].bytes = bytes
                }
            }
        }
        followSources()
    }

    func remove(_ url: URL) {
        sources.removeAll { $0.url == url }
        followSources()
    }

    // MARK: Name

    var suggestedName: String { sources.first?.url.lastPathComponent ?? "New Import" }

    func setName(_ name: String) {
        self.name = name
        nameEdited = true
    }

    private func followSources() {
        if !nameEdited { name = sources.isEmpty ? "" : suggestedName }
    }

    /// The entry name, which also names the event folder in copy mode.
    var effectiveName: String {
        if let existingGroup, let entry = model?.sidebar.imports.first(where: { $0.id == existingGroup }) {
            return entry.name
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    // MARK: Steps

    var canContinue: Bool { !sources.isEmpty && !isScanning && photoCount > 0 }

    var options: ImportOptions {
        let mode: ImportMode = copyFiles
            ? .copy(destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true), eventName: effectiveName)
            : .reference
        let target: ImportTarget = existingGroup.map { .existingGroup($0) } ?? .newGroup(name: effectiveName)
        return ImportOptions(mode: mode, target: target, keywords: keywords.split(separator: ",").map(String.init),
                             developPreset: model?.develop.presets.first { $0.id.uuidString == presetID })
    }

    /// Import, or with culling on, the Cull step. Both stay in the dialog.
    func next(close: @escaping () -> Void) {
        guard let model, canContinue else { return }
        guard cullFirst else {
            wall = photos.map { ImportWallPhoto(url: $0, thumbnail: nil) }
            model.runImport(sources: sources.map(\.url), options: options)
            step = .importing
            return
        }
        let options = self.options
        let cull = model.importCull(sources: sources.map(\.url), options: options)
        cull.onBack = { [weak self] in self?.back() }
        cull.onClose = { [weak self, weak cull] imported in
            guard let self else { return }
            if imported {
                // The import owns the copies made ahead now, and discards what it doesn't use.
                self.stager = nil
                self.wall = (cull?.photos ?? []).compactMap { photo in
                    photo.url.map { ImportWallPhoto(url: $0, thumbnail: photo.thumbnail) }
                }
            }
            self.watch = nil
            self.cull = nil
            if imported { self.step = .importing } else { self.discardAhead(); close() }
        }
        // Copy ahead once the photos are listed, alongside the analysis: it reads little of each
        // file, the copy reads the rest.
        let stager = ImportStager(mode: options.mode)
        cull.stager = stager
        self.stager = stager
        let urls = sources.map(\.url)
        watch = cull.$isLoading.first { !$0 }.sink { [weak cull] _ in
            guard let cull else { return }
            stager.start(sources: urls, workers: Importer.workers(for: options.mode) / 2) { [weak cull] progress in
                Task { @MainActor [weak cull] in cull?.ahead = progress }
            }
        }
        self.cull = cull
        step = .cull
    }

    private func discardAhead() {
        stager?.discard()
        stager = nil
        watch = nil
    }

    /// From the Cull step back to the settings, as they were.
    func back() {
        discardAhead()
        cull?.stop()
        cull = nil
        step = .choose
    }

    /// The dialog closed, by any route.
    func closed() {
        discardAhead()
        cull?.stop()
        cull = nil
    }
}

/// A photo on the copy step's wall: its thumbnail when the Cull step already made one.
struct ImportWallPhoto: Identifiable {
    let url: URL
    let thumbnail: NSImage?
    /// Matches `ImportStatus.doneFiles`.
    let key: String

    init(url: URL, thumbnail: NSImage?) {
        self.url = url
        self.thumbnail = thumbnail
        key = url.standardizedFileURL.path
    }

    var id: URL { url }
}
