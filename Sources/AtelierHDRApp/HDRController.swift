import AppKit
import SwiftUI
import AtelierHDRCore
import AtelierCore

@MainActor
final class HDRController: ObservableObject {
    @Published var settings = HDRSettings()
    @Published var originalToggled = false
    @Published var compareKeySignal = 0
    @Published var before: NSImage?
    @Published var after: NSImage?
    @Published var pixelSize: CGSize?
    @Published var status = "Open a photo or launch from Atelier > Photo > Edit In > HDR App."
    @Published var busy = false
    @Published var error: String?
    @Published var sourceName = "No photo"
    @Published var dirty = false
    @Published var canUndo = false
    @Published var canRedo = false
    let zoom = ZoomState()
    private var input: HDRImage?
    private var detailInput: HDRImage?
    private var detailLoading = false
    private var sourceURL: URL?
    private var store: HDRProjectStore?
    private var request: ProcessorDocument?
    private var requestURL: URL?
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderRevision = 0
    private var undoStack: [HDRSettings] = []
    private var redoStack: [HDRSettings] = []
    private var gestureStart: HDRSettings?
    private var projectURL: URL?
    private var savedSettings: HDRSettings?

    func launch() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--processor-document"), args.count > i+1 {
            openRequest(URL(fileURLWithPath: args[i+1]))
        }
    }

    func openRequest(_ url: URL) {
        do {
            let request = try ProcessorDocument.read(url)
            for key in ["appearance.theme", "zoom.clickPercent", "keys.zoom", "keys.beforeAfter", "keys.compareMode"] {
                if let value = request.uiPreferences?[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            Theme.current.apply()
            self.request = request; requestURL = url
            openProject(request.projectURL, originalName: request.sourceURL.lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }

    func chooseOpen() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true
        panel.title = "Open HDR Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        request = nil; requestURL = nil
        openProject(url, originalName: url.deletingPathExtension().lastPathComponent)
    }

    func openURL(_ url: URL) {
        if url.pathExtension == "json" { openRequest(url) }
        else if url.pathExtension == "atelierhdr" {
            request = nil; requestURL = nil
            openProject(url, originalName: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func openProject(_ url: URL, originalName: String) {
        guard !busy else { return }
        projectURL = url
        busy = true; status = "Opening verified project…"
        task = Task {
            do {
                let loaded = try await Task.detached { () -> (HDRProjectStore, HDRProjectManifest, HDRImage, CGImage) in
                    let store = try HDRProjectStore.open(url), manifest = await store.manifest
                    try await store.publish()
                    let source = await store.sourceURL(), io = HDRImageIO()
                    let input = try io.decode(source, longEdge: 1600)
                    return (store, manifest, input, try io.preview(input))
                }.value
                try Task.checkCancellation()
                store = loaded.0; settings = loaded.1.settings; savedSettings = settings
                input = loaded.2; before = NSImage(cgImage: loaded.3, size: .zero)
                sourceURL = await loaded.0.sourceURL()
                if let sourceURL { pixelSize = try HDRImageIO.dimensions(sourceURL) }
                detailInput = nil
                projectURL = url; sourceName = originalName; dirty = false
                undoStack = []; redoStack = []; updateHistory()
                if loaded.1.revision > 0, let request, let requestURL {
                    let m = loaded.1
                    let receipt = ProcessorReceipt(jobID: request.jobID, projectID: m.projectID, outputID: m.outputID,
                        revision: m.revision, sourceHash: m.sourceHash, resultHash: m.resultHash!,
                        generationID: m.generationID!, width: m.width, height: m.height)
                    try receipt.write(to: requestURL.deletingPathExtension().appendingPathExtension("receipt"))
                }
                busy = false; status = "Ready"; render()
            } catch { busy = false; self.error = error.localizedDescription; status = "Could not open project" }
        }
    }

    func relinkSource() {
        guard let projectURL, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Relink HDR Source"; panel.prompt = "Verify and Relink"
        guard panel.runModal() == .OK, let replacement = panel.url else { return }
        busy = true; status = "Verifying replacement source…"
        Task {
            do {
                try await Task.detached { try HDRProjectStore.relink(projectURL, from: replacement) }.value
                busy = false; openProject(projectURL, originalName: sourceName)
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }

    func binding(_ key: WritableKeyPath<HDRSettings, Float>, name: String) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: key]) }, set: { value in
            let old = self.settings
            self.settings[keyPath: key] = Float(value)
            if key == \HDRSettings.shadowProtection || key == \HDRSettings.highlightProtection { self.settings.artifactsEnabled = true }
            else { self.settings.toneEnabled = true }
            if self.gestureStart == nil, old != self.settings { self.undoStack.append(old); self.redoStack = [] }
            self.changed()
        })
    }
    func gesture(_ active: Bool) {
        if active { gestureStart = settings }
        else if let previous = gestureStart {
            gestureStart = nil
            if previous != settings { undoStack.append(previous); redoStack = [] }
            updateHistory()
        }
    }
    func reset() { reset([\.exposure, \.compression, \.microcontrast, \.detail, \.shadowProtection, \.highlightProtection]) }
    func reset(_ keys: [WritableKeyPath<HDRSettings, Float>]) {
        let old = settings, defaults = HDRSettings()
        for key in keys { settings[keyPath: key] = defaults[keyPath: key] }
        guard old != settings else { return }
        undoStack.append(old); redoStack = []; changed()
    }
    func switchBinding(_ key: WritableKeyPath<HDRSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: key] }, set: { value in
            let old = self.settings; self.settings[keyPath: key] = value
            if old != self.settings { self.undoStack.append(old); self.redoStack = []; self.changed() }
        })
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings); settings = previous; changed()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings); settings = next; changed()
    }
    private func updateHistory() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
    private func changed() { dirty = settings != savedSettings; updateHistory(); render() }

    /// One render in flight, with only the latest settings followed up. Old results never flash.
    private func render() {
        renderRevision += 1
        guard renderTask == nil, let proxy = input else { return }
        let useDetail: Bool
        if case .percent(let percent) = zoom.level { useDetail = percent >= 100 } else { useDetail = false }
        let input = useDetail ? (detailInput ?? proxy) : proxy
        let snapshot = settings, revision = renderRevision
        renderTask = Task {
            do {
                let cg = try await Task.detached { () -> CGImage in
                    let rendered = try HDRToneMapper.render(input, settings: snapshot)
                    return try HDRImageIO().preview(rendered)
                }.value
                if settings == snapshot, revision == renderRevision { after = NSImage(cgImage: cg, size: .zero) }
            } catch { self.error = error.localizedDescription }
            renderTask = nil
            if settings != snapshot || revision != renderRevision { render() }
        }
    }

    func zoomChanged() {
        guard case .percent(let percent) = zoom.level, percent >= 100,
              detailInput == nil, !detailLoading, let sourceURL else { render(); return }
        detailLoading = true; status = "Loading full-resolution detail…"
        Task {
            do {
                let full = try await Task.detached { try HDRImageIO().decode(sourceURL) }.value
                if self.sourceURL == sourceURL {
                    detailInput = full
                    let original = try await Task.detached { try HDRImageIO().preview(full) }.value
                    before = NSImage(cgImage: original, size: .zero)
                    status = "Full-resolution detail ready"; render()
                }
            } catch { self.error = error.localizedDescription }
            detailLoading = false
        }
    }

    func save(returnToAtelier: Bool = false, asNew: Bool = false) {
        guard let store, !busy else { return }
        var destination: URL?
        if asNew {
            let panel = NSSavePanel(); panel.title = "Save HDR As New"
            panel.nameFieldStringValue = sourceName + "-HDR.atelierhdr"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url.pathExtension == "atelierhdr" ? url : url.appendingPathExtension("atelierhdr")
        }
        let snapshot = settings
        busy = true; status = "Rendering full-resolution TIFF…"
        task = Task {
            do {
                let active: HDRProjectStore
                if let destination { active = try await store.fork(to: destination) } else { active = store }
                let manifest = try await active.save(settings: snapshot, cancellation: { try Task.checkCancellation() })
                self.store = active; projectURL = await active.url
                savedSettings = snapshot; dirty = settings != snapshot
                if let request, let requestURL {
                    // Save As New authorizes a new session, leaving the original output identity intact.
                    var publication = request
                    if destination != nil {
                        publication.jobID = UUID()
                        publication.projectURL = await active.url
                        publication.expectedProjectID = manifest.projectID
                        publication.outputID = manifest.outputID
                        let newURL = requestURL.deletingLastPathComponent().appendingPathComponent(publication.jobID.uuidString + ".json")
                        try publication.write(to: newURL)
                        self.request = publication; self.requestURL = newURL
                    }
                    let receipt = ProcessorReceipt(jobID: publication.jobID, projectID: manifest.projectID,
                        outputID: manifest.outputID, revision: manifest.revision, sourceHash: manifest.sourceHash,
                        resultHash: manifest.resultHash!, generationID: manifest.generationID!, width: manifest.width, height: manifest.height)
                    try receipt.write(to: (self.requestURL ?? requestURL).deletingPathExtension().appendingPathExtension("receipt"))
                }
                busy = false; status = "Saved profiled 16-bit TIFF and project"
                if returnToAtelier {
                    if let request = self.request, let hostURL = request.hostBundleURL {
                        let host = request.hostProcessID.flatMap { NSRunningApplication(processIdentifier: $0) }
                        if host?.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL {
                            host?.activate()
                        } else {
                            NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL })?.activate()
                        }
                    }
                }
            } catch is CancellationError { busy = false; status = "Cancelled; the previous saved project is preserved" }
            catch { busy = false; self.error = error.localizedDescription; status = "Save needs attention" }
        }
    }
    func cancel() { task?.cancel() }
}
