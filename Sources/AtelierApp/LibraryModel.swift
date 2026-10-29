import AppKit
import AtelierCore
import Combine
import Foundation
import GRDB

enum ViewMode {
    case grid
    case loupe
    case develop
}

enum SidebarItem: Hashable {
    case all
    case volume(Int64)
    case folder(Int64)
    case collection(Int64)
    case importGroup(Int64)

    var scope: LibraryScope {
        switch self {
        case .all: return .all
        case .volume(let id): return .volume(id)
        case .folder(let id): return .folder(id)
        case .collection(let id): return .collection(id)
        case .importGroup(let id): return .importGroup(id)
        }
    }
}

struct ImportStatus: Equatable {
    var phase: String
    /// nil shows an indeterminate bar.
    var fraction: Double?
}

/// A file the last import or export could not handle, shown from the status bar.
struct Problem: Hashable {
    var name: String
    var reason: String
}

struct SidebarData: Equatable, Sendable {
    var volumes: [Volume] = []
    var folders: [Folder] = []
    var collections: [PhotoCollection] = []
    var imports: [ImportGroupSummary] = []
    var totalCount = 0
}

@MainActor
final class LibraryModel: ObservableObject {
    let catalog: Catalog
    let previews: PreviewCache
    let previewScheduler: PreviewScheduler
    let develop: DevelopController
    let editWatcher = EditWatcher()
    let ai = AIController()

    @Published var rows: [AssetRow] = []
    @Published var sidebar = SidebarData()
    @Published var sidebarSelection: SidebarItem? = .all {
        didSet { filter.scope = sidebarSelection?.scope ?? .all }
    }
    @Published var filter = LibraryFilter(groupsRawPairs: FilePairs.isGrouping) {
        didSet {
            guard filter != oldValue else { return }
            observeRows()
            if filter.groupsRawPairs != oldValue.groupsRawPairs { observeSidebar() }
        }
    }
    @Published var selection: Set<Int64> = []
    /// Set while a Filmstrip right-click menu is open; see `targetIDs`.
    var menuTargets: [Int64]?
    @Published var focusedID: Int64? {
        didSet {
            guard focusedID != oldValue else { return }
            reloadDetail()
            if mode == .develop { develop.open(focusedID) }
        }
    }
    @Published var detail: AssetDetail?
    @Published var mode: ViewMode = .grid {
        didSet {
            if mode == .develop { develop.open(focusedID) } else if oldValue == .develop { develop.flushSave() }
        }
    }
    @Published var status: String?
    @Published var showingImportSheet = false
    @Published var pendingImportSources: [URL] = []
    /// Import entry preselected in the import sheet, when importing more into an existing one.
    @Published var pendingImportGroup: Int64?
    @Published var importProgress: ImportStatus?
    /// Files the last import or export could not handle, shown on request from the status bar.
    @Published var problems: [Problem] = []
    @Published var problemsTitle = ""
    @Published var showingExportSheet = false
    /// Photos the open export dialog will export, in grid order.
    @Published private(set) var exportIDs: [Int64] = []
    @Published var exportProgress: ImportStatus?
    /// The Match Look dialog, while open, and Match each photo's progress in the status bar.
    @Published var matchLook: MatchLookModel?
    @Published var matchProgress: ImportStatus?
    /// The Remove Photo dialog, while open.
    @Published var removal: PhotoRemoval?
    var matchTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importWasCancelled = false
    private var shownImportGroup: Int64?
    /// Bumped when previews are generated so visible cells reload their images.
    @Published var previewRevision = 0
    /// Zoom shared by loupe and develop; kept when moving between photos, as in Lightroom.
    /// Not published here: only the photo and the zoom bar watch it.
    let zoomState = ZoomState()
    var zoom: ZoomLevel {
        get { zoomState.level }
        set { zoomState.level = newValue }
    }
    var zoomReport: ZoomReport {
        get { zoomState.report }
        set { zoomState.report = newValue }
    }
    @Published var showingShortcuts = false
    /// The Cull view, while open.
    @Published var cullSession: CullModel?
    /// The library window, which receives the single-key commands.
    weak var mainWindow: NSWindow?
    /// The photo at the top of the grid, kept while the grid is closed and between launches.
    var gridTopID: Int64?
    /// Last launch's session, applied when its photos first load.
    var pendingSession: SavedSession?
    /// Set until the restored sidebar item has been checked against the catalog.
    var pendingSessionScope = false
    /// The filter the current `rows` were loaded with.
    var loadedRowsFilter: LibraryFilter?
    var sessionSaveScheduled = false
    var sessionObserver: AnyCancellable?

