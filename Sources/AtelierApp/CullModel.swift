import AppKit
import Combine
import AtelierCore
import Foundation

/// One photo in the Cull view.
struct CullPhoto: Identifiable {
    let id: Int
    let url: URL?
    let assetID: Int64?
    let name: String
    let captureTime: Date?
    /// Files shot with this RAW (its JPEG, HEIC…), culled along with it.
    var siblings: [URL] = []
    var siblingIDs: [Int64] = []
    /// The siblings' extensions, such as ["JPG"].
    var pairFormats: [String] = []
    var signals: CullSignals?
    var thumbnail: NSImage?

    /// "RAW+JPG" when the RAW has siblings.
    var pairBadge: String? { pairFormats.isEmpty ? nil : "RAW+" + pairFormats.joined(separator: "+") }

    func renumbered(_ id: Int) -> CullPhoto {
        CullPhoto(id: id, url: url, assetID: assetID, name: name, captureTime: captureTime, siblings: siblings,
                  siblingIDs: siblingIDs, pairFormats: pairFormats, signals: signals, thumbnail: thumbnail)
    }
}

/// Asks the group list to scroll a photo into view. Only keyboard moves do; a click leaves the
/// list where the user put it.
struct CullReveal: Equatable {
    let id: Int
    let serial: Int
}

/// The Cull view's state: photos grouped into similar shots and which ones are kept.
@MainActor
final class CullModel: ObservableObject, Identifiable {
    enum Source {
        /// Folders and files chosen in the Import dialog, not cataloged yet.
        case importing(sources: [URL], options: ImportOptions)
        /// Cataloged photos: an import entry, or one saved cull group under review.
        case photos([Int64], isReview: Bool)
    }

