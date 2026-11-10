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
        // Local adjustments follow the global sliders, as in Develop.
        for (name, label, parameters) in [
            (LookMatch.subjectMaskName, "Subject", LookMatch.subjectParameters),
            (LookMatch.skinMaskName, "Skin", LookMatch.skinParameters)
        ] {
            guard let mask = new.masks.first(where: { $0.name == name }) else { continue }
            let before = old.masks.first { $0.id == mask.id }
            for parameter in parameters {
                let from = before?[parameter] ?? 0, to = mask[parameter]
                guard abs(from - to) > 1e-6 else { continue }
                let change = parameter == .exposure ? String(format: "%+.2f → %+.2f", from, to)
                    : String(format: "%+.0f → %+.0f", from, to)
                lines.append(MatchDifference(name: "\(label) \(parameter.label)", change: change))
            }
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

/// Match Areas: which parts of the two images should match.
enum MatchAreaMode: String, CaseIterable {
    case wholePhoto, subject, boxes

    var label: String {
        switch self {
        case .wholePhoto: return "Whole Photo"
        case .subject: return "Subject & Background"
        case .boxes: return "Boxes"
        }
    }

    var help: String {
        switch self {
        case .wholePhoto: return "Match the whole reference to the whole photo"
        case .subject: return "Match background to background, and the subject to the subject with a mask"
        case .boxes: return "Drag a box on each image over the parts that should match"
        }
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
    @Published private(set) var builtInReference: BuiltInLookReference?
    @Published private var referenceRequest: UUID?
    private var referenceCG: CGImage?
    var isLoadingReference: Bool { referenceRequest != nil }
    @Published private(set) var recent = RecentReference.load()

    @Published var options = MatchLookModel.savedOptions {
        didSet {
            UserDefaults.standard.set([options.whiteBalance, options.tone, options.color], forKey: "matchLook.options")
            scheduleMatch()
        }
    }
    /// The open photo's faces, 0 to 1 from the top left; nil until they've been looked for.
    private var photoFaces: [CGRect]?
    private var userSetSkin = false
    var skinMode: LookSkinMode {
        get { options.skinMode }
        set {
            userSetSkin = true
            options.skinMode = newValue
        }
    }
    /// Keep the external image's area choice while a study uses Whole Photo.
    @Published private var externalAreaMode: MatchAreaMode = .wholePhoto
    var areaMode: MatchAreaMode {
        get { builtInReference == nil ? externalAreaMode : .wholePhoto }
        set {
            guard builtInReference == nil, newValue != externalAreaMode else { return }
            externalAreaMode = newValue
            scheduleMatch()
        }
    }
    var usesAreas: Bool { areaMode == .boxes }
    /// Match Areas' boxes, 0 to 1 from the top left of each image.
    @Published var referenceArea = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) {
        didSet { if usesAreas { scheduleMatch() } }
    }
    @Published var photoArea = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) {
        didSet { if usesAreas { scheduleMatch() } }
    }
    /// What Vision finds in the reference, once per reference.
    private let features = FeatureCache()
    /// 0 to 100.
    @Published var strength = 100.0 {
        didSet { renderPreview() }
    }
    @Published private var preferredApplyMode: MatchApplyMode = .same
    var applyMode: MatchApplyMode {
        get { skinMode == .match ? .each : preferredApplyMode }
        set { if skinMode != .match { preferredApplyMode = newValue } }
    }

    @Published private(set) var preview: NSImage?
    @Published private(set) var before: NSImage?
    @Published private(set) var isMatching = false
    @Published private var referenceError: String?
    @Published private var fitMessage: String?
    var message: String? { referenceError ?? fitMessage }
    @Published private(set) var match: LookMatch?
    private var fittedTarget: LookTarget?

    private var fitSession: DevelopSession?
    private var previewSession: DevelopSession?
    private let fitQueue = DispatchQueue(label: "atelier.matchlook.fit", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "atelier.matchlook.preview", qos: .userInitiated)
    private let latest = Generation()
    private var debounce: Task<Void, Never>?
    private var previewRendering = false
    private var previewPending = false

    /// Long edge of the dialog's preview.
    nonisolated static let previewSize = 1400

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
            // Faces are found on the larger preview, so small faces the 384 px fit render would
            // miss still count; Vision's boxes are 0 to 1, so they fit either size.
            let faces = (beforeImage ?? fit?.renderSRGB(settings)).map { LookSkin.faces(in: $0) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fitSession = fit
                    self.previewSession = preview
                    self.photoFaces = faces
                    if !self.userSetSkin { self.options.skinMode = faces.isEmpty ? .off : .protect }
                    if let beforeImage {
                        let image = NSImage(cgImage: beforeImage, size: NSSize(width: beforeImage.width, height: beforeImage.height))
                        self.before = image
                        if self.preview == nil { self.preview = image }
                    }
                    if fit == nil { self.fitMessage = "This photo can't be opened for matching." }
                    self.scheduleMatch(delay: 0)
                }
            }
        }
    }

    var otherCount: Int { targets.count - 1 }

    /// Show Differences at the current strength.
    var differences: [MatchDifference] {
        guard canApply, let match else { return [] }
        return MatchDifference.list(from: base, to: match.settings(strength: strength / 100),
                                    asShot: match.asShotTemperature)
    }
    var canApply: Bool {
        guard let match, !isMatching, !isLoadingReference else { return false }
        guard skinMode == .match else { return true }
        guard strength > 0 else { return false }
        if match.settings(strength: strength / 100) != base { return true }
        // A fit with no changes on the open photo can still adjust the other selected photos.
        return otherCount > 0 && (options.whiteBalance || options.tone || options.color
            || !match.notices.contains(.noSkinInReference))
    }

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
        loadReference(name: url.lastPathComponent, file: url) {
            LookReference.image(at: url)
        }
    }

    func useBuiltIn(_ reference: BuiltInLookReference) {
        loadReference(name: reference.name, builtIn: reference) { reference.image() }
    }

    func useRecent(_ reference: RecentReference) {
        guard reference.exists else {
            failReference("“\(reference.name)” was moved or deleted.")
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
            failReference("That photo's original is offline.")
            return
        }
        let settings = (try? library.catalog.developSettings(for: id)) ?? .neutral
        loadReference(name: url.lastPathComponent) {
            DevelopRenderer.shared.session(for: url, maxPixelSize: 1024)?.renderSRGB(settings)
        }
    }

    /// All sources share one request token, so an earlier decode can't replace a later pick.
    private func loadReference(name: String, builtIn: BuiltInLookReference? = nil, file: URL? = nil,
                               render: @escaping @Sendable () -> CGImage?) {
        let request = UUID()
        referenceRequest = request
        referenceError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let image = render()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.referenceRequest == request else { return }
                    guard let image else {
                        self.failReference("Atelier can't open “\(name)” as a reference.")
                        return
                    }
                    self.setReference(image, name: name, builtIn: builtIn)
                    self.referenceRequest = nil
                    if let file { self.remember(file, image: image) }
                }
            }
        }
    }

    private func failReference(_ reason: String) {
        referenceRequest = nil
        referenceError = reason
    }

    private func setReference(_ image: CGImage, name: String, builtIn: BuiltInLookReference?) {
        referenceCG = image
        referenceImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        referenceName = name
        builtInReference = builtIn
        match = nil
        preview = before
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
        isMatching = fitSession != nil && referenceCG != nil
        if isMatching { fitMessage = nil }
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
            fitMessage = "Turn on White Balance, Tone, Color or Match Skin Tone to match."
            renderPreview()
            return
        }
        let areas = lookAreas
        let options = self.options, base = self.base, latest = self.latest, features = self.features
        let photoFaces = self.photoFaces
        let authoredSkinRegions = options.skinMode == .match ? builtInReference?.skinRegions : nil
        fitQueue.async {
            guard latest.current == generation else { return }
            let needsFeatures = areas == .subject || (options.skinMode != .off && authoredSkinRegions == nil)
            let target = LookTarget(image: referenceCG, features: needsFeatures ? features.features(for: referenceCG) : nil,
                                    areas: areas, skinMode: options.skinMode, authoredSkinRegions: authoredSkinRegions)
            let result = target.flatMap { target in
                LookMatcher.match(session: fitSession, settings: base, target: target, options: options,
                                  photoFaces: photoFaces, isCancelled: { latest.current != generation })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.latest.current == generation else { return }
                    self.isMatching = false
                    self.match = result
                    self.fittedTarget = target
                    self.fitMessage = result.map { Self.message(for: $0.notices) } ?? "This photo can't be matched."
                    self.renderPreview()
                }
            }
        }
    }

    private var lookAreas: LookAreas {
        switch areaMode {
        case .wholePhoto: return .wholePhoto
        case .subject: return .subject
        case .boxes: return .boxes(reference: referenceArea, photo: photoArea)
        }
    }

    /// What to tell the user about a match that couldn't do all it was asked.
    static func message(for notices: Set<LookMatchNotice>) -> String? {
        var parts: [String] = []
        if notices.contains(.noSubjectInReference) {
            parts.append("No subject found in the reference, so the whole photo was matched.")
        } else if notices.contains(.noSubjectInPhoto) {
            parts.append("No subject found in your photo, so the whole photo was matched.")
        }
        if notices.contains(.noFaces) { parts.append("No usable face skin found in your photo to protect.") }
        if notices.contains(.noSkinInPhoto) { parts.append("No usable face skin in your photo.") }
        if notices.contains(.noSkinInReference) { parts.append("No usable face skin in the reference.") }
        if notices.contains(.skinMatchLimited) { parts.append("The skin sliders could not bring the face color closer.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The preview at the current strength. Latest wins, as in Develop.
    private func renderPreview() {
        guard let previewSession else { return }
        if previewRendering {
            previewPending = true
            return
        }
        previewRendering = true
        let generation = latest.current
        let settings = match?.settings(strength: strength / 100) ?? base
        previewQueue.async {
            let cgImage = previewSession.render(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.previewRendering = false
                    if self.latest.current == generation, let cgImage {
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
        guard canApply, let match, let library, let fittedTarget else { return }
        let strength = self.strength / 100
        let step = "Match Look: \(referenceName ?? "Reference")"
        guard strength > 0 else { return }
        let settings = match.settings(strength: strength)
        let firstPhotoChanged = settings != base
        if firstPhotoChanged {
            library.develop.apply(settings, onto: [assetID], step: step)
        }
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
            library.matchEach(others, target: fittedTarget, options: options, strength: strength, step: step,
                              firstPhotoChanged: firstPhotoChanged)
        }
    }
}

/// The reference's Vision results (subject mask, faces), found once per reference image and read
/// from the fitting queue.
final class FeatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var found: LookReferenceFeatures?

    func features(for reference: CGImage) -> LookReferenceFeatures {
        lock.lock()
        if image === reference, let found {
            lock.unlock()
            return found
        }
        lock.unlock()
        let features = LookReferenceFeatures(image: reference)
        lock.lock()
        image = reference
        found = features
        lock.unlock()
        return features
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
    func matchEach(_ ids: [Int64], target: LookTarget, options: LookMatchOptions, strength: Double,
                   step: String, firstPhotoChanged: Bool) {
        let total = ids.count
        matchProgress = ImportStatus(phase: "Matching 1 of \(total)", fraction: 0)
        matchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var matched = firstPhotoChanged ? 1 : 0, unchanged = firstPhotoChanged ? 0 : 1
            var failed = 0, skinFallbacks = 0
            for (index, id) in ids.enumerated() {
                if Task.isCancelled { break }
                let found: (URL, DevelopSettings)? = await MainActor.run { [weak self] in
                    guard let self else { return nil }
                    self.matchProgress = ImportStatus(phase: "Matching \(index + 1) of \(total)",
                                                      fraction: Double(index) / Double(total))
                    guard let url = try? self.catalog.fileURL(for: id),
                          let settings = try? self.catalog.developSettings(for: id) else { return nil }
                    return (url, settings)
                }
                guard let found,
                      let session = DevelopRenderer.shared.session(for: found.0, maxPixelSize: LookSample.size)
                else {
                    failed += 1
                    continue
                }
                let faces: [CGRect]? = options.skinMode == .off ? nil :
                    DevelopRenderer.shared.session(for: found.0, maxPixelSize: MatchLookModel.previewSize)?
                    .renderSRGB(found.1).map { LookSkin.faces(in: $0) }
                guard let match = LookMatcher.match(session: session, settings: found.1, target: target,
                                                    options: options, photoFaces: faces,
                                                    isCancelled: { Task.isCancelled }) else {
                    if Task.isCancelled { break }
                    failed += 1
                    continue
                }
                let settings = match.settings(strength: strength)
                let saved = await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return false }
                    // The photo may have been edited while its match was running.
                    if self.develop.assetID == id {
                        self.develop.flushSave()
                        guard self.develop.settings == found.1 else { return false }
                    }
                    guard (try? self.catalog.developSettings(for: id)) == found.1 else { return false }
                    guard settings != found.1 else { return true }
                    do {
                        try self.catalog.saveDevelopSettings(settings, for: id, step: step)
                    } catch {
                        return false
                    }
                    if self.develop.assetID == id { self.develop.reopen() }
                    self.develop.refreshPreviews(for: id, settings: settings)
                    return true
                }
                if Task.isCancelled && !saved { break }
                if saved {
                    if settings != found.1 { matched += 1 } else { unchanged += 1 }
                    if !match.notices.isDisjoint(with: [.noSkinInPhoto, .noSkinInReference, .skinMatchLimited]) {
                        skinFallbacks += 1
                    }
                } else {
                    failed += 1
                }
            }
            var parts = ["Matched \(matched) photo\(matched == 1 ? "" : "s")"]
            if unchanged > 0 { parts.append("\(unchanged) unchanged") }
            if skinFallbacks > 0 {
                parts.append("Skipped face color on \(skinFallbacks) additional photo\(skinFallbacks == 1 ? "" : "s")")
            }
            if failed > 0 { parts.append("\(failed) unavailable, changed during the match, or could not be saved") }
            if Task.isCancelled { parts.insert("Match cancelled", at: 0) }
            let status = parts.joined(separator: ", ")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = status
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
