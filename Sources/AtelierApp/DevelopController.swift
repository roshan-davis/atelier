import AppKit
import AtelierCore
import Foundation

/// How the Develop view shows the photo before edits next to the edited one.
enum CompareMode: String, CaseIterable {
    case off, sideBySide, slider

    var label: String {
        switch self {
        case .off: return "Off"
        case .sideBySide: return "Side by Side"
        case .slider: return "Slider"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .slider: return "rectangle.lefthalf.inset.filled"
        }
    }
}

/// State for the Develop view: the open photo's settings, its live proxy render, and saving.
///
/// Rendering is "latest wins": while one render runs, further slider changes collapse into a
/// single follow-up render, so dragging a slider never queues up stale frames.
@MainActor
final class DevelopController: ObservableObject {
    /// Long edge of the live proxy, per the PRD.
    nonisolated static let proxySize = 2560

    @Published private(set) var assetID: Int64?
    @Published private(set) var settings = DevelopSettings()
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var asShotTemperature: Double = 5500
    @Published var showingBefore = false {
        didSet { if showingBefore != oldValue { scheduleRender() } }
    }

    @Published var compareMode: CompareMode = .off {
        didSet { if compareMode != .off { renderBeforeIfNeeded() } }
    }
    /// The photo without edits, rendered once per open photo for the compare views.
    @Published private(set) var beforeImage: NSImage?
    /// Where the slider divides before (left) and after (right), 0...1.
    @Published var sliderPosition = 0.5

    @Published private(set) var histogram: Histogram?

    /// Set while the photo is zoomed past fit; renders the full-resolution image as well.
    @Published var wantsFullResolution = false {
        didSet { if wantsFullResolution, !oldValue { scheduleFullRender() } }
    }
    @Published private(set) var fullImage: NSImage?
    private var fullImageSettings: DevelopSettings?
    private var fullSession: DevelopSession?
    private var sourceURL: URL?
    private var fullRendering = false
    private var fullNeedsRender = false
    private let fullQueue = DispatchQueue(label: "atelier.develop.full", qos: .userInitiated)

    /// The sharpest image that matches the current settings.
    var displayImage: NSImage? {
        if !showingBefore, let fullImage, fullImageSettings == settings { return fullImage }
        return image
    }

    /// Copy/paste settings clipboard, shared across photos.
    @Published private(set) var clipboard: DevelopSettings?

    private let catalog: Catalog
    private let previews: PreviewCache
    private var session: DevelopSession?
    private var rendering = false
    private var needsRender = false
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private let queue = DispatchQueue(label: "atelier.develop", qos: .userInteractive)
    var onPreviewsUpdated: ((Int64) -> Void)?

    init(catalog: Catalog, previews: PreviewCache) {
        self.catalog = catalog
        self.previews = previews
    }

    // MARK: Opening

