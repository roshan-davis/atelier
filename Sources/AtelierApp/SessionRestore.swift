import AppKit
import AtelierCore
import Combine
import Foundation

/// Reopens Atelier where Rosh left it: the same view, sidebar item, filter, photo, zoom and grid
/// scroll position, as Lightroom does. See "Restore last session" in the PRD.
extension LibraryModel {
    static let sessionKey = "session.last"

    /// Off while CI renders layout snapshots, so a run neither starts from nor leaves behind a session.
    private static var restoresSession: Bool { LayoutSnapshots.outputFolder == nil }

    /// Called from init, before rows are first observed: puts back the sidebar item and filter.
    func restoreSessionFilter() {
        guard Self.restoresSession else { return }
        if let saved = SavedSession.load(from: .standard, key: Self.sessionKey) {
            pendingSession = saved
            pendingSessionScope = true
            filter = saved.filter(base: filter)
            sidebarSelection = SidebarItem(saved.scope)
            zoom = ZoomLevel(saved.zoom)
            gridTopID = saved.gridTopID
        }
        // Save shortly after anything changes. A throttle rather than a debounce, so a long import's
        // stream of progress updates can't hold the save off; stopping in Xcode skips willTerminate.
        sessionObserver = objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSessionSave() }
        }
    }

    /// The first sidebar data: falls back to All Photographs if the saved import, collection,
    /// folder or volume has since been deleted.
    func checkRestoredScope(_ data: SidebarData) {
        guard pendingSessionScope else { return }
        pendingSessionScope = false
        let scope = SavedSession.resolveScope(filter.scope, in: (
            volumes: data.volumes.compactMap(\.id), folders: data.folders.compactMap(\.id),
            collections: data.collections.compactMap(\.id), imports: data.imports.map(\.id)))
        if scope != filter.scope {
            sidebarSelection = SidebarItem(scope)
        } else if loadedRowsFilter == filter {
            finishSessionRestore(visible: Set(rows.map(\.id)))
        }
    }

    /// The restored scope's photos have loaded: select the saved photos and open the saved view.
    func finishSessionRestore(visible: Set<Int64>) {
        guard let saved = pendingSession else { return }
        pendingSession = nil
        let restored = saved.restore(visibleIDs: visible) { [catalog] id in
            guard let url = (try? catalog.detail(for: id))?.fileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        selection = restored.selection
        focusedID = restored.focusedID
        switch restored.module {
        case .grid: mode = .grid
        case .loupe: mode = .loupe
        case .develop: mode = .develop
        }
        if restored.module != saved.module, let name = detail?.asset.filename {
            status = "\(name) is missing or its drive is offline, so the grid is shown"
        }
    }

    /// Called by the grid as it scrolls.
    func gridScrolled(toTop id: Int64) {
        guard gridTopID != id else { return }
        gridTopID = id
        scheduleSessionSave()
    }

    func scheduleSessionSave() {
        guard Self.restoresSession, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.sessionSaveScheduled = false
            self?.saveSession()
        }
    }

    /// Also called as the app quits.
    func saveSession() {
        // Until last launch's session has been applied, the state here is only half restored.
        guard Self.restoresSession, pendingSession == nil else { return }
        let module: SavedSession.Module = switch mode {
        case .grid: .grid
        case .loupe: .loupe
        case .develop: .develop
        }
        SavedSession(module: module, filter: filter, selection: selection, focusedID: focusedID,
                     zoom: SavedSession.Zoom(zoom), gridTopID: gridTopID)
            .save(to: .standard, key: Self.sessionKey)
    }
}

extension SidebarItem {
    init(_ scope: LibraryScope) {
        switch scope {
        case .all: self = .all
        case .volume(let id): self = .volume(id)
        case .folder(let id): self = .folder(id)
        case .collection(let id): self = .collection(id)
        case .importGroup(let id): self = .importGroup(id)
        }
    }
}

extension ZoomLevel {
    init(_ zoom: SavedSession.Zoom) {
        switch zoom {
        case .fit: self = .fit
        case .fill: self = .fill
        case .percent(let value): self = .percent(value)
        }
    }
}

extension SavedSession.Zoom {
    init(_ zoom: ZoomLevel) {
        switch zoom {
        case .fit: self = .fit
        case .fill: self = .fill
        case .percent(let value): self = .percent(value)
        }
    }
}