    private var rowsTask: Task<Void, Never>?
    private var sidebarTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var revisionScheduled = false

    /// Called once, when the library's first sidebar data has loaded.
    var onLibraryLoaded: ((SidebarData) -> Void)?

    /// `report` gets each startup step (text, then progress 0 to 1) for the splash screen.
    init(report: (String, Double) -> Void = { _, _ in }) {
        let packageURL = Catalog.defaultPackageURL
        report("Opening catalog “\(packageURL.deletingPathExtension().lastPathComponent)”…", 0.15)
        do {
            catalog = try Catalog(packageURL: packageURL)
        } catch {
            fatalError("Could not open the catalog at \(packageURL.path): \(error)")
        }
        report("Checking previews…", 0.35)
        previews = PreviewCache(rootURL: catalog.previewsURL!)
        previews.discardIfOutdated()
        previewScheduler = PreviewScheduler(cache: previews)
        develop = DevelopController(catalog: catalog, previews: previews)
        report("Checking drives and network volumes…", 0.55)
        try? catalog.refreshVolumes()
        report("Loading library…", 0.75)
        restoreSessionFilter()
        observeRows()
        observeSidebar()
        installKeyMonitor()
        observeMounts()
        // Settings > Import > "Show RAW+JPEG pairs as one photo".
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.filter.groupsRawPairs != FilePairs.isGrouping else { return }
                self.filter.groupsRawPairs = FilePairs.isGrouping
            }
        }
        previewScheduler.onFinish { [weak self] _, _ in
            Task { @MainActor in self?.previewsChanged() }
        }
        develop.onPreviewsUpdated = { [weak self] id in
            ThumbnailLoader.shared.invalidate(id)
            self?.previewsChanged()
        }
        ai.model = self
        editWatcher.onChange = { [weak self] id in self?.editedFileChanged(id) }
        // Folder events can be missed on network shares; coming back from the editor checks too.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editWatcher.check() }
        }
    }

    // MARK: Observation

    private func observeRows() {
        rowsTask?.cancel()
        let filter = self.filter
        let observation = ValueObservation.tracking { db in
            try Catalog.fetchAssetRows(db, filter: filter)
        }
        let writer = catalog.writer
        rowsTask = Task { [weak self] in
            do {
                for try await rows in observation.values(in: writer) {
                    // A replaced observation can still deliver once or twice after it is cancelled;
                    // its rows belong to the old scope.
                    guard let self, !Task.isCancelled, self.filter == filter else { return }
                    self.rows = rows
                    self.loadedRowsFilter = filter
                    let visible = Set(rows.map(\.id))
                    self.selection.formIntersection(visible)
                    if let focused = self.focusedID, !visible.contains(focused) {
                        self.focusedID = rows.first?.id
                    }
                    self.reloadDetail()
                    if !self.pendingSessionScope { self.finishSessionRestore(visible: visible) }
                }
            } catch {
                self?.status = "Catalog error: \(error.localizedDescription)"
            }
        }
    }

    private func observeSidebar() {
        sidebarTask?.cancel()
        let pairs = filter.groupsRawPairs
        let observation = ValueObservation.tracking { db in
            SidebarData(
                volumes: try Volume.order(Column("name")).fetchAll(db),
                folders: try Folder.order(Column("relativePath")).fetchAll(db),
                collections: try PhotoCollection.order(Column("name")).fetchAll(db),
                imports: try Catalog.fetchImportGroupSummaries(db, groupingRawPairs: pairs),
                totalCount: try Catalog.fetchPhotoCount(db, groupingRawPairs: pairs))
        }
        let writer = catalog.writer
        sidebarTask = Task { [weak self] in
            do {
                for try await data in observation.values(in: writer) {
                    self?.sidebar = data
                    self?.checkRestoredScope(data)
                    if let loaded = self?.onLibraryLoaded {
                        self?.onLibraryLoaded = nil
                        loaded(data)
                    }
                }
            } catch {
                self?.status = "Catalog error: \(error.localizedDescription)"
            }
        }
    }

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
    }

    func reloadDetail() {
        detail = focusedID.flatMap { try? catalog.detail(for: $0) }
        // An edit saved while Atelier was not watching (after a relaunch) is picked up when shown.
        if let detail, let id = detail.asset.id, rows.first(where: { $0.id == id })?.stackKind == .externalEdit,
           let url = detail.fileURL {
            editWatcher.watch(id, at: url, known: detail.asset.modifiedAt)
        }
    }

    // MARK: Selection

    /// Photos that an edit applies to: the loupe photo, or the grid selection. While a
    /// Filmstrip right-click menu is open, its selection, in every mode.
    var targetIDs: [Int64] {
        if let menuTargets { return menuTargets }
        if mode != .grid || selection.isEmpty {
            return focusedID.map { [$0] } ?? []
        }
        return Array(selection)
    }

    func openDevelop() {
        if focusedID == nil { focusedID = selection.first ?? rows.first?.id }
        if focusedID != nil { mode = .develop }
    }

    /// Pastes copied develop settings onto the selection (grid) or the open photo.
    func pasteDevelopSettings() {
        develop.pasteSettings(onto: targetIDs)
    }

    func undo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.undoManager?.undo()
        } else if mode == .develop {
            develop.undo()
        }
    }

    func redo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.undoManager?.redo()
        } else if mode == .develop {
            develop.redo()
        }
    }

    func rotate(clockwise: Bool) {
        guard mode == .develop else { return }
        develop.setCrop(develop.crop.turned(clockwise: clockwise))
    }

    func resetDevelopSettings() {
        develop.resetSettings(of: targetIDs)
    }

    func showInFinder() {
        let urls = targetIDs.compactMap { try? catalog.fileURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            status = "The originals are offline. Connect their drive to show them in Finder."
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Makes a right-clicked grid photo the selection unless it is already part of it.
    func prepareContextMenu(for id: Int64) {
        if !selection.contains(id) { selection = [id] }
        focusedID = id
    }

    // MARK: Zoom

    func toggleZoom() {
        if mode == .grid {
            openLoupe()
            zoom = .percent(Self.clickZoomPercent)
        } else {
            zoom = zoomReport.isZoomedPastFit ? .fit : .percent(Self.clickZoomPercent)
        }
    }

    /// Settings > Develop: the zoom a click or Z goes to (Lightroom's 1:1 by default).
    nonisolated static var clickZoomPercent: Double {
        let value = UserDefaults.standard.double(forKey: "zoom.clickPercent")
        return value > 0 ? value : 100
    }

    func zoomIn() {
        guard mode != .grid else { return toggleZoom() }
        let current = zoomReport.percent > 0 ? zoomReport.percent : 100
        zoom = .percent(min(1600, current * 1.5))
    }

    func zoomOut() {
        guard mode != .grid else { return }
        let next = zoomReport.percent / 1.5
        zoom = next <= zoomReport.fitPercent * 1.01 ? .fit : .percent(next)
    }

    func copyDevelopSettings() {
        if mode == .develop {
            develop.copySettings()
        } else if let id = focusedID {
            develop.copySettings(of: id)
        }
    }

    func openLoupe() {
        if focusedID == nil { focusedID = selection.first ?? rows.first?.id }
        if focusedID != nil { mode = .loupe }
    }

    func step(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = focusedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        let next = min(max(index + delta, 0), rows.count - 1)
        focusedID = rows[next].id
        selection = [rows[next].id]
    }

    // MARK: Edits

    /// `targetIDs` plus the JPEGs hidden behind those RAWs, which follow their RAW's rating,
    /// flag, label, keywords, collections and import entries.
    var pairTargetIDs: [Int64] {
        guard filter.groupsRawPairs else { return targetIDs }
        return (try? catalog.withPairSiblings(targetIDs)) ?? targetIDs
    }

    func setRating(_ rating: Int) { perform { try $0.setRating(rating, for: self.pairTargetIDs) } }
    func setFlag(_ flag: Flag) { perform { try $0.setFlag(flag, for: self.pairTargetIDs) } }
    func toggleLabel(_ label: ColorLabel) { perform { try $0.toggleColorLabel(label, for: self.pairTargetIDs) } }

    func setKeywords(_ text: String) {
        let names = text.split(separator: ",").map(String.init)
        perform { try $0.setKeywords(names, for: self.pairTargetIDs) }
    }

    func setTitle(_ title: String, caption: String) {
        guard let id = focusedID else { return }
        perform { try $0.setTitle(title, caption: caption, for: id) }
    }

    func createCollection(named name: String, addingSelection: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { catalog in
            let collection = try catalog.createCollection(named: trimmed)
            if addingSelection, let id = collection.id {
                try catalog.addAssets(self.pairTargetIDs, toCollection: id)
            }
        }
    }

    func addSelection(toCollection id: Int64) {
        perform { try $0.addAssets(self.pairTargetIDs, toCollection: id) }
    }

    func removeSelectionFromCurrentCollection() {
        guard case .collection(let id) = sidebarSelection else { return }
        perform { try $0.removeAssets(self.pairTargetIDs, fromCollection: id) }
    }

    func renameCollection(_ id: Int64, to name: String) {
        perform { try $0.renameCollection(id, to: name) }
    }

    // MARK: Import entries

    func addSelection(toImportGroup id: Int64) {
        perform { try $0.addAssets(self.pairTargetIDs, toImportGroup: id) }
    }

    func removeSelectionFromCurrentImport() {
        guard case .importGroup(let id) = sidebarSelection else { return }
        perform { try $0.removeAssets(self.pairTargetIDs, fromImportGroup: id) }
    }

    func renameImportGroup(_ id: Int64, to name: String) {
        perform { try $0.renameImportGroup(id, to: name) }
    }

    /// Deletes the entry; its photos stay in All Photographs and their folders.
    func deleteImportGroup(_ id: Int64) {
        if sidebarSelection == .importGroup(id) { sidebarSelection = .all }
        perform { try $0.deleteImportGroup(id) }
    }

    func deleteCollection(_ id: Int64) {
        if sidebarSelection == .collection(id) { sidebarSelection = .all }
        perform { try $0.deleteCollection(id) }
    }

    private func perform(_ edit: (Catalog) throws -> Void) {
        do {
            try edit(catalog)
            reloadDetail()
            if UserDefaults.standard.bool(forKey: "xmp.autoWrite") { autoWriteXMP(pairTargetIDs) }
        } catch {
            status = error.localizedDescription
        }
    }

    func refreshVolumes() {
        perform { try $0.refreshVolumes() }
        // Photos on a drive that just came back can be read now.
        previewScheduler.retryFailed()
    }

    /// Settings > Metadata: keeps sidecars in step with catalog edits, quietly.
    private func autoWriteXMP(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let catalog = self.catalog
        Task.detached(priority: .utility) {
            _ = try? catalog.writeXMPSidecars(for: ids)
            await MainActor.run { self.reloadDetail() }
        }
    }

    func writeXMP(selectionOnly: Bool) {
        let ids: [Int64]? = selectionOnly ? targetIDs : nil
        let catalog = self.catalog
        status = "Writing XMP…"
        Task.detached {
            let message: String
            do {
                let result = try catalog.writeXMPSidecars(for: ids)
                var parts = ["Wrote \(result.written) XMP sidecar\(result.written == 1 ? "" : "s")"]
                if result.offline > 0 { parts.append("\(result.offline) waiting for offline volumes") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
                message = parts.joined(separator: ", ")
            } catch {
                message = "XMP write failed: \(error.localizedDescription)"
            }
            await MainActor.run { self.status = message }
        }
    }

    // MARK: Import

    /// Opens the import dialog. Sources are chosen inside it, or arrive by drag and drop.
    func beginImport(into groupID: Int64? = nil, sources: [URL] = []) {
        guard importTask == nil else {
            status = "An import is already running."
            return
        }
        pendingImportSources = sources
        pendingImportGroup = groupID
        showingImportSheet = true
    }

    /// `then` runs on the main actor with the result, before the status is set.
    func runImport(sources: [URL], options: ImportOptions, then: ((ImportProgress) -> Void)? = nil) {
        let importer = Importer(catalog: catalog, previews: nil, scheduler: previewScheduler)
        importProgress = ImportStatus(phase: "Scanning…", fraction: nil)
        shownImportGroup = nil
        importTask = Task.detached {
            let result = await importer.run(sources: sources, options: options) { progress in
                let phase: String
                let fraction: Double?
                phase = "Importing \(min(progress.processed + 1, progress.total)) of \(progress.total)"
                fraction = Double(progress.processed) / Double(max(progress.total, 1))
                let groupID = progress.importGroupId
                Task { @MainActor in
                    // Show the entry right away so photos appear as they arrive.
                    if let groupID, self.shownImportGroup != groupID {
                        self.shownImportGroup = groupID
                        self.sidebarSelection = .importGroup(groupID)
                    }
                    if self.importTask != nil {
                        self.importProgress = ImportStatus(phase: phase, fraction: fraction)
                    }
                }
            }
            await MainActor.run {
                var parts = ["Imported \(result.imported) photo\(result.imported == 1 ? "" : "s")"]
                if result.skipped > 0 { parts.append("\(result.skipped) already in the catalog") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) could not be read") }
                if Task.isCancelled || self.importWasCancelled { parts.insert("Import cancelled", at: 0) }
                self.status = parts.joined(separator: ", ")
                then?(result)
                self.problems = result.failures.map { Problem(name: $0.url.lastPathComponent, reason: $0.reason) }
                self.problemsTitle = "These files could not be imported"
                self.importProgress = nil
                self.importTask = nil
                self.importWasCancelled = false
                self.previewRevision += 1
            }
        }
    }

    func cancelImport() {
        importWasCancelled = true
        importTask?.cancel()
        importProgress = ImportStatus(phase: "Cancelling…", fraction: nil)
    }

    // MARK: Export

    /// Opens the export dialog for the selection, or the open photo in loupe and develop.
    func beginExport() {
        guard exportTask == nil else {
            status = "An export is already running."
            return
        }
        develop.flushSave()
        let targets = Set(targetIDs)
        guard !targets.isEmpty else {
            status = "Select the photos to export first."
            return
        }
        let ordered = rows.map(\.id).filter { targets.contains($0) }
        exportIDs = ordered.isEmpty ? Array(targets) : ordered
        showingExportSheet = true
    }

    func runExport(settings: ExportSettings, revealWhenDone: Bool) {
        let ids = exportIDs
        let exporter = Exporter(catalog: catalog)
        exportProgress = ImportStatus(phase: "Exporting…", fraction: 0)
        exportTask = Task.detached {
            let result = await exporter.run(assetIDs: ids, settings: settings) { progress in
                let phase = "Exporting \(min(progress.processed + 1, progress.total)) of \(progress.total)"
                let fraction = Double(progress.processed) / Double(max(progress.total, 1))
                Task { @MainActor in
                    if self.exportTask != nil, self.exportProgress?.phase != "Cancelling…" {
                        self.exportProgress = ImportStatus(phase: phase, fraction: fraction)
                    }
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                let count = result.exported.count
                var parts = ["Exported \(count) photo\(count == 1 ? "" : "s")"]
                if !result.failures.isEmpty { parts.append("\(result.failures.count) could not be exported") }
                if cancelled { parts.insert("Export cancelled", at: 0) }
                self.status = parts.joined(separator: ", ")
                self.problems = result.failures.map { Problem(name: $0.filename, reason: $0.reason) }
                self.problemsTitle = "These photos could not be exported"
                self.exportProgress = nil
                self.exportTask = nil
                if revealWhenDone, !result.exported.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(result.exported)
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = ImportStatus(phase: "Cancelling…", fraction: nil)
    }

    // MARK: Previews

    /// The cached preview, or nil after queueing it. Thumbnails come first; the loupe's
    /// 2560 px preview is marked urgent so it jumps the queue.
    func thumbnailURL(for id: Int64, size: PreviewCache.Size = .thumbnail) -> URL? {
        if previews.has(size, for: id) { return previews.url(for: id, size: size) }
        if let source = try? catalog.fileURL(for: id) {
            // Edited photos are rebuilt with their settings, for example after the cache is cleared.
            let settings = try? catalog.developSettings(for: id)
            previewScheduler.request(size, for: id, source: source, urgent: size == .preview || mode == .grid,
                                     settings: settings)
        }
        return nil
    }

    /// A grid cell scrolled away before its thumbnail started.
    func cancelThumbnail(for id: Int64) {
        previewScheduler.cancel(.thumbnail, for: id)
    }

    /// Coalesces preview completions into one grid refresh every 150 ms.
    private func previewsChanged() {
        guard !revisionScheduled else { return }
        revisionScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            revisionScheduled = false
            previewRevision += 1
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) }
            return handled ? nil : event
        }
    }

    /// Lightroom-style culling keys. Ignored while typing in a text field or a sheet is open.
    private func handleKey(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        // Only the library window; never Settings or other windows.
        guard let window = NSApp.keyWindow, window === mainWindow, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }

        if mode == .develop, handleTransformKey(event) { return true }
        if mode == .develop, handleMaskingKey(event) { return true }

        // Delete opens Remove Photo, as in Lightroom; not while cropping or painting an AI mask.
        if event.keyCode == 51 || event.keyCode == 117,
           !(mode == .develop && (develop.isCropping || develop.isAIOpen)) {
            beginRemovePhotos()
            return true
        }

        // [ and ] size the AI brush, as in Lightroom.
        if mode == .develop, develop.isAIOpen, event.keyCode == 33 || event.keyCode == 30 {
            let factor = event.keyCode == 30 ? 1.25 : 0.8
            ai.brushSize = min(max(ai.brushSize * factor, 0.005), 0.15)
            return true
        }

        switch event.keyCode {
        case 123 where mode != .grid: step(-1); return true           // left arrow
        case 124 where mode != .grid: step(1); return true            // right arrow
        case 36 where mode != .develop, 76 where mode != .develop:     // return, enter
            if mode == .loupe { mode = .grid } else { openLoupe() }
            return true
        case 53 where mode != .grid: mode = .grid; return true        // escape
        default: break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              let action = KeyBindings.action(for: key) else { return false }
        return perform(action)
    }

    /// Runs a single-key command. Returns false when it doesn't apply in the current view.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .rating0: setRating(0)
        case .rating1: setRating(1)
        case .rating2: setRating(2)
        case .rating3: setRating(3)
        case .rating4: setRating(4)
        case .rating5: setRating(5)
        case .labelRed: toggleLabel(.red)
        case .labelYellow: toggleLabel(.yellow)
        case .labelGreen: toggleLabel(.green)
        case .labelBlue: toggleLabel(.blue)
        case .pick: setFlag(.picked)
        case .reject:
            // As in Lightroom, X in the crop tool swaps the crop's orientation instead.
            if mode == .develop, develop.isCropping {
                develop.setCrop(develop.crop.switchedOrientation(imageAspect: develop.orientedAspect))
            } else {
                setFlag(.rejected)
            }
        case .unflag: setFlag(.none)
        case .loupe: openLoupe()
        case .develop: openDevelop()
        case .grid: mode = .grid
        case .beforeAfter:
            guard mode == .develop else { return false }
            develop.showingBefore.toggle()
        case .compareMode:
            guard mode == .develop else { return false }
            develop.cycleCompareMode()
        case .zoom: toggleZoom()
        case .crop:
            if mode != .develop { openDevelop() }
            guard mode == .develop else { return false }
            develop.isCropping.toggle()
        case .linearGradient, .brush:
            if mode != .develop { openDevelop() }
            guard mode == .develop else { return false }
            develop.startMaskTool(action == .brush ? .brush : .linear)
        case .maskOverlay:
            guard mode == .develop, develop.isMasking else { return false }
            develop.showMaskOverlay.toggle()
        case .treatment:
            guard mode == .develop, develop.assetID != nil else { return false }
            develop.setMonochrome(!develop.settings.monochrome)
        }
        return true
    }

    /// Guided Upright, as in Lightroom: ⇧T opens it, Delete removes the selected guide, Esc closes it.
    private func handleTransformKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "t" {
            if develop.isGuiding { develop.isGuiding = false } else { develop.setUpright(.guided) }
            return true
        }
        guard develop.isGuiding else { return false }
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            develop.deleteSelectedGuide()
            return true
        case 53:  // escape
            develop.isGuiding = false
            return true
        default:
            return false
        }
    }

    /// Lightroom's Masking keys: ⇧W opens it, ⇧M draws a radial gradient, [ and ] size the brush
    /// (with ⇧, its feather), Delete removes the selected part, Esc cancels the tool or closes.
    private func handleMaskingKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if shift, key == "w" {
            develop.isMasking.toggle()
            return true
        }
        if shift, key == "m" {
            develop.startMaskTool(.radial)
            return true
        }
        guard develop.isMasking else { return false }
        switch event.keyCode {
        case 33, 30:  // [ and ]
            let larger = event.keyCode == 30
            if shift {
                develop.brushFeather = min(100, max(0, develop.brushFeather + (larger ? 10 : -10)))
            } else {
                develop.brushSize = min(max(develop.brushSize * (larger ? 1.2 : 1 / 1.2), 0.005), 0.4)
            }
            return true
        case 51, 117:  // delete, forward delete
            develop.deleteSelectedMaskPart()
            return true
        case 53:  // escape
            if develop.maskTool != nil { develop.maskTool = nil } else { develop.isMasking = false }
            return true
        default:
            return false
        }
    }
}
