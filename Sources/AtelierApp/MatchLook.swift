import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// A reference file in Recent References. Only its location and a small thumbnail are kept; the
/// file itself is read in place and never copied into the catalog.
struct RecentReference: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    /// PNG, about 160 pixels on the long edge.
    var thumbnail: Data

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    static let defaultsKey = "matchLook.recent"
    static let limit = 8

    static func load() -> [RecentReference] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RecentReference].self, from: data)) ?? []
    }

    static func save(_ references: [RecentReference]) {
        if let data = try? JSONEncoder().encode(Array(references.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// One line of Show Differences.
struct MatchDifference: Identifiable, Hashable {
    var name: String
    var change: String
    var id: String { name }

    /// The sliders that differ between `old` and `new`, in panel order.
    static func list(from old: DevelopSettings, to new: DevelopSettings, asShot: Double) -> [MatchDifference] {
        var lines: [MatchDifference] = []
        if old.temperature != new.temperature {
            let from = Int((old.temperature ?? asShot).rounded()), to = Int((new.temperature ?? asShot).rounded())
            if from != to { lines.append(MatchDifference(name: "Temp", change: "\(from) → \(to) K")) }
        }
        let changed = DevelopSettings.Parameter.allCases.filter { $0 != .temperature && abs(old[$0] - new[$0]) > 1e-6 }
        for parameter in changed where parameter.panel == .basic {
            lines.append(line(parameter, old[parameter], new[parameter]))
        }
        if old.points(for: .rgb) != new.points(for: .rgb) {
            lines.append(MatchDifference(name: "Tone Curve (RGB)", change: "reshaped"))
        }
        for parameter in changed where parameter.panel != .basic {
            lines.append(line(parameter, old[parameter], new[parameter]))
        }
        return lines
    }

    private static let hueParameters: Set<DevelopSettings.Parameter> = [
        .gradeShadowsHue, .gradeMidtonesHue, .gradeHighlightsHue, .gradeGlobalHue,
    ]

    private static func line(_ parameter: DevelopSettings.Parameter, _ from: Double, _ to: Double) -> MatchDifference {
        let change: String
        if hueParameters.contains(parameter) {
            change = "\(Int(from.rounded()))° → \(Int(to.rounded()))°"
        } else if parameter == .exposure {
            change = String(format: "%+.2f → %+.2f", from, to)
        } else if parameter.range.lowerBound >= 0 {
            change = String(format: "%.0f → %.0f", from, to)
        } else {
            change = String(format: "%+.0f → %+.0f", from, to)
        }
        return MatchDifference(name: name(parameter), change: change)
    }

    private static func name(_ parameter: DevelopSettings.Parameter) -> String {
        if let pair = parameter.hslBand { return "\(pair.0.rawValue) \(pair.1.rawValue)" }
        if parameter.panel == .colorGrading { return "Grading \(parameter.group) \(parameter.label)" }
        return parameter.label
    }
}

/// With several photos selected: one fit synced to all, or a fit per photo.
enum MatchApplyMode: String, CaseIterable {
    case same, each

    var label: String { self == .same ? "Same settings" : "Match each photo" }
}

/// The Match Look dialog's state. The reference is matched and previewed here; nothing changes on
/// the photo until Apply.
@MainActor
final class MatchLookModel: ObservableObject, Identifiable {
    let id = UUID()
    let assetID: Int64
    /// Every photo the match applies to, the open one first.
    let targets: [Int64]
    let photoName: String
    let base: DevelopSettings
    private weak var library: LibraryModel?

    @Published private(set) var referenceName: String?
    @Published private(set) var referenceImage: NSImage?
    private var referenceCG: CGImage?
    @Published private(set) var recent = RecentReference.load()

    @Published var options = MatchLookModel.savedOptions {
        didSet {
            UserDefaults.standard.set([options.whiteBalance, options.tone, options.color], forKey: "matchLook.options")
            scheduleMatch()
        }
    }
    @Published var usesAreas = false {
        didSet { scheduleMatch() }
    }
    /// Match Areas' boxes, 0 to 1 from the top left of each image.
    @Published var referenceArea = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) {
        didSet { if usesAreas { scheduleMatch() } }
    }
    @Published var photoArea = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) {
        didSet { if usesAreas { scheduleMatch() } }
    }
    /// 0 to 100.
    @Published var strength = 100.0 {
        didSet { renderPreview() }
    }
    @Published var applyMode: MatchApplyMode = .same

    @Published private(set) var preview: NSImage?
    @Published private(set) var before: NSImage?
    @Published private(set) var isMatching = false
    @Published private(set) var message: String?
    @Published private(set) var match: LookMatch?

    private var fitSession: DevelopSession?
    private var previewSession: DevelopSession?
    private let fitQueue = DispatchQueue(label: "atelier.matchlook.fit", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "atelier.matchlook.preview", qos: .userInitiated)
    private let latest = Generation()
    private var debounce: Task<Void, Never>?
    private var previewRendering = false
    private var previewPending = false

    /// Long edge of the dialog's preview.
    static let previewSize = 1400

    private static var savedOptions: LookMatchOptions {
        let saved = UserDefaults.standard.array(forKey: "matchLook.options") as? [Bool] ?? []
        guard saved.count == 3 else { return LookMatchOptions() }
        return LookMatchOptions(whiteBalance: saved[0], tone: saved[1], color: saved[2])
    }

    init(library: LibraryModel, assetID: Int64, targets: [Int64], url: URL, settings: DevelopSettings) {
        self.library = library
        self.assetID = assetID
        self.targets = targets
        self.base = settings
        photoName = url.lastPathComponent
        fitQueue.async {
            let fit = DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size)
            let preview = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.previewSize)
            let beforeImage = preview?.render(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fitSession = fit
                    self.previewSession = preview
                    if let beforeImage {
                        let image = NSImage(cgImage: beforeImage, size: NSSize(width: beforeImage.width, height: beforeImage.height))
                        self.before = image
                        if self.preview == nil { self.preview = image }
                    }
                    if fit == nil { self.message = "This photo can't be opened for matching." }
                    self.scheduleMatch(delay: 0)
                }
            }
        }
    }

    var otherCount: Int { targets.count - 1 }

    /// Show Differences at the current strength.
    var differences: [MatchDifference] {
        guard let match else { return [] }
        return MatchDifference.list(from: base, to: match.settings(strength: strength / 100),
                                    asShot: match.asShotTemperature)
    }
    var canApply: Bool { match != nil && !isMatching }

    // MARK: Reference

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Reference Image"
        panel.prompt = "Use as Reference"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFile(url)
    }

    /// Any image file: a downloaded photo, a film still, a screenshot, or a RAW's embedded preview.
    func useFile(_ url: URL) {
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let image = LookReference.image(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let image else {
                        self.message = "Lightfast can't read “\(url.lastPathComponent)” as an image."
                        return
                    }
                    self.setReference(image, name: url.lastPathComponent)
                    self.remember(url, image: image)
                }
            }
        }
    }

    func useRecent(_ reference: RecentReference) {
        guard reference.exists else {
            message = "“\(reference.name)” was moved or deleted."
            return
        }
        useFile(reference.url)
    }

    func removeRecent(_ reference: RecentReference) {
        recent.removeAll { $0.path == reference.path }
        RecentReference.save(recent)
    }

    /// A catalog photo with its current edits.
    func useCatalogPhoto(_ id: Int64) {
        guard let library, let url = try? library.catalog.fileURL(for: id) else {
            message = "That photo's original is offline."
            return
        }
        let settings = (try? library.catalog.developSettings(for: id)) ?? .neutral
        let name = url.lastPathComponent
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let image = DevelopRenderer.shared.session(for: url, maxPixelSize: 1024)?.renderSRGB(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let image else {
                        self.message = "“\(name)” can't be opened."
                        return
                    }
                    self.setReference(image, name: name)
                }
            }
        }
    }

    private func setReference(_ image: CGImage, name: String) {
        referenceCG = image
        referenceImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        referenceName = name
        scheduleMatch(delay: 0)
    }

    private func remember(_ url: URL, image: CGImage) {
        guard let thumbnail = Self.thumbnailPNG(image) else { return }
        recent.removeAll { $0.path == url.path }
        recent.insert(RecentReference(path: url.path, name: url.lastPathComponent, thumbnail: thumbnail), at: 0)
        recent = Array(recent.prefix(RecentReference.limit))
        RecentReference.save(recent)
    }

    private static func thumbnailPNG(_ image: CGImage) -> Data? {
        let factor = min(1, 160 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: DevelopRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }

    // MARK: Matching

    /// Refits after the reference, checkboxes or areas change; dragging an area collapses into one fit.
    func scheduleMatch(delay: Int = 250) {
        let generation = latest.next()
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.runMatch(generation)
        }
    }

    private func runMatch(_ generation: Int) {
        guard let fitSession, let referenceCG else { return }
        guard !options.isEmpty else {
            match = nil
            isMatching = false
            message = "Turn on White Balance, Tone or Color to match."
            renderPreview()
            return
        }
        isMatching = true
        message = nil
        let referenceArea = usesAreas ? self.referenceArea : nil
        let photoArea = usesAreas ? self.photoArea : nil
        let options = self.options, base = self.base, latest = self.latest
        fitQueue.async {
            guard latest.current == generation else { return }
            let result = LookSample(image: referenceCG, area: referenceArea).flatMap { reference in
                LookMatcher.match(session: fitSession, settings: base, reference: reference, options: options,
                                  photoArea: photoArea, isCancelled: { latest.current != generation })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.latest.current == generation else { return }
                    self.isMatching = false
                    self.match = result
                    if result == nil { self.message = "This photo can't be matched." }
                    self.renderPreview()
                }
            }
        }
    }

    /// The preview at the current strength. Latest wins, as in Develop.
    private func renderPreview() {
        guard let previewSession else { return }
        if previewRendering {
            previewPending = true
            return
        }
        previewRendering = true
        let settings = match?.settings(strength: strength / 100) ?? base
        previewQueue.async {
            let cgImage = previewSession.render(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.previewRendering = false
                    if let cgImage {
                        self.preview = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    }
                    if self.previewPending {
                        self.previewPending = false
                        self.renderPreview()
                    }
                }
            }
        }
    }

    // MARK: Apply

    func apply() {
        guard let match, let library, let referenceCG else { return }
        let strength = self.strength / 100
        let step = "Match Look: \(referenceName ?? "Reference")"
        library.develop.apply(match.settings(strength: strength), onto: [assetID], step: step)
        let others = Array(targets.dropFirst())
        guard !others.isEmpty else { return }
        switch applyMode {
        case .same:
            for id in others {
                let settings = match.applied(to: (try? library.catalog.developSettings(for: id)) ?? .neutral,
                                             strength: strength)
                try? library.catalog.saveDevelopSettings(settings, for: id, step: step)
                library.develop.refreshPreviews(for: id, settings: settings)
            }
            library.status = "Matched \(targets.count) photos to \(referenceName ?? "the reference")"
        case .each:
            guard let reference = LookSample(image: referenceCG, area: usesAreas ? referenceArea : nil) else { return }
            library.matchEach(others, reference: reference, options: options, photoArea: usesAreas ? photoArea : nil,
                              strength: strength, step: step)
        }
    }
}

