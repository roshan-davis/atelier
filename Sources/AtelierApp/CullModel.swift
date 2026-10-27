import AppKit
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

/// The Cull view's state: photos grouped into similar shots and which ones are kept.
@MainActor
final class CullModel: ObservableObject, Identifiable {
    enum Source {
        /// Files chosen in the Import dialog, not cataloged yet.
        case importing(files: [URL], options: ImportOptions)
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
    @Published private(set) var analyzed = 0
    @Published private(set) var isAnalyzing = true
    /// 0 is tight (only near-identical shots), 1 is loose.
    @Published var looseness = 0.5 {
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
    /// Measurements between each photo and the next (key: the first's id), made after analysis.
    private var neighbors: [Int: CullComparison] = [:]
    /// Measurements between a group's first shot and later ones, made as grouping needs them.
    private var distant: [Int: CullComparison] = [:]
    @Published private(set) var largeImage: NSImage?

    private weak var model: LibraryModel?
    private var analysisTask: Task<Void, Never>?
    private var largeTask: Task<Void, Never>?

    var isImporting: Bool { if case .importing = source { return true } else { return false } }
    var isReview: Bool { if case .photos(_, true) = source { return true } else { return false } }
    var multiGroups: [[Int]] { groups.filter { $0.count > 1 } }
    var singles: [Int] { groups.filter { $0.count == 1 }.flatMap { $0 } }

    init(source: Source, title: String, model: LibraryModel) {
        self.source = source
        self.title = title
        self.model = model
        load()
    }

    // MARK: Loading

    private func load() {
        guard let model else { return }
        switch source {
        case .importing(let files, _):
            // A RAW and its JPEG are one frame: culled as the RAW, the decision applies to both.
            let photos = FilePairs.pairs(files).enumerated().map { index, pair in
                CullPhoto(id: index, url: pair.primary, assetID: nil, name: pair.primary.lastPathComponent,
                          captureTime: MetadataReader.read(pair.primary).captureTime, siblings: pair.siblings,
                          pairFormats: pair.siblings.map { $0.pathExtension.uppercased() })
            }
            self.photos = Self.ordered(photos)
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
            self.photos = Self.ordered(photos)
        }
        focused = photos.first?.id
        analyze()
    }

    /// Capture order, renumbered so ids are positions.
    private static func ordered(_ photos: [CullPhoto]) -> [CullPhoto] {
        photos.sorted { ($0.captureTime ?? .distantFuture, $0.name) < ($1.captureTime ?? .distantFuture, $1.name) }
            .enumerated().map { index, photo in photo.renumbered(index) }
    }

    private func analyze() {
        let jobs = photos.map { ($0.id, $0.url) }
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            await withTaskGroup(of: (Int, CullSignals).self) { group in
                var pending = jobs.makeIterator()
                for _ in 0..<workers {
                    guard let (id, url) = pending.next() else { break }
                    group.addTask { (id, url.map(Culling.analyze) ?? CullSignals()) }
                }
                for await (id, signals) in group {
                    if Task.isCancelled { return }
                    let thumbnail = signals.thumbnail.map { NSImage(cgImage: $0, size: .zero) }
                    await MainActor.run {
                        guard let self else { return }
                        self.photos[id].signals = signals
                        self.photos[id].thumbnail = thumbnail
                        self.analyzed += 1
                    }
                    if let (nextID, url) = pending.next() {
                        group.addTask { (nextID, url.map(Culling.analyze) ?? CullSignals()) }
                    }
                }
            }
            // Each photo against the next, in parallel: lining shots up for a zoom is the slow part.
            let signals = await MainActor.run { self?.photos.map(\.signals) } ?? []
            guard !Task.isCancelled, signals.count > 1 else {
                await MainActor.run { self?.analysisFinished([:]) }
                return
            }
            let results = UnsafeMutableBufferPointer<CullComparison>.allocate(capacity: signals.count - 1)
            results.initialize(repeating: CullComparison())
            DispatchQueue.concurrentPerform(iterations: signals.count - 1) { index in
                guard let a = signals[index], let b = signals[index + 1] else { return }
                results[index] = Culling.compare(a, b)
            }
            var neighbors: [Int: CullComparison] = [:]
            for index in results.indices { neighbors[index] = results[index] }
            results.deallocate()
            await MainActor.run { self?.analysisFinished(neighbors) }
        }
    }

