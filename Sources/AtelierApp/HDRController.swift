import AppKit
import Combine
import SwiftUI
import AtelierHDRCore
import AtelierCore

/// Atelier's HDR mode (Library > HDR, Photo > HDR…, ⌃H): tone-maps one photo's original pixels
/// and saves a profiled 16-bit TIFF, stacked with the source, plus an HDR project that reopens
/// the sliders. Opened on the focused photo, like Develop; the HDR TIFF reopens its project.
///
/// Until the first Save nothing is written: no project, no source copy. Save renders at full
/// size in the background and registers the TIFF in the catalog in one transaction
/// (`Catalog.acceptProcessorResult`), with the same request and result identity checks the
/// separate HDR app used before HDR became a mode (Rosh, Nov 12, 2026).
@MainActor
final class HDRController: ObservableObject {
    @Published var settings = HDRSettings()
    @Published private(set) var before: NSImage?
    @Published private(set) var after: NSImage?
    @Published private(set) var pixelSize: CGSize?
    /// Changing photo: the last photo's picture and size stay on screen until the next one's
    /// After is rendered, then it goes on once (the shared rule, `PhotoChangeHold`, as in Develop
    /// and Loupe). Opening a photo in HDR decodes its original, so past the hold's limit a spinner
    /// shows over the last photo rather than the empty background.
    @Published private(set) var heldPicture: NSImage?
    @Published private(set) var heldPixelSize: CGSize?
    let photoHold = PhotoChangeHold(limit: 1.0)
    private var holdObserver: AnyCancellable?
    /// Saving: the controls are locked and Esc cancels.
    @Published private(set) var busy = false
    /// Opening a photo or project.
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var sourceName = ""
    @Published private(set) var dirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Before and After, as in Develop (Y cycles, \ shows the original).
    @Published var compareMode: CompareMode = .off
    @Published var showingBefore = false
    @Published var sliderPosition = 0.5
    /// The photo the mode was opened on: the source, or the HDR TIFF whose project is open.
    @Published private(set) var assetID: Int64?
    /// The HDR TIFF in the catalog, once this session has one.
    @Published private(set) var resultAssetID: Int64?
    /// The saved project's revision; 0 until the first Save.
    @Published private(set) var revision = 0
    /// Whether the open project's own source copy is missing or changed, so Relink Source helps.
    @Published private(set) var needsRelink = false
    /// The Source panel's Exposures strip: the photo at −spacing, 0 and +spacing EV (Fusion's
    /// three exposures), small. Empty until made.
    @Published private(set) var plates: [NSImage] = []
    /// The Presets panel: the user's presets, then the built-in ones (`HDRController+Presets`).
    @Published var presets: [HDRPreset] = []
    /// Each preset's look on this photo, small, by preset id. Empty until made.
    @Published var presetThumbnails: [UUID: NSImage] = [:]
    /// The preset the pointer rests on, previewed on the photo without changing the settings.
    @Published var previewSettings: HDRSettings?

    private(set) weak var model: LibraryModel?
    let zoom: ZoomState
    private var input: HDRImage?
    private var detailInput: HDRImage?
    private var detailLoading = false
    private var sourceURL: URL?
    private var store: HDRProjectStore?
    /// The session's identity: source asset and hash, project location and, after the first
    /// Save, project and output IDs. Never written to disk; the catalog checks results against it.
    private var request: ProcessorDocument?
    private var openTask: Task<Void, Never>?
    /// The original's SHA-256, found in the background while the photo already shows (AT-076
    /// P4: on a NAS the whole file is read for it). Save waits for it: the project is made only
    /// from the exact source that was opened.
    private var sourceHash: Task<String, Error>?
    private var saveTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderRevision = 0
    private var undoStack: [HDRSettings] = []
    private var redoStack: [HDRSettings] = []
    private var gestureStart: HDRSettings?
    private var savedSettings: HDRSettings?
    private var confirming = false
    /// The tone mapper's exposure analysis of the photo shown, and its GPU upload; see `render()`.
    private let previewCache = HDRPreviewCache()
    /// Changes whenever another photo or project is shown, so an analysis can't outlive it.
    private var inputToken = 0
    /// One Core Image context for every CPU preview, rather than one per render.
    private let previewIO = HDRImageIO()
    /// Live slider frames go straight onto the After photo (`PhotoFeed`), as in Develop.
    let photoFeed = PhotoFeed()
    private lazy var liveFrames = HDRLiveFrames(cache: previewCache, sink: photoFeed.sink,
                                                onMiss: { [weak self] in self?.liveFrameMissed() })
    /// Counts live frames and published images together, so neither replaces a newer one.
    private var renderCount = 0
    /// The Exposures strip: one made at a time, then the latest Exposure and spacing.
    private struct PlatesKey: Equatable { var token: Int; var exposure: Float; var spacing: Float }
    private var platesTask: Task<Void, Never>?
    private var platesShown: PlatesKey?
    let presetStore = HDRPresetStore(fileURL: HDRPresetStore.defaultURL)
    /// The preset thumbnails: what they were made for, and the one being made.
    struct ThumbnailsKey: Equatable { var token: Int; var exposure: Float; var presets: [HDRPreset] }
    var thumbnailsTask: Task<Void, Never>?
    var thumbnailsShown: ThumbnailsKey?