/// The newest request's number, readable from the fitting queue.
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

extension LibraryModel {
    /// Photo > Match Look to Reference…: the dialog for the open photo, and any others selected
    /// in the filmstrip.
    func beginMatchLook() {
        guard mode == .develop, let assetID = focusedID else {
            status = "Open a photo in Develop to match its look."
            return
        }
        guard matchProgress == nil else {
            status = "A match is already running."
            return
        }
        develop.flushSave()
        guard let url = try? catalog.fileURL(for: assetID) else {
            status = "The original is offline. Connect its drive to match this photo."
            return
        }
        var targets = [assetID]
        if selection.count > 1, selection.contains(assetID) {
            targets += rows.map(\.id).filter { $0 != assetID && selection.contains($0) }
        }
        matchLook = MatchLookModel(library: self, assetID: assetID, targets: targets, url: url, settings: develop.settings)
    }

    /// The right-click menu's Match Look to Reference…: opens the clicked photos in Develop first,
    /// keeping a multiple selection so the dialog offers Same settings or Match each photo.
    func beginMatchLook(for ids: [Int64]) {
        guard let first = ids.first else { return }
        if focusedID.map({ !ids.contains($0) }) ?? true { focusedID = first }
        if ids.count > 1 { selection = Set(ids) }
        if mode != .develop { mode = .develop }
        beginMatchLook()
    }

