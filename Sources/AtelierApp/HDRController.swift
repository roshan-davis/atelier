import AppKit
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

    private weak var model: LibraryModel?
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
    private var saveTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderRevision = 0
    private var undoStack: [HDRSettings] = []
    private var redoStack: [HDRSettings] = []
    private var gestureStart: HDRSettings?
    private var savedSettings: HDRSettings?
    private var confirming = false
    /// The tone mapper's exposure analysis of the image last rendered; see `render()`.
    private var analysis: HDRToneMapper.Analysis?
    /// Changes whenever another photo or project is shown, so an analysis can't outlive it.
    private var inputToken = 0
    /// One Core Image context for every preview, rather than one per render.
    private let previewIO = HDRImageIO()

    init(model: LibraryModel) {
        self.model = model
        zoom = model.zoomState
    }

    var hasPhoto: Bool { before != nil }
    var projectURL: URL? { request?.projectURL }

    // MARK: Opening

    /// Opens a photo: its HDR project when it is an HDR TIFF, otherwise a new session on its
    /// original. Opening the photo already open (or its result) does nothing.
    func open(_ id: Int64?) {
        guard id != assetID || (id != nil && before == nil && !isLoading) else { return }
        if let id, id == resultAssetID { return }
        close()
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
                self.error = error.localizedDescription
            }
        }
    }

    /// A new session reads the original; the project and its source copy are made on first Save.
    private func openOriginal(_ id: Int64, catalog: Catalog) async throws {
        let loaded = try await Task.detached { () -> (ProcessorDocument, HDRImage, CGImage, CGSize) in
            guard let source = try catalog.fileURL(for: id) else {
                throw ExportError("The original is offline. Reconnect its drive to open it in HDR.")
            }
            let hash = try FileHasher.sha256(of: source)
            try Task.checkCancellation()
            let stem = source.deletingPathExtension().lastPathComponent + "-HDR-" + UUID().uuidString.prefix(8)
            let projectURL = DerivedFiles.folder(for: source).appendingPathComponent(stem).appendingPathExtension("atelierhdr")
            let request = ProcessorDocument(sourceAssetID: id, sourceURL: source, sourceHash: hash, projectURL: projectURL)
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
        self.input = input; detailInput = nil; analysis = nil; inputToken += 1
        before = NSImage(cgImage: preview, size: .zero); after = nil
        self.pixelSize = pixelSize
        self.settings = settings; savedSettings = saved; self.revision = revision
        undoStack = []; redoStack = []; updateHistory()
        dirty = settings != saved
        isLoading = false
        render()
        if case .percent(let percent) = zoom.level, percent >= 100 { zoomChanged() }
    }

    /// Leaves the photo: frees its images. Unsaved changes are the caller's to confirm first.
    func close() {
        openTask?.cancel(); openTask = nil
        renderTask?.cancel(); renderTask = nil
        renderRevision += 1
        assetID = nil; resultAssetID = nil; request = nil; store = nil; sourceURL = nil
        input = nil; detailInput = nil; detailLoading = false; analysis = nil; inputToken += 1
        before = nil; after = nil; pixelSize = nil
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
            if key == \HDRSettings.shadowProtection || key == \HDRSettings.highlightProtection { self.settings.artifactsEnabled = true }
            else { self.settings.toneEnabled = true }
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
            // Zoomed in, the drag showed the proxy: now the full-size render.
            if case .percent(let percent) = zoom.level, percent >= 100, detailInput != nil { render() }
        }
    }

    static let toneKeys: [WritableKeyPath<HDRSettings, Float>] = [\.exposure, \.compression, \.microcontrast, \.detail]
    static let textureKeys: [WritableKeyPath<HDRSettings, Float>] = [\.microcontrast, \.detail]
    static let artifactKeys: [WritableKeyPath<HDRSettings, Float>] = [\.shadowProtection, \.highlightProtection]

    func reset() { reset(Self.toneKeys + Self.artifactKeys) }
    func reset(_ keys: [WritableKeyPath<HDRSettings, Float>]) {
        let old = settings, defaults = HDRSettings()
        for key in keys { settings[keyPath: key] = defaults[keyPath: key] }
        guard old != settings else { return }
        undoStack.append(old); redoStack = []; changed()
    }

    func isModified(_ keys: [WritableKeyPath<HDRSettings, Float>]) -> Bool {
        let defaults = HDRSettings()
        return keys.contains { settings[keyPath: $0] != defaults[keyPath: $0] }
    }

    func switchBinding(_ key: WritableKeyPath<HDRSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: key] }, set: { value in
            let old = self.settings; self.settings[keyPath: key] = value
            if old != self.settings { self.undoStack.append(old); self.redoStack = []; self.changed() }
        })
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
    private func changed() { dirty = settings != savedSettings; updateHistory(); render() }

    /// Puts the sliders back to the last Save (or the defaults, before one).
    func discardChanges() {
        guard dirty else { return }
        settings = savedSettings ?? HDRSettings(); undoStack = []; redoStack = []; changed()
    }

    // MARK: Rendering

    /// One render in flight, with only the latest settings followed up. Old results never flash.
    ///
    /// Smoothness (Rosh, Nov 12, 2026): the tone mapper's exposure analysis is kept between
    /// renders (`analysis`), so only Exposure recomputes it; one Core Image context is reused
    /// for previews; and while a slider is held at 100% or closer the 1600 px proxy is drawn
    /// (scaled up, like Develop's drafts), with the full-size render once the slider is let go.
    private func render() {
        renderRevision += 1
        guard renderTask == nil, let proxy = input else { return }
        let useDetail: Bool
        if case .percent(let percent) = zoom.level { useDetail = percent >= 100 && gestureStart == nil } else { useDetail = false }
        let input = useDetail ? (detailInput ?? proxy) : proxy
        let snapshot = settings, revision = renderRevision, io = previewIO, token = inputToken
        let cached = analysis.flatMap { $0.matches(input, exposure: snapshot.exposure) ? $0 : nil }
        // Only the proxy's analysis is kept (about 27 MB); a full-size one would be ~400 MB.
        let keepsAnalysis = input.width == proxy.width && input.height == proxy.height
        renderTask = Task {
            do {
                let result = try await Task.detached { () -> (CGImage, HDRToneMapper.Analysis?) in
                    var prepared = cached
                    if snapshot.toneEnabled, prepared == nil {
                        prepared = try HDRToneMapper.analyze(input, exposure: snapshot.exposure)
                    }
                    let rendered = try HDRToneMapper.render(input, settings: snapshot, analysis: prepared)
                    return (try io.preview(rendered), prepared)
                }.value
                // Kept only for the image it was made from; a new photo or project clears it.
                if token == inputToken, keepsAnalysis, let prepared = result.1 { analysis = prepared }
                if settings == snapshot, revision == renderRevision { after = NSImage(cgImage: result.0, size: .zero) }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            guard revision <= renderRevision, self.input != nil else { renderTask = nil; return }
            renderTask = nil
            if settings != snapshot || revision != renderRevision { render() }
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
        busy = true; model.status = "Saving HDR: rendering the full-resolution TIFF…"
        saveTask = Task {
            var newlyCreated: HDRProjectStore?
            do {
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
                let manifest = try await active.save(settings: snapshot, cancellation: { try Task.checkCancellation() })
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