    let source: Source
    let title: String
    @Published private(set) var photos: [CullPhoto] = []
    @Published private(set) var groups: [[Int]] = []
    @Published private(set) var suggested: Set<Int> = []
    @Published var kept: Set<Int> = []
    @Published var focused: Int?
    @Published private(set) var reveal: CullReveal?
    /// Finding the photos and reading their capture times, before analysis.
    @Published private(set) var isLoading = true
    /// While loading: photos found (nil while the folders are still being listed) and how many
    /// have had their capture time read.
    @Published private(set) var found: Int?
    @Published private(set) var read = 0
    /// When analysis started, for the time left.
    @Published private(set) var analysisStarted: Date?
    @Published private(set) var analyzed = 0
    @Published private(set) var isAnalyzing = true
    /// 0 is tight (only near-identical shots), 1 is loose. Every cull starts tight, so shots that
    /// only look alike are never hidden in a group unless the user loosens it (Rosh, Oct 30, 2026).
    @Published var looseness = 0.0 {
        didSet { if abs(looseness - oldValue) > 0.001, !isAnalyzing { regroup() } }
    }
    /// Same frame only, or similar shots too; remembered between culls.
    @Published var mode: CullMode = CullMode(rawValue: UserDefaults.standard.string(forKey: CullModel.modeKey) ?? "")
        ?? .similarShots {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode != oldValue, !isAnalyzing { regroup() }
        }
    }
    static let modeKey = "cull.mode"
    /// How the suggested keeper of each group is picked; remembered between culls. Changing it
    /// suggests again (as the Grouping slider does), without analyzing again.
    @Published var pickBy: CullPick = CullPick(rawValue: UserDefaults.standard.string(forKey: CullModel.pickKey) ?? "")
        ?? .balanced {
        didSet {
            UserDefaults.standard.set(pickBy.rawValue, forKey: Self.pickKey)
            // Best Expression reads expressions, which only the Advanced checks do; regrouping
            // again when they finish picks with them.
            if pickBy.needsAdvanced, !advanced { advanced = true }
            if pickBy != oldValue, !isAnalyzing { regroup() }
        }
    }
    static let pickKey = "cull.pickBy"
    /// Which face finder Cull uses: Apple Vision, MediaPipe or both (the default); remembered.
    /// Every photo is read with each finder, so switching only picks again (AT-061).
    @Published var faceFinder: CullFaceFinder = CullFaceFinder(rawValue: UserDefaults.standard.string(forKey: CullModel.finderKey) ?? "")
        ?? .both {
        didSet {
            guard faceFinder != oldValue else { return }
            UserDefaults.standard.set(faceFinder.rawValue, forKey: Self.finderKey)
            guard !isAnalyzing else { return }
            // The other finder's faces haven't had the Advanced checks: read them again.
            stopAdvanced()
            useFaceFinder()
            regroup(keepingChoices: true)
            if advanced { runAdvanced() }
        }
    }
    static let finderKey = "cull.faceFinder"
    /// Advanced checks (slower): each grouped photo's eyes read again from a large copy, and
    /// blinks and smiles read with MediaPipe Face Landmarker.
    /// Off by default, remembered.
    @Published var advanced = UserDefaults.standard.bool(forKey: CullModel.advancedKey) {
        didSet {
            guard advanced != oldValue else { return }
            UserDefaults.standard.set(advanced, forKey: Self.advancedKey)
            if advanced { runAdvanced() } else { stopAdvanced() }
        }
    }
    static let advancedKey = "cull.advanced"
    /// Advanced checks' progress: photos done and to do; nil when not running.
    @Published private(set) var advancedProgress: (done: Int, total: Int)?
    /// Write each dropped photo's reasons to its notes when the cull ends (AT-058); on by
    /// default, remembered.
    @Published var writeReasons = UserDefaults.standard.object(forKey: CullModel.reasonsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(writeReasons, forKey: Self.reasonsKey) }
    }
    static let reasonsKey = "cull.writeReasons"
    /// Each photo measured against its group (key: photo id), for the caption and the notes.
    @Published private(set) var assessments: [Int: CullAssessment] = [:]
    private var advancedTask: Task<Void, Never>?
    /// The person kept or dropped something since the keepers were last suggested.
    private var choicesChanged = false
    /// Measurements between each photo and the next (key: the first's id), made after analysis.
    private var neighbors: [Int: CullComparison] = [:]
    /// Measurements between a group's first shot and later ones, made as grouping needs them.
    private var distant: [Int: CullComparison] = [:]
    @Published private(set) var largeImage: NSImage?
    /// The photo `largeImage` is of (it can still be the last photo's while the next loads).
    private var largeImageID: Int?
    /// The photo the preview's picture (`fullImage ?? largeImage`) is of, for the photo view
    /// (`ZoomableImageView.imagePhotoID`).
    var shownPhotoID: Int64? { (fullImage != nil ? focused : largeImageID).map(Int64.init) }
    /// The focused photo at full size, read once it is zoomed past Fit; nil until then.
    @Published private(set) var fullImage: NSImage?
    /// The focused photo's size in pixels (as shot, turned upright), so 100% is one pixel per
    /// screen pixel whatever size the preview is.
    @Published private(set) var pixelSize: CGSize?
    /// Changing photo: the last one stays, at its zoom, until the next one's picture for the
    /// view is in (its 1800 px copy at Fit, its full size zoomed in), then it goes on once, not
    /// its thumbnail and then the larger picture (the shared rule, `PhotoChangeHold`).
    let photoHold = PhotoChangeHold(limit: 1.0)
    private var holdObserver: AnyCancellable?
    /// The Cull preview's zoom, its own: zooming here doesn't move Loupe or Develop. Kept from
    /// photo to photo, so the same spot can be compared across a group, as in Lightroom.
    let zoom = ZoomState()
    /// The note waiting for a click on the photo to be pinned there (the notes panel's Pin
    /// button); nil when none. Esc or another photo stops it.
    @Published var placingNote: Int64?
    /// The focused photo's notes, for the markers on the preview (the notes panel has its own).
    private(set) lazy var markerNotes: PhotoNotesModel? = catalog.map { PhotoNotesModel(catalog: $0) }
    /// Photo > Add Note… asks this view's notes panel for a new note (AT-058).
    @Published var noteRequest: NoteRequest?

    private weak var model: LibraryModel?
    /// Set when the Cull view is a step of the Import dialog: called with true after Import, with
    /// false after Cancel. Otherwise finishing or cancelling closes the Cull sheet.
    var onClose: ((Bool) -> Void)?
    /// Set in the Import dialog to show Back, which returns to the import settings.
    var onBack: (() -> Void)?
    /// In the Import dialog: copies the files to the library while the user culls, and how far
    /// it has got. Import takes over what it has done.
    var stager: ImportStager?
    @Published var ahead: ImportStager.Progress?
    private var loadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var largeTask: Task<Void, Never>?

    /// The catalog, for the notes panel.
    var catalog: Catalog? { model?.catalog }
    /// The focused photo in the catalog; nil while it is still being imported.
    var focusedAssetID: Int64? { focused.flatMap { photos.indices.contains($0) ? photos[$0].assetID : nil } }

    var isImporting: Bool { if case .importing = source { return true } else { return false } }
    var isReview: Bool { if case .photos(_, true) = source { return true } else { return false } }
    var multiGroups: [[Int]] { groups.filter { $0.count > 1 } }
    var singles: [Int] { groups.filter { $0.count == 1 }.flatMap { $0 } }

    init(source: Source, title: String, model: LibraryModel) {
        self.source = source
        self.title = title
        self.model = model
        // The photo view watches this model: tell it when a photo change's hold starts or ends.
        holdObserver = photoHold.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        load()
    }

    // MARK: Loading

    private func load() {
        guard let model else { return }
        switch source {
        case .importing(let sources, _):
            // Off the main thread: a card or the NAS can take a while to list and read.
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let files = Importer.collectFiles(from: sources)
                // A RAW and its JPEG are one frame: culled as the RAW, the decision applies to both.
                let pairs = FilePairs.pairs(files)
                await MainActor.run { [weak self] in self?.found = pairs.count }
                // Capture times, a few files at a time, reporting as each batch is done.
                var times = [Date?](repeating: nil, count: pairs.count)
                let batch = 24
                for start in stride(from: 0, to: pairs.count, by: batch) {
                    if Task.isCancelled { return }
                    let end = min(start + batch, pairs.count)
                    // Each photo's time goes to its own slot.
                    nonisolated(unsafe) let slice = UnsafeMutableBufferPointer<Date?>.allocate(capacity: end - start)
                    slice.initialize(repeating: nil)
                    DispatchQueue.concurrentPerform(iterations: end - start) { offset in
                        slice[offset] = MetadataReader.read(pairs[start + offset].primary).captureTime
                    }
                    for offset in 0..<(end - start) { times[start + offset] = slice[offset] }
                    slice.deallocate()
                    await MainActor.run { [weak self] in self?.read = end }
                }
                let photos = pairs.enumerated().map { index, pair in
                    CullPhoto(id: index, url: pair.primary, assetID: nil, name: pair.primary.lastPathComponent,
                              captureTime: times[index], siblings: pair.siblings,
                              pairFormats: pair.siblings.map { $0.pathExtension.uppercased() })
                }
                let ordered = CullModel.ordered(photos)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.loaded(ordered) }
            }
        case .photos(let ids, _):
            let photos = ids.enumerated().compactMap { index, id -> CullPhoto? in
                guard let detail = try? model.catalog.detail(for: id) else { return nil }
                let url = detail.fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? (model.previews.has(.preview, for: id) ? model.previews.url(for: id, size: .preview) : nil)
                let siblings = (try? model.catalog.pairSiblings(of: [id])) ?? []
                let formats = siblings.compactMap { try? model.catalog.detail(for: $0)?.asset.filename }
                    .map { ($0 as NSString).pathExtension.uppercased() }
                return CullPhoto(id: index, url: url, assetID: id, name: detail.asset.filename,
                                 captureTime: detail.asset.captureTime, siblingIDs: siblings, pairFormats: formats)
            }
            loaded(Self.ordered(photos))
        }
    }

    private func loaded(_ photos: [CullPhoto]) {
        self.photos = photos
        isLoading = false
        focused = photos.first?.id
        loadLarge()
        analyze()
    }

    /// Capture order, renumbered so ids are positions.
    nonisolated private static func ordered(_ photos: [CullPhoto]) -> [CullPhoto] {
        photos.sorted { ($0.captureTime ?? .distantFuture, $0.name) < ($1.captureTime ?? .distantFuture, $1.name) }
            .enumerated().map { index, photo in photo.renumbered(index) }
    }

    private func analyze() {
        analysisStarted = Date()
        let jobs = photos.map { ($0.id, $0.url) }
        let finder = faceFinder
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            await withTaskGroup(of: (Int, CullSignals).self) { group in
                var pending = jobs.makeIterator()
                for _ in 0..<workers {
                    guard let (id, url) = pending.next() else { break }
                    group.addTask { (id, await Self.analyze(url, finder)) }
                }
                for await (id, signals) in group {
                    if Task.isCancelled { return }
                    let thumbnail = signals.thumbnail.map { NSImage(cgImage: $0, size: .zero) }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.photos[id].signals = signals
                        self.photos[id].thumbnail = thumbnail
                        self.analyzed += 1
                    }
                    if let (nextID, url) = pending.next() {
                        group.addTask { (nextID, await Self.analyze(url, finder)) }
                    }
                }
            }
            // Each photo against the next, in parallel: lining shots up for a zoom is the slow part.
            let signals = await MainActor.run { [weak self] in self?.photos.map(\.signals) } ?? []
            guard !Task.isCancelled, signals.count > 1 else {
                await MainActor.run { [weak self] in self?.analysisFinished([:]) }
                return
            }
            // Each pair's comparison goes to its own slot.
            nonisolated(unsafe) let results = UnsafeMutableBufferPointer<CullComparison>.allocate(capacity: signals.count - 1)
            results.initialize(repeating: CullComparison())
            DispatchQueue.concurrentPerform(iterations: signals.count - 1) { index in
                guard let a = signals[index], let b = signals[index + 1] else { return }
                results[index] = Culling.compare(a, b)
            }
            var neighbors: [Int: CullComparison] = [:]
            for index in results.indices { neighbors[index] = results[index] }
            results.deallocate()
            await MainActor.run { [weak self] in self?.analysisFinished(neighbors) }
        }
    }

    nonisolated private static func analyze(_ url: URL?, _ finder: CullFaceFinder) async -> CullSignals {
        guard let url else { return CullSignals() }
        return await Culling.analyze(url, finder: finder)
    }

    /// Every photo's faces from the chosen finder.
    private func useFaceFinder() {
        for index in photos.indices {
            photos[index].signals = photos[index].signals?.using(faceFinder)
        }
    }

    private func analysisFinished(_ neighbors: [Int: CullComparison]) {
        self.neighbors = neighbors
        isAnalyzing = false
        // Find Faces may have changed while the photos were read.
        useFaceFinder()
        regroup()
        if advanced { runAdvanced() }
        // The list starts again at the top with the groups, so the keys do too: the first
        // photo of the first group, not wherever capture order left off.
        focused = rows.first?.first
        loadLarge()
    }

    // MARK: Grouping

    /// What was measured between two photos (ids in capture order, `a` before `b`).
    private func comparison(_ a: Int, _ b: Int) -> CullComparison {
        if b == a + 1, let known = neighbors[a] { return known }
        let key = a * photos.count + b
        if let known = distant[key] { return known }
        guard let first = photos[a].signals, let second = photos[b].signals else { return CullComparison() }
        // Only the cheap measures: this guards a group from drifting, the neighbor did the matching.
        let measured = Culling.compare(first, second, aligning: false)
        distant[key] = measured
        return measured
    }

    /// How two photos relate at the current Grouping position.
    func link(_ a: Int, _ b: Int, slack: Bool = false) -> CullLink {
        Culling.link(comparison(min(a, b), max(a, b)), looseness: looseness, slack: slack)
    }

    /// True when every shot in the group is the same frame as the one before it.
    func isSameFrame(_ group: [Int]) -> Bool {
        group.count > 1 && zip(group, group.dropFirst()).allSatisfy { link($0, $1) == .sameFrame }
    }

    /// Groups again and suggests keepers; `keepingChoices` keeps the person's Keep and Drop
    /// clicks (when the Advanced checks finish in the background) once they've made any.
    func regroup(keepingChoices: Bool = false) {
        if isReview {
            groups = [photos.map(\.id)]
        } else {
            let photos = self.photos
            groups = Culling.groups(count: photos.count, times: { photos[$0].captureTime }, mode: mode) { a, b, slack in
                self.link(a, b, slack: slack)
            }
        }
        var suggested: Set<Int> = []
        var kept: Set<Int> = []
        var assessments: [Int: CullAssessment] = [:]
        let flags = currentFlags()
        for group in groups {
            let signals = group.map { photos[$0].signals ?? CullSignals() }
            for (id, assessment) in zip(group, Culling.assess(signals)) { assessments[id] = assessment }
            guard group.count > 1 else {
                kept.formUnion(group)
                continue
            }
            let best = Culling.keeper(signals, by: pickBy)
            if let best { suggested.insert(group[best]) }
            // Photos already picked stay the keepers; otherwise the suggestion.
            let picked = group.filter { flags[$0] == .picked }
            if !picked.isEmpty {
                kept.formUnion(picked)
            } else if let best {
                kept.insert(group[best])
            }
        }
        self.suggested = suggested
        if !(keepingChoices && choicesChanged) {
            self.kept = kept
            choicesChanged = false
        }
        self.assessments = assessments
        if advanced { runAdvanced() }
    }

    // MARK: Advanced checks

    /// Reads the eyes of every photo in a group of two or more again from a large copy (single
    /// shots are always kept, so they're skipped), the focused photo's group first. Picks again
    /// when done. Photos already read keep their result, so moving the Grouping slider only
    /// reads the new ones.
    private func runAdvanced() {
        guard !isAnalyzing, advancedTask == nil else { return }
        let focusedGroup = focused.flatMap { id in multiGroups.first { $0.contains(id) } } ?? []
        let ids = (focusedGroup + multiGroups.flatMap { $0 })
            .reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { photos[$0].signals.map { !$0.advanced } ?? false }
        guard !ids.isEmpty else { return }
        let jobs = ids.map { ($0, photos[$0].url, photos[$0].signals ?? CullSignals()) }
        advancedProgress = (0, jobs.count)
        advancedTask = Task.detached(priority: .utility) { [weak self] in
            // Fewer at once than the standard pass: each large copy takes a lot of memory.
            let workers = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 3))
            await withTaskGroup(of: (Int, CullSignals).self) { group in
                var pending = jobs.makeIterator()
                for _ in 0..<workers {
                    guard let (id, url, signals) = pending.next() else { break }
                    group.addTask { (id, Self.advanced(url, signals)) }
                }
                for await (id, signals) in group {
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.photos[id].signals = signals
                        if let progress = self.advancedProgress { self.advancedProgress = (progress.done + 1, progress.total) }
                    }
                    if let (nextID, url, signals) = pending.next() {
                        group.addTask { (nextID, Self.advanced(url, signals)) }
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.advancedTask = nil
                self.advancedProgress = nil
                self.regroup(keepingChoices: true)
            }
        }
    }

    nonisolated private static func advanced(_ url: URL?, _ signals: CullSignals) -> CullSignals {
        guard let url, !Task.isCancelled else { return signals }
        return Culling.analyzeAdvanced(url, signals: signals)
    }

    private func stopAdvanced() {
        advancedTask?.cancel()
        advancedTask = nil
        advancedProgress = nil
    }

    private func currentFlags() -> [Int: Flag] {
        guard let model else { return [:] }
        var flags: [Int: Flag] = [:]
        for photo in photos {
            if let id = photo.assetID, let flag = try? model.catalog.detail(for: id)?.metadata.flag { flags[photo.id] = flag }
        }
        return flags
    }

    // MARK: Choosing

    func toggle(_ id: Int) {
        if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
        choicesChanged = true
    }

    func setKept(_ id: Int, _ keep: Bool) {
        if keep { kept.insert(id) } else { kept.remove(id) }
        choicesChanged = true
    }

    func keepAll() {
        kept = Set(photos.map(\.id))
        choicesChanged = true
    }

    func focus(_ id: Int) {
        guard focused != id else { return }
        focused = id
        loadLarge()
    }

    /// Focuses a photo and scrolls the list to it, for the arrow keys.
    private func focusAndReveal(_ id: Int) {
        focus(id)
        reveal = CullReveal(id: id, serial: (reveal?.serial ?? 0) + 1)
    }

    /// The rows the list shows, top to bottom: while analyzing, every photo in capture order
    /// wrapped at `columns`; then the groups of similar shots and a last row of single shots.
    /// The arrow keys move through these, so they always match what is on screen.
    var rows: [[Int]] {
        if isAnalyzing {
            let ids = photos.map(\.id)
            return stride(from: 0, to: ids.count, by: max(columns, 1)).map { Array(ids[$0..<min($0 + max(columns, 1), ids.count)]) }
        }
        return multiGroups + (singles.isEmpty ? [] : [singles])
    }

    /// Photos per row while analyzing, set by the list from its width.
    @Published var columns = 4

    /// Arrow keys: left and right through the photos in list order, up and down to the row above
    /// or below, keeping the place in the row where it can (like a grid).
    func move(_ step: Int, byRow: Bool) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        guard let current = focused, let row = rows.firstIndex(where: { $0.contains(current) }),
              let column = rows[row].firstIndex(of: current) else {
            focusAndReveal(rows[0][0])
            return
        }
        if byRow {
            let target = row + step
            guard rows.indices.contains(target) else { return }
            focusAndReveal(rows[target][min(column, rows[target].count - 1)])
        } else {
            let order = rows.flatMap { $0 }
            guard let index = order.firstIndex(of: current) else { return }
            focusAndReveal(order[min(max(index + step, 0), order.count - 1)])
        }
    }

    private func loadLarge() {
        placingNote = nil
        fullImage = nil
        fullTask?.cancel()
        fullTask = nil
        guard let id = focused, let url = photos[id].url else {
            largeImage = nil
            pixelSize = nil
            return
        }
        // With a photo on screen it stays until this one is ready; otherwise its thumbnail shows.
        if largeImage == nil {
            largeImage = photos[id].thumbnail
            largeImageID = id
            pixelSize = nil
        } else {
            photoHold.begin()
            // Past the limit: its thumbnail rather than the last photo.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.photoHold.limit ?? 1))
                guard let self, self.focused == id, self.largeImageID != id, let thumbnail = self.photos[id].thumbnail else { return }
                self.largeImage = thumbnail
                self.largeImageID = id
                self.pixelSize = nil
            }
        }
        largeTask?.cancel()
        largeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let size = Culling.pixelSize(at: url)
            let image = Culling.image(at: url, maxPixel: 1800).map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.focused == id else { return }
                self.largeImage = image
                self.largeImageID = id
                self.pixelSize = size
                self.zoomChanged()
                // At Fit this is the picture; zoomed in, the full-size one ends the hold.
                if !self.zoom.report.isZoomedPastFit || image == nil { self.photoHold.end(because: nil) }
            }
        }
    }

    private var fullTask: Task<Void, Never>?

    /// The preview's zoom moved: past Fit, the focused photo is read at full size (once).
    func zoomChanged() {
        guard zoom.report.isZoomedPastFit, fullImage == nil, fullTask == nil,
              let id = focused, let url = photos[id].url else { return }
        let side = pixelSize.map { Int(max($0.width, $0.height)) } ?? 12000
        fullTask = Task.detached(priority: .userInitiated) { [weak self] in
            let image = Culling.image(at: url, maxPixel: max(side, 1800)).map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.focused == id else { return }
                self.fullImage = image
                self.photoHold.end(because: nil)
            }
        }
    }

    /// Z (the zoom key in Settings > Keyboard): Fit, or the click zoom (100% unless changed).
    func toggleZoom() {
        zoom.level = zoom.report.isZoomedPastFit ? .fit : .percent(ZoomLevel.clickZoomPercent)
    }

    /// The click on the photo that pins the waiting note (0...1 across and down the photo).
    func placeNote(at point: CGPoint) {
        guard let id = placingNote, catalog != nil else { return }
        placingNote = nil
        pinNote(id, at: point)
    }

    func removePin(_ note: PhotoNote) {
        guard let id = note.id, catalog != nil else { return }
        if placingNote == id { placingNote = nil }
        pinNote(id, at: nil)
    }

    /// Pins a note to a spot or unpins it; a failed save is said in the status line (AT-076 E1).
    private func pinNote(_ id: Int64, at point: CGPoint?) {
        guard let catalog else { return }
        do {
            _ = try catalog.setNoteSpot(id, point)
        } catch {
            model?.status = "Couldn't save the note's pin: \(error.localizedDescription)"
        }
    }

    /// The focused photo's faces with what culling concluded about each, for the preview's
    /// Show Subject boxes. Eyes are judged against the photo's group, as for the pick.
    func previewFaces(of id: Int) -> [CullPreviewFace] {
        guard photos.indices.contains(id), let signals = photos[id].signals else { return [] }
        let group = groups.first { $0.contains(id) } ?? [id]
        let eyes = Culling.eyes(in: group.map { photos[$0].signals?.faces ?? [] })
        let mine = eyes[group.firstIndex(of: id) ?? 0]
        let all = zip(signals.faces, mine).map { face, eyes in
            CullPreviewFace(box: face.box, eyes: eyes, smile: face.expression?.smile, byMediaPipe: face.byMediaPipe)
        }
        // Numbered left to right on the photo.
        return all.sorted { $0.box.minX < $1.box.minX }
    }

    /// What was measured for the focused photo, for the preview's caption.
    func caption(of id: Int) -> String? {
        guard let assessment = assessments[id] else { return nil }
        let inGroup = groups.first { $0.contains(id) }.map { $0.count > 1 } ?? false
        return Culling.caption(assessment, inGroup: inGroup)
    }

    /// Why a photo isn't kept so far, one line per reason, for the preview; nil when it is kept
    /// or alone.
    func reasons(of id: Int) -> [String]? {
        guard !kept.contains(id), let group = groups.first(where: { $0.contains(id) }), group.count > 1,
              let keeper = self.keeper(of: group), let mine = assessments[id], let theirs = assessments[keeper] else { return nil }
        return Culling.reasons(mine, keeper: theirs)
    }

    /// The kept photo a dropped one is compared with: the best of the group's kept photos by
    /// the current Pick By.
    func keeper(of group: [Int]) -> Int? {
        let keptIDs = group.filter { kept.contains($0) }
        guard !keptIDs.isEmpty else { return nil }
        let scores = Culling.ranking(keptIDs.map { assessments[$0] ?? CullAssessment() }, by: pickBy)
        return scores.indices.max { scores[$0] < scores[$1] }.map { keptIDs[$0] }
    }

    /// The Cull note for each photo dropped from a group of two or more (key: photo id).
    func reasonNotes() -> [Int: String] {
        var notes: [Int: String] = [:]
        for group in multiGroups {
            guard let keeper = self.keeper(of: group), let theirs = assessments[keeper] else { continue }
            for id in group where !kept.contains(id) {
                notes[id] = Culling.reasonNote(
                    name: photos[keeper].name, groupSize: group.count, sameFrame: isSameFrame(group),
                    keeperChosenByYou: !suggested.contains(keeper),
                    reasons: assessments[id].map { Culling.reasons($0, keeper: theirs) } ?? [],
                    droppedSuggestion: suggested.contains(id))
            }
        }
        return notes
    }

    /// Where each dropped photo's reason note is pinned (key: photo id): the face with closed
    /// eyes, for the Cull preview's markers.
    func reasonSpots() -> [Int: CGPoint] {
        var spots: [Int: CGPoint] = [:]
        for group in multiGroups {
            guard let keeper = self.keeper(of: group), let keeperIndex = group.firstIndex(of: keeper) else { continue }
            let signals = group.map { photos[$0].signals ?? CullSignals() }
            for (id, spot) in zip(group, Culling.reasonSpots(signals, keeper: keeperIndex)) where !kept.contains(id) {
                if let spot { spots[id] = spot }
            }
        }
        return spots
    }

    // MARK: Finishing

    var keptCount: Int { kept.count }
    var droppedCount: Int { photos.count - kept.count }

    func cancel() {
        stop()
        if let onClose { onClose(false) } else { model?.cullSession = nil }
    }

    /// Stops reading and analyzing, as when going back from the Import dialog's Cull step.
    func stop() {
        loadTask?.cancel()
        analysisTask?.cancel()
        largeTask?.cancel()
        fullTask?.cancel()
        stopAdvanced()
    }

    func finish() {
        guard let model else { return }
        analysisTask?.cancel()
        stopAdvanced()
        let groups = self.groups, kept = self.kept, photos = self.photos
        // Reasons for the photos not kept (AT-058), and the kept ones whose old Cull note says
        // "Kept later".
        let notes = writeReasons ? reasonNotes() : [:]
        let spots = writeReasons ? reasonSpots() : [:]
        let keptInGroups = writeReasons ? groups.filter { $0.count > 1 }.flatMap { $0 }.filter { kept.contains($0) } : []
        switch source {
        case .importing(_, let options):
            // Everything is cataloged so rejects can be reviewed later; only keepers join the entry.
            let files = photos.flatMap { [$0.url!] + $0.siblings }
            model.runImport(sources: files, options: options, stager: stager) { result in
                guard let entry = result.importGroupId else { return }
                let id = { (index: Int) in result.assetIDsBySource[photos[index].url!] }
                let rejected = photos.filter { !kept.contains($0.id) }
                let rejects = rejected.compactMap { id($0.id) }
                let rejectFiles = rejects + rejected.flatMap { $0.siblings.compactMap { result.assetIDsBySource[$0] } }
                // AT-076 E1: as for culling cataloged photos below, a failed write is said, not
                // reported as culled.
                do {
                    try model.catalog.removeAssets(rejectFiles, fromImportGroup: entry)
                    try model.catalog.applyCull(groups: groups.map { $0.compactMap(id) },
                                                keepers: Set(kept.compactMap(id)))
                    try model.catalog.writeCullNotes(rejected: Self.byAsset(notes, id), spots: Self.byAsset(spots, id),
                                                     kept: keptInGroups.compactMap(id))
                    model.status = "Imported \(kept.count) kept photo\(kept.count == 1 ? "" : "s"); \(rejects.count) culled shot\(rejects.count == 1 ? " is" : "s are") in Show Cull Group"
                } catch {
                    model.status = "Imported \(photos.count) photo\(photos.count == 1 ? "" : "s"), but the cull couldn't be saved: \(error.localizedDescription)"
                }
            }
        case .photos:
            let id = { (index: Int) in photos[index].assetID }
            do {
                try model.catalog.applyCull(groups: groups.map { $0.compactMap(id) }, keepers: Set(kept.compactMap(id)))
                try model.catalog.writeCullNotes(rejected: Self.byAsset(notes, id), spots: Self.byAsset(spots, id),
                                                 kept: keptInGroups.compactMap(id))
                let culled = groups.filter { $0.count > 1 }.flatMap { $0 }
                let rejected = culled.filter { !kept.contains($0) }.count
                model.status = isReview ? "Cull group updated"
                    : "Culled \(culled.count) photos: \(culled.count - rejected) picked, \(rejected) rejected"
                model.reloadDetail()
            } catch {
                model.status = error.localizedDescription
            }
        }
        if let onClose { onClose(true) } else { model.cullSession = nil }
    }

    /// Notes keyed by photo id, re-keyed by catalog id (photos without one are left out).
    nonisolated static func byAsset<Value>(_ values: [Int: Value], _ id: (Int) -> Int64?) -> [Int64: Value] {
        var result: [Int64: Value] = [:]
        for (photo, value) in values { if let asset = id(photo) { result[asset] = value } }
        return result
    }
}

