import Foundation

/// Where Rosh left off, saved as they work and restored at the next launch, as in Lightroom:
/// the view, the sidebar item and filter, the selected photos, the zoom and the grid's scroll position.
public struct SavedSession: Codable, Equatable, Sendable {
    public enum Module: String, Codable, Sendable {
        case grid, loupe, develop
    }

    public enum Zoom: Codable, Equatable, Sendable {
        case fit, fill
        case percent(Double)
    }

    /// More selected photos than this saves only the focused one, to keep the preference small.
    public static let maxSavedSelection = 1000

    public var module: Module = .grid
    public var scope: LibraryScope = .all
    public var minRating = 0
    public var flag: Flag?
    public var colorLabel: ColorLabel?
    public var text = ""
    public var selection: [Int64] = []
    public var focusedID: Int64?
    public var zoom: Zoom = .fit
    /// The photo at the top of the grid.
    public var gridTopID: Int64?

    public init(module: Module = .grid, filter: LibraryFilter = LibraryFilter(), selection: Set<Int64> = [],
                focusedID: Int64? = nil, zoom: Zoom = .fit, gridTopID: Int64? = nil) {
        self.module = module
        scope = filter.scope
        minRating = filter.minRating
        flag = filter.flag
        colorLabel = filter.colorLabel
        text = filter.text
        self.selection = selection.count <= Self.maxSavedSelection ? selection.sorted() : focusedID.map { [$0] } ?? []
        self.focusedID = focusedID
        self.zoom = zoom
        self.gridTopID = gridTopID
    }

    /// The saved filter on top of `base`, which keeps settings that are not part of a session
    /// (whether RAW+JPEG pairs are grouped).
    public func filter(base: LibraryFilter) -> LibraryFilter {
        var filter = base
        filter.scope = scope
        filter.minRating = minRating
        filter.flag = flag
        filter.colorLabel = colorLabel
        filter.text = text
        return filter
    }

    /// The saved sidebar item if it still exists, otherwise All Photographs.
    public static func resolveScope(_ scope: LibraryScope, in sidebar: (volumes: [Int64], folders: [Int64],
                                                                       collections: [Int64], imports: [Int64])) -> LibraryScope {
        switch scope {
        case .all: return .all
        case .volume(let id): return sidebar.volumes.contains(id) ? scope : .all
        case .folder(let id): return sidebar.folders.contains(id) ? scope : .all
        case .collection(let id): return sidebar.collections.contains(id) ? scope : .all
        case .importGroup(let id): return sidebar.imports.contains(id) ? scope : .all
        }
    }

    /// What to show once the restored scope's photos have loaded.
    public struct Restored: Equatable, Sendable {
        public var module: Module
        public var selection: Set<Int64>
        public var focusedID: Int64?
    }

    /// Keeps only photos still in the grid. Loupe and Develop need the focused photo's file;
    /// when it is gone or its drive is offline, the grid opens instead with the photo still selected.
    public func restore(visibleIDs: Set<Int64>, isFileAvailable: (Int64) -> Bool) -> Restored {
        let focused = focusedID.flatMap { visibleIDs.contains($0) ? $0 : nil }
        var selection = Set(self.selection).intersection(visibleIDs)
        if let focused { selection.insert(focused) }
        var module = self.module
        if module != .grid, focused.map(isFileAvailable) != true { module = .grid }
        return Restored(module: module, selection: selection, focusedID: focused)
    }

    public static func load(from defaults: UserDefaults, key: String) -> SavedSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    public func save(to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