    private func analysisFinished(_ neighbors: [Int: CullComparison]) {
        self.neighbors = neighbors
        isAnalyzing = false
        regroup()
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

    func regroup() {
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
        let flags = currentFlags()
        for group in groups {
            guard group.count > 1 else {
                kept.formUnion(group)
                continue
            }
            let signals = group.map { photos[$0].signals ?? CullSignals() }
            if let best = Culling.suggestedKeeper(signals) { suggested.insert(group[best]) }
            // Photos already picked stay the keepers; otherwise the suggestion.
            let picked = group.filter { flags[$0] == .picked }
            if !picked.isEmpty {
                kept.formUnion(picked)
            } else if let best = Culling.suggestedKeeper(signals) {
                kept.insert(group[best])
            }
        }
        self.suggested = suggested
        self.kept = kept
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
    }

    func setKept(_ id: Int, _ keep: Bool) {
        if keep { kept.insert(id) } else { kept.remove(id) }
    }

    func keepAll() { kept = Set(photos.map(\.id)) }

    func focus(_ id: Int) {
        guard focused != id else { return }
        focused = id
        loadLarge()
    }

    /// Arrow keys: left and right within the order, up and down a group at a time.
    func move(_ step: Int, byGroup: Bool) {
        let order = multiGroups.flatMap { $0 } + singles
        guard !order.isEmpty else { return }
        guard let current = focused, let index = order.firstIndex(of: current) else {
            focus(order[0])
            return
        }
        if byGroup {
            let all = multiGroups + (singles.isEmpty ? [] : [singles])
            guard let groupIndex = all.firstIndex(where: { $0.contains(current) }) else { return }
            let target = min(max(groupIndex + step, 0), all.count - 1)
            focus(all[target].first { kept.contains($0) } ?? all[target][0])
        } else {
            focus(order[min(max(index + step, 0), order.count - 1)])
        }
    }

    private func loadLarge() {
        guard let id = focused, let url = photos[id].url else {
            largeImage = nil
            return
        }
        largeImage = photos[id].thumbnail
        largeTask?.cancel()
        largeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let image = Culling.image(at: url, maxPixel: 1800).map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run {
                guard let self, !Task.isCancelled, self.focused == id else { return }
                self.largeImage = image
            }
        }
    }

    /// Sharpness relative to the sharpest photo of its group, for the preview's caption.
    func relativeSharpness(of id: Int) -> Double? {
        guard let group = groups.first(where: { $0.contains(id) }), group.count > 1,
              let value = photos[id].signals?.sharpness else { return nil }
        let best = group.compactMap { photos[$0].signals?.sharpness }.max() ?? 0
        return best > 0 ? value / best : nil
    }

    // MARK: Finishing

    var keptCount: Int { kept.count }
    var droppedCount: Int { photos.count - kept.count }

    func cancel() {
        analysisTask?.cancel()
        largeTask?.cancel()
        model?.cullSession = nil
    }

    func finish() {
        guard let model else { return }
        analysisTask?.cancel()
        let groups = self.groups, kept = self.kept, photos = self.photos
        switch source {
        case .importing(_, let options):
            // Everything is cataloged so rejects can be reviewed later; only keepers join the entry.
            let files = photos.flatMap { [$0.url!] + $0.siblings }
            model.runImport(sources: files, options: options) { result in
                guard let entry = result.importGroupId else { return }
                let id = { (index: Int) in result.assetIDsBySource[photos[index].url!] }
                let rejected = photos.filter { !kept.contains($0.id) }
                let rejects = rejected.compactMap { id($0.id) }
                let rejectFiles = rejects + rejected.flatMap { $0.siblings.compactMap { result.assetIDsBySource[$0] } }
                try? model.catalog.removeAssets(rejectFiles, fromImportGroup: entry)
                try? model.catalog.applyCull(groups: groups.map { $0.compactMap(id) },
                                             keepers: Set(kept.compactMap(id)))
                model.status = "Imported \(kept.count) kept photo\(kept.count == 1 ? "" : "s"); \(rejects.count) culled shot\(rejects.count == 1 ? " is" : "s are") in Show Cull Group"
            }
        case .photos:
            let id = { (index: Int) in photos[index].assetID }
            do {
                try model.catalog.applyCull(groups: groups.map { $0.compactMap(id) }, keepers: Set(kept.compactMap(id)))
                let culled = groups.filter { $0.count > 1 }.flatMap { $0 }
                let rejected = culled.filter { !kept.contains($0) }.count
                model.status = isReview ? "Cull group updated"
                    : "Culled \(culled.count) photos: \(culled.count - rejected) picked, \(rejected) rejected"
                model.reloadDetail()
            } catch {
                model.status = error.localizedDescription
            }
        }
        model.cullSession = nil
    }
}

extension LibraryModel {
    /// Right-click an import entry > Cull…, or Library > Cull Import….
    func beginCull(importGroup id: Int64) {
        // Virtual copies are deliberate versions, not near-duplicate shots.
        guard let entry = sidebar.imports.first(where: { $0.id == id }),
              let rows = (try? catalog.assetRows(filter: LibraryFilter(scope: .importGroup(id), groupsRawPairs: true)))?
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

    /// From the Import dialog with Cull before importing on.
    func beginImportCull(sources: [URL], options: ImportOptions) {
        let files = Importer.collectFiles(from: sources)
        guard !files.isEmpty else { return }
        let name: String
        switch options.target {
        case .existingGroup(let id): name = sidebar.imports.first { $0.id == id }?.name ?? "Import"
        case .newGroup(let entry): name = entry.isEmpty ? (sources.first?.lastPathComponent ?? "Import") : entry
        }
        cullSession = CullModel(source: .importing(files: files, options: options), title: "Cull Before Importing \u{201C}\(name)\u{201D}", model: self)
    }

    var focusedCullGroupSize: Int {
        guard let id = focusedID else { return 0 }
        return rows.first { $0.id == id }?.cullGroupSize ?? 0
    }
}