extension LibraryModel {
    /// Right-click an import entry > Cull…, or Library > Cull Import….
    func beginCull(importGroup id: Int64) {
        // Virtual copies are deliberate versions, not near-duplicate shots.
        guard let entry = sidebar.imports.first(where: { $0.id == id }),
              let rows = (try? catalog.assetRows(filter: LibraryFilter(scope: .importGroup(id), groupsRawPairs: true, privacy: filter.privacy)))?
                .filter({ $0.stackKind != .virtualCopy }), !rows.isEmpty else {
            status = "This import has no photos to cull"
            return
        }
        cullSession = CullModel(source: .photos(rows.map(\.id), isReview: false), title: "Cull \u{201C}\(entry.name)\u{201D}", model: self)
    }

    /// Photo > Show Cull Group: the photo with every shot it was culled with.
    func showCullGroup() {
        guard let id = focusedID, let members = try? catalog.cullGroup(of: id), members.count > 1 else {
            status = "This photo wasn't culled with other shots"
            return
        }
        let session = CullModel(source: .photos(members, isReview: true), title: "Cull Group", model: self)
        cullSession = session
    }

    /// The Import dialog's Cull step, with Cull before importing on.
    func importCull(sources: [URL], options: ImportOptions) -> CullModel {
        let name: String
        switch options.target {
        case .existingGroup(let id): name = sidebar.imports.first { $0.id == id }?.name ?? "Import"
        case .newGroup(let entry): name = entry.isEmpty ? (sources.first?.lastPathComponent ?? "Import") : entry
        }
        return CullModel(source: .importing(sources: sources, options: options),
                         title: "Cull Before Importing \u{201C}\(name)\u{201D}", model: self)
    }

    var focusedCullGroupSize: Int {
        guard let id = focusedID else { return 0 }
        return rows.first { $0.id == id }?.cullGroupSize ?? 0
    }
}