    func open(_ assetID: Int64?) {
        guard assetID != self.assetID else { return }
        flushSave()
        self.assetID = assetID
        session = nil
        image = nil
        beforeImage = nil
        histogram = nil
        fullImage = nil
        fullImageSettings = nil
        fullSession = nil
        sourceURL = nil
        errorMessage = nil
        showingBefore = false
        guard let assetID else { return }

        settings = (try? catalog.developSettings(for: assetID)) ?? .neutral
        // Show the cached preview immediately while the editable proxy decodes.
        let cachedPreview = previews.url(for: assetID, size: .preview)
        if previews.has(.preview, for: assetID) { image = NSImage(contentsOf: cachedPreview) }

        guard let url = try? catalog.fileURL(for: assetID) else {
            errorMessage = "The original is offline. Connect its drive to edit this photo."
            return
        }
        sourceURL = url
        isLoading = true
        queue.async {
            let session = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.proxySize)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID else { return }
                    self.isLoading = false
                    guard let session else {
                        self.errorMessage = "This file can't be opened for editing."
                        return
                    }
                    self.session = session
                    self.asShotTemperature = session.asShotTemperature
                    self.scheduleRender()
                    if self.compareMode != .off { self.renderBeforeIfNeeded() }
                }
            }
        }
    }

    func cycleCompareMode() {
        let all = CompareMode.allCases
        compareMode = all[(all.firstIndex(of: compareMode)! + 1) % all.count]
    }

    // MARK: Editing

    func value(_ parameter: DevelopSettings.Parameter) -> Double {
        if parameter == .temperature, settings.temperature == nil { return asShotTemperature }
        return settings[parameter]
    }

    func set(_ parameter: DevelopSettings.Parameter, to value: Double) {
        guard assetID != nil else { return }
        settings[parameter] = value
        changed()
    }

    func reset(_ parameter: DevelopSettings.Parameter) {
        guard assetID != nil else { return }
        switch parameter {
        case .temperature: settings.temperature = nil
        default: settings[parameter] = DevelopSettings.neutral[parameter]
        }
        changed()
    }

    func reset(_ panel: DevelopSettings.Panel) {
        guard assetID != nil else { return }
        for parameter in panel.parameters {
            if parameter == .temperature {
                settings.temperature = nil
            } else {
                settings[parameter] = DevelopSettings.neutral[parameter]
            }
        }
        changed()
    }

    func isModified(_ panel: DevelopSettings.Panel) -> Bool {
        panel.parameters.contains { parameter in
            parameter == .temperature ? settings.temperature != nil
                : settings[parameter] != DevelopSettings.neutral[parameter]
        }
    }

    func resetAll() {
        guard assetID != nil else { return }
        settings = .neutral
        changed()
    }

    func copySettings() {
        clipboard = settings
    }

    func copySettings(of assetID: Int64) {
        clipboard = (try? catalog.developSettings(for: assetID)) ?? .neutral
    }

    /// Pastes onto the open photo, or onto every photo in `assetIDs` when given.
    func pasteSettings(onto assetIDs: [Int64]? = nil) {
        guard let clipboard else { return }
        apply(clipboard, onto: assetIDs)
    }

    /// Clears all edits on the photos (Lightroom's Reset).
    func resetSettings(of assetIDs: [Int64]) {
        apply(.neutral, onto: assetIDs)
    }

    private func apply(_ newSettings: DevelopSettings, onto assetIDs: [Int64]?) {
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        for id in targets where id != assetID {
            try? catalog.saveDevelopSettings(newSettings, for: id)
            refreshPreviews(for: id, settings: newSettings)
        }
        if let assetID, targets.contains(assetID) {
            settings = newSettings
            changed()
        }
    }

    private func changed() {
        dirty = true
        scheduleRender()
        scheduleSave()
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard let session else { return }
        if rendering {
            needsRender = true
            return
        }
        rendering = true
        let settings = showingBefore ? DevelopSettings.neutral : self.settings
        let assetID = self.assetID
        queue.async {
            let cgImage = session.render(settings)
            let histogram = cgImage.flatMap { Histogram(image: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.rendering = false
                    if self.assetID == assetID, let cgImage {
                        self.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.histogram = histogram
                    }
                    if self.needsRender {
                        self.needsRender = false
                        self.scheduleRender()
                    } else {
                        self.scheduleFullRender()
                    }
                }
            }
        }
    }

    /// Full-resolution render for zoomed views, after the proxy settles. Latest wins.
    private func scheduleFullRender() {
        guard wantsFullResolution, !showingBefore, let url = sourceURL, fullImageSettings != settings else { return }
        if fullRendering {
            fullNeedsRender = true
            return
        }
        fullRendering = true
        let settings = self.settings
        let assetID = self.assetID
        let existing = fullSession
        fullQueue.async {
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: nil)
            let cgImage = session?.render(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fullRendering = false
                    guard self.assetID == assetID, let session else { return }
                    self.fullSession = session
                    if let cgImage {
                        self.fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.fullImageSettings = settings
                    }
                    if self.fullNeedsRender {
                        self.fullNeedsRender = false
                        if !self.rendering { self.scheduleFullRender() }
                    }
                }
            }
        }
    }

    private func renderBeforeIfNeeded() {
        guard beforeImage == nil, let session else { return }
        let assetID = self.assetID
        queue.async {
            let cgImage = session.render(.neutral)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, let cgImage else { return }
                    self.beforeImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// Writes pending settings and refreshes the grid thumbnail and loupe preview.
    func flushSave() {
        saveTask?.cancel()
        guard dirty, let assetID else { return }
        dirty = false
        let settings = self.settings
        do {
            try catalog.saveDevelopSettings(settings, for: assetID)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        if let session {
            let previews = self.previews
            queue.async {
                if let cgImage = session.render(settings) {
                    try? previews.store(cgImage, for: assetID, size: .preview)
                    try? previews.store(cgImage, for: assetID, size: .thumbnail)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onPreviewsUpdated?(assetID) }
                }
            }
        }
    }

    /// Re-renders previews for a photo that is not open, after pasting settings onto it.
    private func refreshPreviews(for assetID: Int64, settings: DevelopSettings) {
        guard let url = try? catalog.fileURL(for: assetID) else { return }
        let previews = self.previews
        DispatchQueue.global(qos: .utility).async {
            guard let session = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.proxySize),
                  let cgImage = session.render(settings) else { return }
            try? previews.store(cgImage, for: assetID, size: .preview)
            try? previews.store(cgImage, for: assetID, size: .thumbnail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onPreviewsUpdated?(assetID) }
            }
        }
    }
}