    init(model: LibraryModel) {
        self.model = model
        zoom = model.zoomState
        presets = presetStore.all()
        // The photo view watches this controller: tell it when the hold's limit passes.
        holdObserver = photoHold.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// What the photo shows: the preset the pointer rests on, otherwise the settings.
    var displayedSettings: HDRSettings { previewSettings ?? settings }

    /// The photo open in HDR, at the 1600 px proxy size (the preset thumbnails are made from it).
    var proxyInput: HDRImage? { input }
    /// Changes whenever another photo or project is shown.
    var currentInputToken: Int { inputToken }
    var thumbnailIO: HDRImageIO { previewIO }

    var hasPhoto: Bool { before != nil }
    var projectURL: URL? { request?.projectURL }

    // MARK: Opening

    /// Opens a photo: its HDR project when it is an HDR TIFF, otherwise a new session on its
    /// original. Opening the photo already open (or its result) does nothing.
    func open(_ id: Int64?) {
        guard id != assetID || (id != nil && before == nil && !isLoading) else { return }
        if let id, id == resultAssetID { return }
        // Another photo: the one on screen stays until this one's After is in.
        if id != nil, let shown = heldPicture ?? after ?? before {
            heldPicture = shown
            heldPixelSize = heldPixelSize ?? pixelSize
            photoHold.begin()
        }
        close(keepingHeldPicture: true)
        if id == nil { releaseHeldPicture() }
        guard let id, let model else { return }
        assetID = id
        isLoading = true
        sourceName = model.detail?.asset.filename ?? ""
        let catalog = model.catalog
        openTask = Task {
            do {
                if let association = try await Task.detached(operation: { try catalog.processorAssociation(for: id) }).value {
                    try await openProject(association, assetID: id, catalog: catalog)
                } else {
                    try await openOriginal(id, catalog: catalog)
                }
            } catch is CancellationError {
            } catch {
                guard assetID == id else { return }
                isLoading = false
                releaseHeldPicture()
                self.error = error.localizedDescription
            }
        }
    }

    /// A new session reads the original; the project and its source copy are made on first Save.
    private func openOriginal(_ id: Int64, catalog: Catalog) async throws {
        let source = try await Task.detached { () -> URL in
            guard let source = try catalog.fileURL(for: id) else {
                throw ExportError("The original is offline. Reconnect its drive to open it in HDR.")
            }
            return source
        }.value
        try Task.checkCancellation()
        guard assetID == id else { return }
        // The hash reads the whole file alongside the decode; the photo doesn't wait for it.
        let hash = Task.detached(priority: .utility) { try FileHasher.sha256(of: source) }
        sourceHash = hash
        let loaded = try await Task.detached { () -> (ProcessorDocument, HDRImage, CGImage, CGSize) in
            let stem = source.deletingPathExtension().lastPathComponent + "-HDR-" + UUID().uuidString.prefix(8)
            let projectURL = DerivedFiles.folder(for: source).appendingPathComponent(stem).appendingPathExtension("atelierhdr")
            // The hash is filled in once found (`save` waits for it).
            let request = ProcessorDocument(sourceAssetID: id, sourceURL: source, sourceHash: "", projectURL: projectURL)
            let io = HDRImageIO(), image = try io.decode(source, longEdge: 1600)
            try Task.checkCancellation()
            return (request, image, try io.preview(image), try HDRImageIO.dimensions(source))
        }.value
        try Task.checkCancellation()
        guard assetID == id else { return }
        request = loaded.0; sourceURL = loaded.0.sourceURL; store = nil
        sourceName = loaded.0.sourceURL.lastPathComponent
        show(input: loaded.1, preview: loaded.2, pixelSize: loaded.3, settings: HDRSettings(), saved: HDRSettings(), revision: 0)
        model?.status = "HDR works on the original's pixels. Save creates the TIFF and its HDR project."
    }

    /// An HDR TIFF: reopens its project with the sliders where they were saved.
    private func openProject(_ association: ProcessorAssociation, assetID id: Int64, catalog: Catalog,
                             restoring unsaved: HDRSettings? = nil) async throws {
        do {
            let loaded = try await Task.detached { () -> (HDRProjectStore, HDRProjectManifest, HDRImage, CGImage, URL, CGSize) in
                let store = try HDRProjectStore.open(association.projectURL), manifest = await store.manifest
                guard manifest.projectID == association.projectID, manifest.outputID == association.outputID else {
                    throw ProcessorDocumentError.invalidRequest
                }
                // Puts back the public TIFF from the saved generation if a save was interrupted.
                try await store.publish()
                let source = await store.sourceURL(), io = HDRImageIO()
                let input = try io.decode(source, longEdge: 1600)
                try Task.checkCancellation()
                return (store, manifest, input, try io.preview(input), source, try HDRImageIO.dimensions(source))
            }.value
            try Task.checkCancellation()
            guard assetID == id else { return }
            let original = try? await Task.detached { try catalog.fileURL(for: association.sourceAssetID) }.value
            var request = ProcessorDocument(sourceAssetID: association.sourceAssetID,
                                            sourceURL: original ?? loaded.4, sourceHash: association.sourceHash,
                                            projectURL: association.projectURL,
                                            expectedProjectID: association.projectID, outputID: association.outputID)
            request.hostProcessID = nil; request.hostBundleURL = nil
            self.request = request; store = loaded.0; sourceURL = loaded.4; resultAssetID = id
            sourceName = (original ?? association.projectURL).deletingPathExtension().lastPathComponent
            needsRelink = false
            show(input: loaded.2, preview: loaded.3, pixelSize: loaded.5, settings: unsaved ?? loaded.1.settings,
                 saved: loaded.1.settings, revision: loaded.1.revision)
        } catch HDRError.invalidProject(let message) {
            guard assetID == id else { return }
            // The project is there but its private source copy is missing or changed.
            var request = ProcessorDocument(sourceAssetID: association.sourceAssetID, sourceURL: association.projectURL,
                                            sourceHash: association.sourceHash, projectURL: association.projectURL,
                                            expectedProjectID: association.projectID, outputID: association.outputID)
            request.hostProcessID = nil; request.hostBundleURL = nil
            self.request = request; resultAssetID = id; needsRelink = true
            throw HDRError.invalidProject(message)
        }
    }

    private func show(input: HDRImage, preview: CGImage, pixelSize: CGSize, settings: HDRSettings,
                      saved: HDRSettings, revision: Int) {
        self.input = input; detailInput = nil; previewCache.reset(); inputToken += 1
        photoFeed.sink.invalidate()
        before = NSImage(cgImage: preview, size: .zero); after = nil
        self.pixelSize = pixelSize
        self.settings = settings; savedSettings = saved; self.revision = revision
        undoStack = []; redoStack = []; updateHistory()
        dirty = settings != saved
        isLoading = false
        render()
        updatePlates()
        updatePresetThumbnails()
        if case .percent(let percent) = zoom.level, percent >= 100 { zoomChanged() }
    }

    /// Leaves the photo: frees its images. Unsaved changes are the caller's to confirm first.
    /// The next photo is on screen: the last one goes.
    private func releaseHeldPicture() {
        guard heldPicture != nil else { return }
        heldPicture = nil
        heldPixelSize = nil
        photoHold.end(because: nil)
    }

    func close(keepingHeldPicture: Bool = false) {
        if !keepingHeldPicture { releaseHeldPicture() }
        openTask?.cancel(); openTask = nil
        renderTask?.cancel(); renderTask = nil
        renderRevision += 1
        sourceHash?.cancel(); sourceHash = nil
        assetID = nil; resultAssetID = nil; request = nil; store = nil; sourceURL = nil
        input = nil; detailInput = nil; detailLoading = false; previewCache.reset(); inputToken += 1
        photoFeed.sink.invalidate()
        before = nil; after = nil; pixelSize = nil
        plates = []; platesShown = nil
        presetThumbnails = [:]; thumbnailsShown = nil; previewSettings = nil
        settings = HDRSettings(); savedSettings = nil; revision = 0
        undoStack = []; redoStack = []; updateHistory()
        dirty = false; isLoading = false; needsRelink = false; showingBefore = false; error = nil
    }

    /// Relink Source…: a byte-identical copy of the original replaces the project's missing or
    /// changed source copy. Unsaved slider changes are kept.
    func relinkSource() {
        guard let request, let id = assetID, !busy, let model else { return }
        let panel = NSOpenPanel(); panel.title = "Relink HDR Source"; panel.prompt = "Verify and Relink"
        panel.message = "Choose an identical copy of \(sourceName). Its contents are checked before it is used."
        guard panel.runModal() == .OK, let replacement = panel.url else { return }
        let unsaved = dirty ? settings : nil
        let projectURL = request.projectURL, catalog = model.catalog
        isLoading = true; error = nil
        openTask = Task {
            do {
                try await Task.detached { try HDRProjectStore.relink(projectURL, from: replacement) }.value
                guard let association = try await Task.detached(operation: { try catalog.processorAssociation(for: id) }).value else {
                    throw ProcessorDocumentError.invalidRequest
                }
                try await openProject(association, assetID: id, catalog: catalog, restoring: unsaved)
            } catch is CancellationError {
            } catch { isLoading = false; self.error = error.localizedDescription }
        }
    }

    // MARK: Editing

    func binding(_ key: WritableKeyPath<HDRSettings, Float>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: key]) }, set: { value in
            let old = self.settings
            self.settings[keyPath: key] = Float(value)
            // Moving a control turns its panel back on, as in Develop.
            self.settings.toneEnabled = true
            if self.gestureStart == nil, old != self.settings { self.undoStack.append(old); self.redoStack = [] }
            self.changed()
        })
    }

    /// A slider drag is one undo step.
    func gesture(_ active: Bool) {
        if active { gestureStart = settings }
        else if let previous = gestureStart {
            gestureStart = nil
            if previous != settings { undoStack.append(previous); redoStack = [] }
            updateHistory()
            // The drag drew live frames (and, zoomed in, the proxy): now the ordinary image,
            // at full size when zoomed to 100% or closer.
            render()
        }
    }

    static let toneKeys: [WritableKeyPath<HDRSettings, Float>] = [\.exposure, \.compression, \.fusionSpacing,
                                                                  \.highlights, \.shadows, \.microcontrast, \.detail,
                                                                  \.temperature, \.vibrance, \.saturation]
    static let colorKeys: [WritableKeyPath<HDRSettings, Float>] = [\.temperature, \.vibrance, \.saturation]
    static let regionKeys: [WritableKeyPath<HDRSettings, Float>] = [\.highlights, \.shadows]
    static let textureKeys: [WritableKeyPath<HDRSettings, Float>] = [\.microcontrast, \.detail]

    /// Reset All, and the Tone Mapping header's reset: every slider, the Method and both Exposures back in.
    func reset() { reset(Self.toneKeys, method: true) }
    func reset(_ keys: [WritableKeyPath<HDRSettings, Float>], method: Bool = false) {
        let old = settings, defaults = HDRSettings()
        for key in keys { settings[keyPath: key] = defaults[keyPath: key] }
        if method {
            settings.method = defaults.method
            settings.fusionUsesDarker = true; settings.fusionUsesBrighter = true
        }
        guard old != settings else { return }
        undoStack.append(old); redoStack = []; changed()
    }

    func isModified(_ keys: [WritableKeyPath<HDRSettings, Float>], method: Bool = false) -> Bool {
        let defaults = HDRSettings()
        return (method && (settings.method != defaults.method || !settings.fusionUsesDarker || !settings.fusionUsesBrighter)) || keys.contains { settings[keyPath: $0] != defaults[keyPath: $0] }
    }

    /// The Method menu (Natural, Fusion): one undo step per choice, and it turns the panel on.
    var methodBinding: Binding<HDRMethod> {
        Binding(get: { self.settings.method }, set: { value in
            let old = self.settings
            self.settings.method = value
            self.settings.toneEnabled = true
            if old != self.settings { self.undoStack.append(old); self.redoStack = []; self.changed() }
        })
    }

    func switchBinding(_ key: WritableKeyPath<HDRSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: key] }, set: { value in
            let old = self.settings; self.settings[keyPath: key] = value
            if old != self.settings { self.undoStack.append(old); self.redoStack = []; self.changed() }
        })
    }

    /// One undo step from `old` to the current settings (a preset applied).
    func recordStep(from old: HDRSettings) {
        guard old != settings else { return }
        undoStack.append(old); redoStack = []
    }

    func undo() {
        guard !busy, let previous = undoStack.popLast() else { return }
        redoStack.append(settings); settings = previous; changed()
    }
    func redo() {
        guard !busy, let next = redoStack.popLast() else { return }
        undoStack.append(settings); settings = next; changed()
    }
    func cycleCompareMode() {
        let all = CompareMode.allCases
        compareMode = all[((all.firstIndex(of: compareMode) ?? 0) + 1) % all.count]
    }
    private func updateHistory() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
    func changed() {
        dirty = settings != savedSettings; updateHistory(); render(); updatePlates(); updatePresetThumbnails()
    }

    /// Done: back to the view HDR was opened from (Esc does the same).
    func done() { model?.closeHDR() }

    /// Puts the sliders back to the last Save (or the defaults, before one).
    func discardChanges() {
        guard dirty else { return }
        settings = savedSettings ?? HDRSettings(); undoStack = []; redoStack = []; changed()
    }

    // MARK: Rendering

    /// One render in flight, with only the latest settings followed up. Old results never flash.
    ///
    /// Smoothness (Rosh, Nov 12, 2026): while a slider is held, frames are drawn on the GPU
    /// straight into the After photo from a queue of their own (`HDRLiveFrames`), from the 1600 px
    /// proxy even when zoomed in, like Develop's drafts. The exposure analysis is kept between
    /// renders (`HDRPreviewCache`), so only Exposure recomputes it. When the slider is let go (or
    /// for a click, a typed value or a key) the ordinary image is published: the proxy from the
    /// same GPU kernel, or the full-size original from the CPU at 100% and closer.
    func render() {
        renderRevision += 1
        guard let proxy = input else { return }
        if gestureStart != nil, previewSettings == nil, !showingBefore, photoFeed.isAttached, HDRPreviewRenderer.shared != nil {
            renderCount += 1
            liveFrames.submit(.init(input: proxy, settings: settings, token: inputToken, count: renderCount,
                                    epoch: photoFeed.sink.currentEpoch))
            return
        }
        renderImage()
    }

    /// Remakes the Exposures strip when the photo, Exposure or spacing changed. One is made at a
    /// time (a few milliseconds at 240 px); a drag meanwhile is followed by one for its latest value.
    private func updatePlates() {
        guard let proxy = input else { plates = []; platesShown = nil; return }
        let key = PlatesKey(token: inputToken, exposure: settings.exposure, spacing: settings.fusionSpacing)
        guard key != platesShown, platesTask == nil else { return }
        let io = previewIO
        platesTask = Task {
            let made = try? await Task.detached { () -> [CGImage] in
                try HDRToneMapper.exposurePlates(proxy, exposure: key.exposure, spacing: key.spacing, longEdge: 240)
                    .map { try io.preview($0) }
            }.value
            platesTask = nil
            if key.token == inputToken {
                plates = (made ?? []).map { NSImage(cgImage: $0, size: .zero) }
                platesShown = key
            }
            updatePlates()
        }
    }

    /// A live frame couldn't be shown: draw the ordinary image instead.
    private func liveFrameMissed() {
        guard input != nil else { return }
        renderImage()
    }

    /// The ordinary image, published as `after`.
    private func renderImage() {
        guard renderTask == nil, let proxy = input else { return }
        let useDetail: Bool
        if case .percent(let percent) = zoom.level { useDetail = percent >= 100 && gestureStart == nil } else { useDetail = false }
        let input = useDetail ? (detailInput ?? proxy) : proxy
        let isProxy = input.width == proxy.width && input.height == proxy.height
        renderCount += 1
        let snapshot = displayedSettings, revision = renderRevision, io = previewIO, token = inputToken
        let cache = previewCache, count = renderCount
        renderTask = Task {
            do {
                let result = try await Task.detached { () -> CGImage in
                    // The proxy: the same GPU kernel as the live frames, so letting go of a
                    // slider doesn't change the picture.
                    if isProxy, let renderer = HDRPreviewRenderer.shared,
                       let source = try cache.source(input, exposure: snapshot.exposure, token: token),
                       let image = renderer.image(source, settings: snapshot), let picture = renderer.cgImage(image) {
                        return picture
                    }
                    var prepared: HDRToneMapper.Analysis?
                    if snapshot.toneEnabled {
                        prepared = try cache.analysis(input, exposure: snapshot.exposure, token: token, keep: isProxy)
                    }
                    let rendered = try HDRToneMapper.render(input, settings: snapshot, analysis: prepared)
                    return try io.preview(rendered)
                }.value
                if token == inputToken, displayedSettings == snapshot, revision == renderRevision {
                    let image = NSImage(cgImage: result, size: .zero)
                    photoFeed.published(image, count: count)
                    after = image
                    releaseHeldPicture()
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            guard revision <= renderRevision, self.input != nil else { renderTask = nil; return }
            renderTask = nil
            if displayedSettings != snapshot || revision != renderRevision { render() }
        }
    }

    /// At 100% and closer the full-size original is decoded once, so detail is judged on real pixels.
    func zoomChanged() {
        guard case .percent(let percent) = zoom.level, percent >= 100,
              detailInput == nil, !detailLoading, let sourceURL, input != nil else { render(); return }
        detailLoading = true
        model?.status = "Loading full-resolution detail…"
        Task {
            do {
                let decoded = try await Task.detached { () -> (HDRImage, CGImage) in
                    let io = HDRImageIO(), full = try io.decode(sourceURL)
                    return (full, try io.preview(full))
                }.value
                if self.sourceURL == sourceURL, input != nil {
                    detailInput = decoded.0
                    before = NSImage(cgImage: decoded.1, size: .zero)
                    model?.status = "Full-resolution detail ready"
                    render()
                }
            } catch { self.error = error.localizedDescription }
            detailLoading = false
        }
    }

    // MARK: Saving

    /// Save (⌘S) writes the full-size TIFF and the project and updates the same photo in the
    /// catalog; Save As New (⇧⌘S) forks a new project and a new TIFF. `done` gets whether it saved.
    func save(asNew: Bool = false, done: ((Bool) -> Void)? = nil) {
        guard !busy, let request, let sourceURL, let model, !needsRelink else { done?(false); return }
        var destination: URL?
        if asNew {
            let panel = NSSavePanel(); panel.title = "Save HDR As New"
            panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + "-HDR.atelierhdr"
            panel.directoryURL = request.projectURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { done?(false); return }
            destination = url.pathExtension == "atelierhdr" ? url : url.appendingPathExtension("atelierhdr")
        }
        let snapshot = settings, store = self.store, catalog = model.catalog, opened = assetID
        let pendingHash = request.sourceHash.isEmpty ? sourceHash : nil
        busy = true
        model.status = pendingHash == nil ? "Saving HDR: rendering the full-resolution TIFF…"
            : "Saving HDR: checking the original, then rendering the full-resolution TIFF…"
        saveTask = Task {
            var newlyCreated: HDRProjectStore?
            var request = request
            do {
                if let pendingHash {
                    request.sourceHash = try await pendingHash.value
                    try Task.checkCancellation()
                    if assetID == opened, self.request?.jobID == request.jobID { self.request?.sourceHash = request.sourceHash }
                }
                let active: HDRProjectStore
                if let destination {
                    if let store { active = try await store.fork(to: destination) }
                    else { active = try await Self.createProject(at: destination, source: sourceURL, hash: request.sourceHash) }
                    newlyCreated = active
                } else if let store {
                    active = store
                } else {
                    active = try await Self.createProject(at: request.projectURL, source: sourceURL, hash: request.sourceHash)
                    newlyCreated = active
                }
                // Runs on the project's own actor, off the main thread; Cancel (Esc) reaches it
                // because it is awaited in this task rather than a detached one.
                let manifest = try await active.save(settings: snapshot, cancellation: { @Sendable in try Task.checkCancellation() })
                // Save As New is a new session: the earlier project and TIFF stay as they were.
                var publication = request
                if destination != nil { publication.jobID = UUID() }
                publication.projectURL = await active.url
                publication.expectedProjectID = manifest.projectID
                publication.outputID = manifest.outputID
                guard let resultHash = manifest.resultHash, let generationID = manifest.generationID else {
                    throw ProcessorDocumentError.invalidReceipt
                }
                let receipt = ProcessorReceipt(jobID: publication.jobID, projectID: manifest.projectID,
                    outputID: manifest.outputID, revision: manifest.revision, sourceHash: manifest.sourceHash,
                    resultHash: resultHash, generationID: generationID, width: manifest.width, height: manifest.height)
                let registered = try await Task.detached { try catalog.acceptProcessorResult(receipt, request: publication) }.value
                guard assetID == opened else { done?(true); busy = false; return }
                self.request = publication; self.store = active
                self.sourceURL = await active.sourceURL()
                savedSettings = snapshot; revision = manifest.revision
                dirty = settings != snapshot
                resultAssetID = registered
                busy = false
                finishSave(registered)
                done?(true)
            } catch {
                if let newlyCreated, (try? await newlyCreated.discardIfUnsaved()) != true,
                   await newlyCreated.manifest.revision > 0, destination == nil {
                    // The project saved but the catalog didn't take the TIFF: keep using it.
                    self.store = newlyCreated
                }
                busy = false
                if error is CancellationError {
                    model.status = "HDR save cancelled; the last saved TIFF and project are kept"
                } else {
                    self.error = error.localizedDescription
                    model.status = "The HDR save needs attention"
                }
                done?(false)
            }
        }
    }

    private static func createProject(at url: URL, source: URL, hash: String) async throws -> HDRProjectStore {
        try await Task.detached {
            guard try HDRProjectStore.hash(source) == hash else {
                throw HDRError.invalidProject("The original changed since it was opened in HDR. Open it again before saving.")
            }
            return try HDRProjectStore.create(at: url, source: source)
        }.value
    }

    /// The TIFF's thumbnails and Develop copy are rebuilt, and the HDR TIFF becomes the
    /// selected photo once the grid shows it (it is stacked with its source).
    private func finishSave(_ id: Int64) {
        guard let model else { return }
        if let url = try? model.catalog.fileURL(for: id) {
            let settings = (try? model.catalog.developSettings(for: id)) ?? .neutral
            model.previewScheduler.refresh(for: id, source: url, settings: settings)
        }
        model.develop.sourceChanged(id)
        model.status = "Saved the HDR TIFF, stacked with \(sourceName). Finish its color in Develop."
        Task {
            for _ in 0..<40 {
                if model.rows.contains(where: { $0.id == id }) {
                    if resultAssetID == id, model.mode == .hdr, model.focusedID != id {
                        model.selection = [id]; model.focusedID = id
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func cancel() { saveTask?.cancel() }

    // MARK: Leaving with unsaved changes

    /// Before HDR shows another photo, another mode takes over or Atelier quits: Save, Don't Save
    /// or Cancel, as in any Mac editor. `proceed` runs once it is safe to leave; `stay` when not.
    /// `canCancel` is false when there is no window left to stay in.
    func confirmLeaving(canCancel: Bool = true, asSheet: Bool = true,
                        proceed: @escaping () -> Void, stay: @escaping () -> Void = {}) {
        if busy {
            model?.status = "Saving the HDR TIFF. Wait for it to finish, or press Esc to cancel the save."
            NSSound.beep()
            stay(); return
        }
        guard dirty else { proceed(); return }
        // One question at a time: another photo or mode asked for meanwhile waits for this one.
        guard !confirming else { stay(); return }
        confirming = true
        let alert = NSAlert()
        alert.messageText = "Do you want to save the HDR changes to \(sourceName)?"
        alert.informativeText = revision > 0
            ? "If you don't save, the HDR TIFF keeps its last saved look."
            : "If you don't save, no HDR TIFF or project is made. The original is never changed."
        alert.addButton(withTitle: "Save")
        if canCancel { alert.addButton(withTitle: "Cancel") }
        alert.addButton(withTitle: "Don't Save")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.confirming = false
            switch response {
            case .alertFirstButtonReturn:
                self.save { saved in saved ? proceed() : stay() }
            case .alertSecondButtonReturn where canCancel:
                stay()
            default:
                self.discardChanges(); proceed()
            }
        }
        if asSheet, canCancel, let window = model?.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
