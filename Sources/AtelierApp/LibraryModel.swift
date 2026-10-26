import AppKit
import AtelierCore
import Foundation
import GRDB

enum ViewMode {
    case grid
    case loupe
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

    @Published var rows: [AssetRow] = []
    @Published var sidebar = SidebarData()
    @Published var sidebarSelection: SidebarItem? = .all {
        didSet { filter.scope = sidebarSelection?.scope ?? .all }
    }
    @Published var filter = LibraryFilter() {
        didSet { if filter != oldValue { observeRows() } }
    }
    @Published var selection: Set<Int64> = []
    @Published var focusedID: Int64? {
        didSet { if focusedID != oldValue { reloadDetail() } }
    }
    @Published var detail: AssetDetail?
    @Published var mode: ViewMode = .grid
    @Published var status: String?
    @Published var showingImportSheet = false
    @Published var pendingImportSources: [URL] = []
    /// Import entry preselected in the import sheet, when importing more into an existing one.
    @Published var pendingImportGroup: Int64?
    @Published var importProgress: ImportStatus?
    /// Files the last import could not read, shown on request from the status bar.
    @Published var importFailures: [ImportFailure] = []
    private var importTask: Task<Void, Never>?
    private var importWasCancelled = false
    private var shownImportGroup: Int64?
    /// Bumped when previews are generated so visible cells reload their images.
    @Published var previewRevision = 0

    private var rowsTask: Task<Void, Never>?
    private var sidebarTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var previewRequests = Set<Int64>()

    init() {
        let packageURL = Catalog.defaultPackageURL
        do {
            catalog = try Catalog(packageURL: packageURL)
        } catch {
            fatalError("Could not open the catalog at \(packageURL.path): \(error)")
        }
        previews = PreviewCache(rootURL: catalog.previewsURL!)
        try? catalog.refreshVolumes()
        observeRows()
        observeSidebar()
        installKeyMonitor()
        observeMounts()
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
                    guard let self else { return }
                    self.rows = rows
                    let visible = Set(rows.map(\.id))
                    self.selection.formIntersection(visible)
                    if let focused = self.focusedID, !visible.contains(focused) {
                        self.focusedID = rows.first?.id
                    }
                    self.reloadDetail()
                }
            } catch {
                self?.status = "Catalog error: \(error.localizedDescription)"
            }
        }
    }

    private func observeSidebar() {
        let observation = ValueObservation.tracking { db in
            SidebarData(
                volumes: try Volume.order(Column("name")).fetchAll(db),
                folders: try Folder.order(Column("relativePath")).fetchAll(db),
                collections: try PhotoCollection.order(Column("name")).fetchAll(db),
                imports: try Catalog.fetchImportGroupSummaries(db),
                totalCount: try Asset.fetchCount(db))
        }
        let writer = catalog.writer
        sidebarTask = Task { [weak self] in
            do {
                for try await data in observation.values(in: writer) {
                    self?.sidebar = data
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
    }

    // MARK: Selection

    /// Photos that an edit applies to: the loupe photo, or the grid selection.
    var targetIDs: [Int64] {
        if mode == .loupe || selection.isEmpty {
            return focusedID.map { [$0] } ?? []
        }
        return Array(selection)
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

    func setRating(_ rating: Int) { perform { try $0.setRating(rating, for: self.targetIDs) } }
    func setFlag(_ flag: Flag) { perform { try $0.setFlag(flag, for: self.targetIDs) } }
    func toggleLabel(_ label: ColorLabel) { perform { try $0.toggleColorLabel(label, for: self.targetIDs) } }

    func setKeywords(_ text: String) {
        let names = text.split(separator: ",").map(String.init)
        perform { try $0.setKeywords(names, for: self.targetIDs) }
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
                try catalog.addAssets(self.targetIDs, toCollection: id)
            }
        }
    }

    func addSelection(toCollection id: Int64) {
        perform { try $0.addAssets(self.targetIDs, toCollection: id) }
    }

    func removeSelectionFromCurrentCollection() {
        guard case .collection(let id) = sidebarSelection else { return }
        perform { try $0.removeAssets(self.targetIDs, fromCollection: id) }
    }

    func renameCollection(_ id: Int64, to name: String) {
        perform { try $0.renameCollection(id, to: name) }
    }

    // MARK: Import entries

    func addSelection(toImportGroup id: Int64) {
        perform { try $0.addAssets(self.targetIDs, toImportGroup: id) }
    }

    func removeSelectionFromCurrentImport() {
        guard case .importGroup(let id) = sidebarSelection else { return }
        perform { try $0.removeAssets(self.targetIDs, fromImportGroup: id) }
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
        } catch {
            status = error.localizedDescription
        }
    }

    func refreshVolumes() {
        perform { try $0.refreshVolumes() }
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

    func runImport(sources: [URL], options: ImportOptions) {
        let importer = Importer(catalog: catalog, previews: previews)
        importProgress = ImportStatus(phase: "Scanning…", fraction: nil)
        shownImportGroup = nil
        importTask = Task.detached {
            let result = await importer.run(sources: sources, options: options) { progress in
                let phase: String
                let fraction: Double?
                if progress.processed < progress.total {
                    phase = "Importing \(progress.processed + 1) of \(progress.total)"
                    fraction = Double(progress.processed) / Double(max(progress.total, 1))
                } else {
                    phase = "Building previews \(progress.previewsBuilt) of \(progress.imported)"
                    fraction = Double(progress.previewsBuilt) / Double(max(progress.imported, 1))
                }
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
                    self.previewRevision += 1
                }
            }
            await MainActor.run {
                var parts = ["Imported \(result.imported) photo\(result.imported == 1 ? "" : "s")"]
                if result.skipped > 0 { parts.append("\(result.skipped) already in the catalog") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) could not be read") }
                if Task.isCancelled || self.importWasCancelled { parts.insert("Import cancelled", at: 0) }
                self.status = parts.joined(separator: ", ")
                self.importFailures = result.failures
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

    // MARK: Previews

    func thumbnailURL(for id: Int64, size: PreviewCache.Size = .thumbnail) -> URL? {
        let url = previews.url(for: id, size: size)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        requestPreview(for: id)
        return nil
    }

    /// Generates missing previews on demand, for example after the cache was cleared.
    func requestPreview(for id: Int64) {
        guard !previewRequests.contains(id), let url = try? catalog.fileURL(for: id) else { return }
        previewRequests.insert(id)
        let previews = self.previews
        Task.detached(priority: .utility) {
            try? previews.generate(for: id, from: url)
            await MainActor.run {
                self.previewRequests.remove(id)
                self.previewRevision += 1
            }
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
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }

        switch event.keyCode {
        case 123 where mode == .loupe: step(-1); return true          // left arrow
        case 124 where mode == .loupe: step(1); return true           // right arrow
        case 36, 76:                                                   // return, enter
            if mode == .loupe { mode = .grid } else { openLoupe() }
            return true
        case 53 where mode == .loupe: mode = .grid; return true       // escape
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "0": setRating(0)
        case "1": setRating(1)
        case "2": setRating(2)
        case "3": setRating(3)
        case "4": setRating(4)
        case "5": setRating(5)
        case "6": toggleLabel(.red)
        case "7": toggleLabel(.yellow)
        case "8": toggleLabel(.green)
        case "9": toggleLabel(.blue)
        case "p": setFlag(.picked)
        case "x": setFlag(.rejected)
        case "u": setFlag(.none)
        case "e": openLoupe()
        case "g": mode = .grid
        default: return false
        }
        return true
    }
}
