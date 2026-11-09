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
    /// The Import dialog's figures: photos done and in all, "1.2 GB of 9.8 GB", "180 MB/s",
    /// "About 1 minute", and the file being read or copied.
    var done: Int?
    var total: Int?
    var amount: String?
    var speed: String?
    var timeLeft: String?
    var file: String?
    /// The paths of the files in the catalog so far, for the dialog's wall of photos.
    var doneFiles: Set<String> = []
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
    /// Private import entries and collections, shown or not, for View > Show Private Photos.
    var privateListCount = 0
}

@MainActor
final class LibraryModel: ObservableObject {
    let catalog: Catalog
    lazy var processorSessions = ProcessorDesktopSessions(model: self)
    /// Library > Show/Hide Private Photos and hiding them again when Atelier isn't used.
    lazy var privatePhotos = PrivatePhotos(model: self)
    /// Set when lists were just made private or hidden: the next sidebar data leaves a sidebar
    /// item that is no longer listed.
    var leavesHiddenScope = false
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
            if filter.groupsRawPairs != oldValue.groupsRawPairs || filter.privacy != oldValue.privacy {
                observeSidebar()
            }
        }
    }
    @Published var selection: Set<Int64> = []
    /// Set while a Filmstrip right-click menu is open; see `targetIDs`.
    var menuTargets: [Int64]?
    @Published var focusedID: Int64? {
        didSet {
            guard focusedID != oldValue else { return }
            zoomForNextPhoto(leaving: oldValue)
            reloadDetail()
            if mode == .develop {
                develop.open(focusedID)
                if let image = develop.image, !develop.showsPreviousPhoto, let width = detail?.asset.width, let height = detail?.asset.height {
                    zoomState.showNow(image, pixelSize: develop.croppedPixelSize(assetSize: CGSize(width: width, height: height)))
                }
            }
            prefetchNeighbourPreviews()
        }
    }
    @Published var detail: AssetDetail?
    @Published var mode: ViewMode = .grid {
        didSet {
            if mode == .develop { develop.open(focusedID) } else if oldValue == .develop { develop.flushSave() }
            prefetchNeighbourPreviews()
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
    /// The Delete Import dialog, while open.
    @Published var deletingImport: ImportDeletion?
    var matchTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importWasCancelled = false
    /// Bumped when previews are generated so visible cells reload their images.
    @Published var previewRevision = 0
    /// Zoom shared by loupe and develop; what happens on moving to another photo is a setting
    /// (see `ZoomOnPhotoChange`).
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
    /// Where the last click in the library window landed, the text field the user chose (by
    /// clicking or tabbing into it), and whether the last key that went on to the window was
    /// Tab. Together they tell a field the user is typing in from one SwiftUI gave the keyboard
    /// on its own: with nothing else able to take it, SwiftUI hands the window's first text
    /// field (Search Presets, in Develop) the keyboard, which silently swallowed ← →, Tab and
    /// every single-key command (Rosh's test, Nov 9, 2026).
    private var lastClick: NSPoint?
    private weak var chosenTextField: NSView?
    private var lastKeyWasTab = false
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
    private var inputMonitor: Any?
    private var revisionScheduled = false

    /// Called once, when the library's first sidebar data has loaded.
    var onLibraryLoaded: ((SidebarData) -> Void)?

    /// The catalog has opened successfully before any library observers or tools are installed.
    init(catalog: Catalog, report: (String, Double) -> Void = { _, _ in }) {
        self.catalog = catalog
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
        installInputMonitor()
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
        develop.onSettingsSaved = { [weak self] id in
            if UserDefaults.standard.bool(forKey: "xmp.autoWrite") { self?.autoWriteXMP([id]) }
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
        let privacy = filter.privacy
        let observation = ValueObservation.tracking { db in
            SidebarData(
                volumes: try Volume.order(Column("name")).fetchAll(db),
                folders: try Catalog.fetchFolders(db, privacy: privacy),
                collections: try Catalog.fetchCollections(db, privacy: privacy),
                imports: try Catalog.fetchImportGroupSummaries(db, groupingRawPairs: pairs, privacy: privacy),
                totalCount: try Catalog.fetchPhotoCount(db, groupingRawPairs: pairs, privacy: privacy),
                privateListCount: try Catalog.fetchPrivateListCount(db))
        }
        let writer = catalog.writer
        sidebarTask = Task { [weak self] in
            do {
                for try await data in observation.values(in: writer) {
                    // A replaced observation can still deliver; it may list hidden private lists.
                    guard let self, !Task.isCancelled, self.filter.privacy == privacy else { return }
                    self.sidebar = data
                    self.checkRestoredScope(data)
                    // The last private list was made not private: nothing is left to show or hide.
                    if data.privateListCount == 0, privacy != .hidden { self.privatePhotos.reset() }
                    if self.leavesHiddenScope {
                        self.leavesHiddenScope = false
                        self.leaveMissingScope(data)
                    }
                    if let loaded = self.onLibraryLoaded {
                        self.onLibraryLoaded = nil
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

    /// Settings > Develop > "When you move to another photo": open it at Fit or Fill (the
    /// default, at Fit), return to the zoom it was left at, or keep the zoom as Lightroom does.
    enum ZoomOnPhotoChange: String, CaseIterable {
        case reset, remember, keep
        nonisolated static let key = "zoom.onPhotoChange"
        nonisolated static let resetLevelKey = "zoom.resetLevel"

        nonisolated static var current: ZoomOnPhotoChange {
            UserDefaults.standard.string(forKey: key).flatMap { ZoomOnPhotoChange(rawValue: $0) } ?? .reset
        }

        /// Fit or Fill, for `reset` and for photos `remember` hasn't seen zoomed.
        nonisolated static var resetLevel: ZoomLevel {
            UserDefaults.standard.string(forKey: resetLevelKey) == "fill" ? .fill : .fit
        }
    }

    /// Each photo's zoom and visible center when it was left, for "Return to its last zoom".
    /// Saved across launches (see `savePhotoZooms`).
    private var zoomByPhoto: [Int64: (level: ZoomLevel, center: CGPoint?)] = LibraryModel.loadPhotoZooms()

    private func zoomForNextPhoto(leaving previous: Int64?) {
        let mode = ZoomOnPhotoChange.current
        guard let previous else {
            // The first photo after launch: the session restored the zoom; with "Return to its
            // last zoom" the photo's own zoom and position come back too.
            if mode == .remember, let saved = focusedID.flatMap({ zoomByPhoto[$0] }) {
                zoomState.pendingCenter = saved.center
                if zoom != saved.level { zoom = saved.level }
            }
            return
        }
        let center = zoomState.currentCenter?()
        let next: ZoomLevel
        switch mode {
        case .keep:
            // Same zoom on the same spot of the next photo, as Lightroom does for checking
            // focus across a burst.
            zoomState.pendingCenter = center
            return
        case .reset:
            next = ZoomOnPhotoChange.resetLevel
            zoomState.pendingCenter = nil
        case .remember:
            zoomByPhoto[previous] = (zoom, center)
            savePhotoZooms()
            let saved = focusedID.flatMap { zoomByPhoto[$0] }
            next = saved?.level ?? ZoomOnPhotoChange.resetLevel
            zoomState.pendingCenter = saved?.center
        }
        if zoom != next { zoom = next }
    }

    nonisolated private static let photoZoomsKey = "zoom.byPhoto"
    /// Photos remembered at most; the ones zoomed longest ago are dropped first.
    nonisolated private static let photoZoomsLimit = 2000

    /// Records the open photo's zoom too, as the app quits.
    func rememberCurrentPhotoZoom() {
        guard ZoomOnPhotoChange.current == .remember, let id = focusedID, mode != .grid else { return }
        // No photo view yet (still loading): keep what was saved.
        guard let center = zoomState.currentCenter?() else { return }
        zoomByPhoto[id] = (zoom, center)
        savePhotoZooms()
    }

    /// Stored as [asset id: [kind (0 Fit, 1 Fill, 2 percent), percent, center x, center y, time]],
    /// with -1 for no center.
    private func savePhotoZooms() {
        var stored = UserDefaults.standard.dictionary(forKey: Self.photoZoomsKey) as? [String: [Double]] ?? [:]
        let now = Date().timeIntervalSinceReferenceDate
        for (id, entry) in zoomByPhoto {
            var kind = 0.0, percent = 0.0
            switch entry.level {
            case .fit: break
            case .fill: kind = 1
            case .percent(let value): kind = 2; percent = value
            }
            var row: [Double] = [kind, percent, -1, -1]
            if let center = entry.center {
                row[2] = Double(center.x)
                row[3] = Double(center.y)
            }
            if let old = stored[String(id)], Array(old.prefix(4)) == row { continue }
            stored[String(id)] = row + [now]
        }
        if stored.count > Self.photoZoomsLimit {
            let oldest = stored.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }
                .prefix(stored.count - Self.photoZoomsLimit).map(\.key)
            for key in oldest {
                stored[key] = nil
                if let id = Int64(key) { zoomByPhoto[id] = nil }
            }
        }
        UserDefaults.standard.set(stored, forKey: Self.photoZoomsKey)
    }

    nonisolated private static func loadPhotoZooms() -> [Int64: (level: ZoomLevel, center: CGPoint?)] {
        guard let stored = UserDefaults.standard.dictionary(forKey: photoZoomsKey) as? [String: [Double]] else { return [:] }
        var zooms: [Int64: (level: ZoomLevel, center: CGPoint?)] = [:]
        for (key, row) in stored {
            guard let id = Int64(key), row.count >= 4 else { continue }
            let level: ZoomLevel = row[0] == 1 ? .fill : row[0] == 2 && row[1] > 0 ? .percent(row[1]) : .fit
            let center = row[2] >= 0 && row[3] >= 0 ? CGPoint(x: row[2], y: row[3]) : nil
            zooms[id] = (level, center)
        }
        return zooms
    }

    /// Settings > Develop: the zoom a double-click or Z goes to (Lightroom's 1:1 by default).
    nonisolated static var clickZoomPercent: Double {
        ZoomLevel.clickZoomPercent
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
        if perform({ try $0.removeAssets(self.pairTargetIDs, fromCollection: id) }) { DeleteFeedback.play(.remove) }
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
        if perform({ try $0.removeAssets(self.pairTargetIDs, fromImportGroup: id) }) { DeleteFeedback.play(.remove) }
    }

    func renameImportGroup(_ id: Int64, to name: String) {
        perform { try $0.renameImportGroup(id, to: name) }
    }

    /// Deletes the entry; its photos stay in All Photographs and their folders.
    func deleteImportGroup(_ id: Int64) {
        if sidebarSelection == .importGroup(id) { sidebarSelection = .all }
        if perform({ try $0.deleteImportGroup(id) }) { DeleteFeedback.play(.remove) }
    }

    func deleteCollection(_ id: Int64) {
        if sidebarSelection == .collection(id) { sidebarSelection = .all }
        if perform({ try $0.deleteCollection(id) }) { DeleteFeedback.play(.remove) }
    }

    /// Whether the edit was made.
    @discardableResult
    private func perform(_ edit: (Catalog) throws -> Void) -> Bool {
        do {
            try edit(catalog)
            reloadDetail()
            if UserDefaults.standard.bool(forKey: "xmp.autoWrite") { autoWriteXMP(pairTargetIDs) }
            return true
        } catch {
            status = error.localizedDescription
            return false
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
            do {
                let result = try catalog.writeXMPSidecars(for: ids)
                await MainActor.run {
                    self.reloadDetail()
                    if let failure = result.failures.first {
                        self.status = "XMP write failed: \(failure.url.lastPathComponent): \(failure.reason)"
                    }
                }
            } catch {
                await MainActor.run { self.status = "XMP write failed: \(error.localizedDescription)" }
            }
        }
    }

    func writeXMP(selectionOnly: Bool) {
        develop.flushSave()
        let ids: [Int64]? = selectionOnly ? targetIDs : nil
        let catalog = self.catalog
        status = "Writing XMP…"
        Task.detached {
            let message: String
            let failures: [ImportFailure]
            do {
                let result = try catalog.writeXMPSidecars(for: ids)
                var parts = ["Wrote \(result.written) XMP sidecar\(result.written == 1 ? "" : "s")"]
                if result.offline > 0 { parts.append("\(result.offline) waiting for offline volumes") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
                message = parts.joined(separator: ", ")
                failures = result.failures
            } catch {
                message = "XMP write failed: \(error.localizedDescription)"
                failures = []
            }
            await MainActor.run {
                self.status = message
                if !failures.isEmpty {
                    self.problems = failures.map { Problem(name: $0.url.lastPathComponent, reason: $0.reason) }
                    self.problemsTitle = "These XMP sidecars could not be written"
                }
            }
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

    /// `then` runs on the main actor with the result, before the status is set. The import
    /// entry is selected when every file is cataloged, and thumbnails are made after that.
    /// A `stager` hands over what it copied ahead while the user culled.
    func runImport(sources: [URL], options: ImportOptions, stager: ImportStager? = nil,
                   then: ((ImportProgress) -> Void)? = nil) {
        let importer = Importer(catalog: catalog, previews: nil, scheduler: previewScheduler)
        let copying: Bool
        if case .copy = options.mode { copying = true } else { copying = false }
        importProgress = ImportStatus(phase: "Looking for photos…", fraction: nil)
        let meter = ImportMeter()
        importTask = Task.detached {
            let result = await importer.run(sources: sources, options: options, stager: stager) { progress in
                // Called on the import's own loop after every file: keep it cheap, and update
                // the dialog a few times a second rather than per file.
                guard let status = meter.status(for: progress, copying: copying) else { return }
                Task { @MainActor in
                    if self.importTask != nil, !self.importWasCancelled { self.importProgress = status }
                }
            }
            await MainActor.run {
                var parts = ["Imported \(result.imported) photo\(result.imported == 1 ? "" : "s")"]
                if result.skipped > 0 { parts.append("\(result.skipped) already in the catalog") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) could not be read") }
                if Task.isCancelled || self.importWasCancelled { parts.insert("Import cancelled", at: 0) }
                self.status = parts.joined(separator: ", ")
                if let groupID = result.importGroupId {
                    // Showing only private photos: an ordinary import would open empty.
                    if self.filter.privacy == .only,
                       (try? self.catalog.writer.read({ try ImportGroup.fetchOne($0, key: groupID) }))?.isPrivate != true {
                        self.privatePhotos.choose(.shown)
                    }
                    self.sidebarSelection = .importGroup(groupID)
                }
                if UserDefaults.standard.bool(forKey: "xmp.autoWrite") {
                    self.autoWriteXMP(result.developedAssetIDs)
                }
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

    /// "Copying 23 of 400 photos" for the status bar, with the figures the Import dialog shows.
    nonisolated static func importStatus(_ progress: ImportProgress, copying: Bool, speed: Double?,
                                         doneFiles: Set<String> = []) -> ImportStatus {
        let verb = copying ? "Copying" : "Adding"
        let shown = min(progress.processed + 1, progress.total)
        var status = ImportStatus(phase: progress.total == 0 ? "Looking for photos…"
                                    : "\(verb) \(shown) of \(progress.total) photo\(progress.total == 1 ? "" : "s")",
                                  fraction: progress.totalBytes > 0
                                    ? Double(progress.bytesDone) / Double(progress.totalBytes)
                                    : Double(progress.processed) / Double(max(progress.total, 1)))
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        status.done = progress.processed
        status.doneFiles = doneFiles
        status.total = progress.total
        status.amount = "\(bytes.string(fromByteCount: progress.bytesDone)) of \(bytes.string(fromByteCount: progress.totalBytes))"
        status.file = progress.currentFile?.lastPathComponent
        // Speed and time left once there is enough to go on.
        if progress.bytesDone > 0, let speed, speed > 0 {
            status.speed = "\(bytes.string(fromByteCount: Int64(speed)))/s"
            let left = Double(progress.totalBytes - progress.bytesDone) / speed
            let time = DateComponentsFormatter()
            time.unitsStyle = .full
            time.maximumUnitCount = 1
            time.allowedUnits = left < 60 ? [.second] : [.hour, .minute]
            status.timeLeft = left < 1 ? "Almost done" : time.string(from: left.rounded(.up)).map { "About \($0)" }
        }
        return status
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

    /// Decodes the previews of the photos before and after the focused one, in Loupe and
    /// Develop, so the arrow keys show them at once. A missing preview (for the focused photo
    /// too) is queued to be built, so the next visit shows it sharp instead of the thumbnail.
    private func prefetchNeighbourPreviews() {
        guard mode == .loupe || mode == .develop, let focusedID,
              let index = rows.firstIndex(where: { $0.id == focusedID }) else { return }
        let ids = [index + 1, index - 1].filter { rows.indices.contains($0) }.map { rows[$0].id }
        var ready: [(id: Int64, url: URL)] = []
        for id in [focusedID] + ids {
            if previews.has(.preview, for: id) {
                if id != focusedID { ready.append((id: id, url: previews.url(for: id, size: .preview))) }
            } else if let source = try? catalog.fileURL(for: id) {
                previewScheduler.request(.preview, for: id, source: source, settings: try? catalog.developSettings(for: id))
            }
        }
        PreviewImages.shared.prefetch(ready)
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

    // MARK: Window input

    private func installInputMonitor() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                switch event.type {
                case .keyDown:
                    let handled = self.handleKey(event)
                    self.lastKeyWasTab = !handled && event.keyCode == 48
                    return handled ? nil : event
                case .leftMouseDown where event.window === self.mainWindow:
                    self.lastClick = event.locationInWindow
                    self.chosenTextField = nil
                    if self.mode == .develop {
                        self.develop.beginPointerEdit()
                        // After the click reaches the view, so a control it lands on takes focus first.
                        if let content = event.window?.contentView {
                            let local = content.convert(event.locationInWindow, from: nil)
                            let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
                            DispatchQueue.main.async { KeyboardFocus.shared.clicked(at: point) }
                        }
                    }
                case .leftMouseUp:
                    // Let the control consume mouse-up and apply its final value first.
                    DispatchQueue.main.async { [weak self] in self?.develop.endPointerEdit() }
                default:
                    break
                }
                return event
            }
        }
    }

    /// Lightroom-style culling keys. Ignored while typing in a text field or a sheet is open.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        // Only the library window; never Settings or other windows.
        guard let window = NSApp.keyWindow, window === mainWindow, window.attachedSheet == nil else { return false }
        // ⌃Tab moves between areas from anywhere in Develop, even from a text field (the Mac's
        // own ⌃Tab leaves a text field), so it never gets stuck.
        if mode == .develop, let action = KeyBindings.action(for: event),
           action == .nextArea || action == .previousArea {
            return perform(action)
        }
        // Tab and ⇧Tab stay in the focused area, text fields included (Search Presets is a stop
        // in Presets), instead of the window's Tab order, which hopped between the Presets and
        // Library search fields (Rosh, Nov 9, 2026).
        if mode == .develop, event.keyCode == 48, event.modifierFlags.intersection([.control, .option]).isEmpty {
            KeyboardFocus.shared.step(forward: !event.modifierFlags.contains(.shift))
            return true
        }
        if let text = window.firstResponder as? NSText {
            // A field that is a Tab stop (Search Presets) types; Esc leaves it for the photos.
            if mode == .develop, KeyboardFocus.shared.currentIsText {
                if event.keyCode == 53 {
                    KeyboardFocus.shared.release()
                    return true
                }
                return false
            }
            if userIsTyping(in: text) {
                // Typing in a field: it keeps the keys, and no control keeps the focus mark.
                KeyboardFocus.shared.release(endEditing: false)
                return false
            }
            window.makeFirstResponder(nil)
        }
        // ⌃ and ⌥ presses run only a command bound to them in Settings > Keyboard (⌃Tab).
        if !event.modifierFlags.intersection([.control, .option]).isEmpty {
            guard let action = KeyBindings.action(for: event) else { return false }
            return perform(action)
        }

        if mode == .develop, develop.picker != nil, event.keyCode == 53 {  // escape puts any color picker away
            develop.picker = nil
            return true
        }
        // A focused slider or the Presets list takes the arrows, Return, Space and Esc (Esc then
        // gives them back to the photos).
        if mode == .develop, KeyboardFocus.shared.current != nil {
            let shift = event.modifierFlags.contains(.shift)
            let key: KeyboardFocus.Key?
            switch event.keyCode {
            case 123: key = .left
            case 124: key = .right
            case 125: key = .down
            case 126: key = .up
            case 36, 76: key = .enter
            case 49: key = .space
            case 53: key = .escape
            default: key = nil
            }
            if let key {
                // Arrows never fall through to changing photos while a control has focus.
                let handled = KeyboardFocus.shared.handle(KeyboardFocus.Press(key: key, shift: shift))
                if handled || [.left, .right, .up, .down].contains(key) { return true }
            }
        }
        // Arrow keys over a Color Grading wheel nudge it (Shift for bigger steps) instead of
        // changing photos.
        if mode == .develop, let region = develop.hoveredGradeRegion, (123...126).contains(event.keyCode) {
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            switch event.keyCode {
            case 123: develop.nudgeGrade(region, hue: -step, saturation: 0)   // left
            case 124: develop.nudgeGrade(region, hue: step, saturation: 0)    // right
            case 125: develop.nudgeGrade(region, hue: 0, saturation: -step)   // down
            default: develop.nudgeGrade(region, hue: 0, saturation: step)     // up
            }
            return true
        }
        // Arrow keys over the point curve nudge its selected point, as in Lightroom.
        if mode == .develop, develop.hoveredCurvePoint != nil, (123...126).contains(event.keyCode) {
            let large = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 123: develop.nudgeCurvePoint(dx: -1, dy: 0, large: large)   // left
            case 124: develop.nudgeCurvePoint(dx: 1, dy: 0, large: large)    // right
            case 125: develop.nudgeCurvePoint(dx: 0, dy: -1, large: large)   // down
            default: develop.nudgeCurvePoint(dx: 0, dy: 1, large: large)     // up
            }
            return true
        }
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

        guard let action = KeyBindings.action(for: event) else { return false }
        return perform(action)
    }

    /// Whether the text field with the keyboard is one the user is typing in: they clicked or
    /// tabbed into it, or it has text. An empty field nobody chose (SwiftUI's automatic pick)
    /// gives the keys back.
    private func userIsTyping(in text: NSText) -> Bool {
        let field = ((text as? NSTextView)?.delegate as? NSView) ?? text
        if field === chosenTextField || lastKeyWasTab || !text.string.isEmpty {
            chosenTextField = field
            return true
        }
        if let click = lastClick, field.window != nil, field.bounds.contains(field.convert(click, from: nil)) {
            chosenTextField = field
            return true
        }
        return false
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
        case .clipping:
            guard mode == .develop, develop.assetID != nil else { return false }
            develop.toggleClippingOverlay()
        case .treatment:
            guard mode == .develop, develop.assetID != nil else { return false }
            develop.setMonochrome(!develop.settings.monochrome)
        case .whiteBalance:
            if mode != .develop { openDevelop() }
            guard mode == .develop, develop.assetID != nil else { return false }
            develop.isPickingWhiteBalance.toggle()
        case .masking:
            if mode != .develop { openDevelop() }
            guard mode == .develop else { return false }
            develop.isMasking.toggle()
        case .radialGradient:
            if mode != .develop { openDevelop() }
            guard mode == .develop else { return false }
            develop.startMaskTool(.radial)
        case .guidedUpright:
            guard mode == .develop else { return false }
            if develop.isGuiding { develop.isGuiding = false } else { develop.setUpright(.guided) }
        case .nextArea, .previousArea:
            guard mode == .develop else { return false }
            KeyboardFocus.shared.cycle(forward: action == .nextArea)
        }
        return true
    }

    /// Guided Upright, as in Lightroom (⇧T, a `KeyAction`, opens it): O shows or hides the loupe, Delete removes
    /// the selected guide, Esc closes it.
    private func handleTransformKey(_ event: NSEvent) -> Bool {
        guard develop.isGuiding else { return false }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "o" {
            let key = GuidedUprightView.loupeKey
            UserDefaults.standard.set(!(UserDefaults.standard.object(forKey: key) as? Bool ?? true), forKey: key)
            return true
        }
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

    /// Lightroom's Masking keys (⇧W and ⇧M are `KeyAction`s): [ and ] size the brush
    /// (with ⇧, its feather), Delete removes the selected part, Esc cancels the tool or closes.
    private func handleMaskingKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
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