    /// Match each photo: fits every photo to the reference on its own, in the background.
    func matchEach(_ ids: [Int64], reference: LookSample, options: LookMatchOptions, photoArea: CGRect?,
                   strength: Double, step: String) {
        let total = ids.count
        matchProgress = ImportStatus(phase: "Matching 1 of \(total)", fraction: 0)
        matchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var matched = 0, failed = 0
            for (index, id) in ids.enumerated() {
                if Task.isCancelled { break }
                let found: (URL, DevelopSettings)? = await MainActor.run {
                    guard let self else { return nil }
                    self.matchProgress = ImportStatus(phase: "Matching \(index + 1) of \(total)",
                                                      fraction: Double(index) / Double(total))
                    guard let url = try? self.catalog.fileURL(for: id) else { return nil }
                    return (url, (try? self.catalog.developSettings(for: id)) ?? .neutral)
                }
                guard let found,
                      let session = DevelopRenderer.shared.session(for: found.0, maxPixelSize: LookSample.size),
                      let match = LookMatcher.match(session: session, settings: found.1, reference: reference,
                                                    options: options, photoArea: photoArea,
                                                    isCancelled: { Task.isCancelled })
                else {
                    failed += 1
                    continue
                }
                let settings = match.settings(strength: strength)
                await MainActor.run {
                    guard let self else { return }
                    try? self.catalog.saveDevelopSettings(settings, for: id, step: step)
                    self.develop.refreshPreviews(for: id, settings: settings)
                }
                matched += 1
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                var parts = ["Matched \(matched + 1) photo\(matched == 0 ? "" : "s")"]
                if failed > 0 { parts.append("\(failed) could not be matched (offline or unreadable)") }
                if cancelled { parts.insert("Match cancelled", at: 0) }
                self.status = parts.joined(separator: ", ")
                self.matchProgress = nil
                self.matchTask = nil
            }
        }
    }

    func cancelMatchEach() {
        matchTask?.cancel()
        matchProgress = ImportStatus(phase: "Cancelling…", fraction: nil)
    }
}
