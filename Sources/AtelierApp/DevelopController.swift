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

    /// The crop tool is open: the photo renders whole (turned and straightened) under the crop frame.
    @Published var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            if isCropping {
                showingBefore = false
                isAIOpen = false
                isMasking = false
            }
            scheduleRender()
        }
    }
    /// The AI tool is open: the photo shows under the AI brush and the AI panel replaces Crop.
    @Published var isAIOpen = false {
        didSet {
            guard isAIOpen != oldValue, isAIOpen else { return }
            isCropping = false
            isMasking = false
            showingBefore = false
            compareMode = .off
        }
    }

    /// The Masking tool is open: the photo shows under the mask pins and the Masks panel.
    @Published var isMasking = false {
        didSet {
            guard isMasking != oldValue else { return }
            if isMasking {
                isCropping = false
                isAIOpen = false
                showingBefore = false
                compareMode = .off
                if selectedMaskID == nil { selectedMaskID = settings.masks.last?.id }
            } else {
                maskTool = nil
            }
            scheduleRender()
        }
    }
    /// The selected mask and part in the Masks panel.
    @Published var selectedMaskID: UUID? {
        didSet { if selectedMaskID != oldValue, showMaskOverlay { scheduleRender() } }
    }
    @Published var selectedComponentID: UUID?
    /// What the next drag on the photo draws, if anything.
    @Published var maskTool: MaskTool?
    /// Tints the selected mask red on the photo (O).
    @Published var showMaskOverlay = UserDefaults.standard.bool(forKey: "masks.showOverlay") {
        didSet {
            UserDefaults.standard.set(showMaskOverlay, forKey: "masks.showOverlay")
            scheduleRender()
        }
    }
    /// Brush settings, remembered like Lightroom's. Size is a fraction of the photo's long edge.
    @Published var brushSize = UserDefaults.standard.object(forKey: "masks.brushSize") as? Double ?? 0.06 {
        didSet { UserDefaults.standard.set(brushSize, forKey: "masks.brushSize") }
    }
    @Published var brushFeather = UserDefaults.standard.object(forKey: "masks.brushFeather") as? Double ?? 50 {
        didSet { UserDefaults.standard.set(brushFeather, forKey: "masks.brushFeather") }
    }
    @Published var brushFlow = UserDefaults.standard.object(forKey: "masks.brushFlow") as? Double ?? 100 {
        didSet { UserDefaults.standard.set(brushFlow, forKey: "masks.brushFlow") }
    }
    @Published var brushErasing = false
    /// The decoded photo's size (upright, uncropped) at proxy scale; its aspect drives the crop tool.
    @Published private(set) var sourceSize: CGSize?

    var crop: DevelopSettings.Crop { settings.crop ?? DevelopSettings.Crop() }

    /// The turned photo's width / height, which crop fractions are measured against.
    var orientedAspect: Double {
        guard let size = sourceSize, size.height > 0 else { return 1.5 }
        let oriented = crop.orientedSize(size)
        return Double(oriented.width / oriented.height)
    }

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
        if isCropping || isMasking { return image }
        if !showingBefore, let fullImage, fullImageSettings == settings { return fullImage }
        return image
    }

    /// The open photo's history and snapshots. `committed` is the settings of the newest step,
    /// and `pendingStep` names the change waiting to become a step when the edit settles.
    @Published private(set) var history = DevelopHistory()
    private var committed = DevelopSettings()
    private var pendingStep: String?

    /// Built-in and user presets, shared across catalogs.
    @Published private(set) var presets: [DevelopPreset] = []
    private let presetStore = PresetStore(fileURL: PresetStore.defaultURL)

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
        presets = presetStore.all()
    }

    // MARK: Opening

    /// Opens the current photo again, after its file changed on disk.
    func reopen() {
        let id = assetID
        open(nil)
        open(id)
    }

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
        isCropping = false
        sourceSize = nil
        selectedMaskID = nil
        selectedComponentID = nil
        maskTool = nil
        guard let assetID else { return }

        settings = (try? catalog.developSettings(for: assetID)) ?? .neutral
        if isMasking { selectedMaskID = settings.masks.last?.id }
        history = (try? catalog.developHistory(for: assetID)) ?? DevelopHistory()
        committed = settings
        pendingStep = nil
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
                    self.sourceSize = session.sourceSize
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

    /// The value Reset returns to; for temperature, the photo's as-shot white balance.
    func defaultValue(_ parameter: DevelopSettings.Parameter) -> Double {
        parameter == .temperature ? asShotTemperature : parameter.defaultValue
    }

    func set(_ parameter: DevelopSettings.Parameter, to value: Double) {
        guard assetID != nil else { return }
        settings[parameter] = value
        changed(step: Self.stepName(parameter, value: settings[parameter]))
    }

    func reset(_ parameter: DevelopSettings.Parameter) {
        guard assetID != nil else { return }
        switch parameter {
        case .temperature: settings.temperature = nil
        default: settings[parameter] = DevelopSettings.neutral[parameter]
        }
        changed(step: "Reset \(Self.parameterName(parameter))")
    }

    func setPoints(_ points: [DevelopSettings.CurvePoint], for channel: DevelopSettings.CurveChannel) {
        guard assetID != nil else { return }
        settings.setPoints(points, for: channel)
        changed(step: "Tone Curve (\(channel.label))")
    }

    func reset(_ panel: DevelopSettings.Panel) {
        guard assetID != nil else { return }
        if panel == .toneCurve {
            for channel in DevelopSettings.CurveChannel.allCases { settings.setPoints([], for: channel) }
        }
        for parameter in panel.parameters {
            if parameter == .temperature {
                settings.temperature = nil
            } else {
                settings[parameter] = DevelopSettings.neutral[parameter]
            }
        }
        changed(step: "Reset \(panel.title)")
    }

    func isModified(_ panel: DevelopSettings.Panel) -> Bool {
        if panel == .toneCurve, settings.hasPointCurve { return true }
        return panel.parameters.contains { parameter in
            parameter == .temperature ? settings.temperature != nil
                : settings[parameter] != DevelopSettings.neutral[parameter]
        }
    }

    func setCrop(_ crop: DevelopSettings.Crop) {
        guard assetID != nil, crop != self.crop else { return }
        let previous = self.crop
        settings.crop = crop
        beforeImage = nil
        changed(step: Self.cropStepName(from: previous, to: crop))
        if compareMode != .off { renderBeforeIfNeeded() }
    }

    /// The photo without edits but with the same crop, so before and after line up.
    private var beforeSettings: DevelopSettings {
        var before = DevelopSettings.neutral
        before.crop = settings.crop
        return before
    }

    /// The full-size photo's size after the crop, for 100% zoom. `assetSize` is the original's
    /// pixel size from the catalog.
    func croppedPixelSize(assetSize: CGSize?) -> CGSize? {
        guard let assetSize, let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else { return assetSize }
        let factor = max(assetSize.width, assetSize.height) / max(sourceSize.width, sourceSize.height)
        let full = CGSize(width: sourceSize.width * factor, height: sourceSize.height * factor)
        return crop.outputSize(full)
    }

    func resetAll() {
        guard assetID != nil else { return }
        settings = .neutral
        validateMaskSelection()
        changed(step: "Reset All")
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
        apply(clipboard, onto: assetIDs, step: "Paste Settings")
    }

    /// Clears all edits on the photos (Lightroom's Reset).
    func resetSettings(of assetIDs: [Int64]) {
        apply(.neutral, onto: assetIDs, step: "Reset All")
    }

    func apply(_ newSettings: DevelopSettings, onto assetIDs: [Int64]?, step: String) {
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        for id in targets where id != assetID {
            try? catalog.saveDevelopSettings(newSettings, for: id, step: step)
            refreshPreviews(for: id, settings: newSettings)
        }
        if let assetID, targets.contains(assetID) {
            settings = newSettings
            validateMaskSelection()
            changed(step: step)
        }
    }

    /// An edit to the open photo. `step` names it in the history; nil (undo, redo, jumping
    /// in the history) saves without adding a step.
    private func changed(step: String?) {
        dirty = true
        if let step { pendingStep = step }
        scheduleRender()
        scheduleSave()
    }

    // MARK: Presets

    /// Applies a preset to the open photo, or to each photo in `assetIDs` on top of its own
    /// settings.
    func applyPreset(_ preset: DevelopPreset, onto assetIDs: [Int64]? = nil) {
        let step = "Preset: \(preset.name)"
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        for id in targets where id != assetID {
            let base = (try? catalog.developSettings(for: id)) ?? .neutral
            let newSettings = preset.applied(to: base)
            try? catalog.saveDevelopSettings(newSettings, for: id, step: step)
            refreshPreviews(for: id, settings: newSettings)
        }
        if let assetID, targets.contains(assetID) {
            settings = preset.applied(to: settings)
            validateMaskSelection()
            beforeImage = nil
            changed(step: step)
        }
    }

    /// Saves the open photo's settings as a new preset with the chosen parts.
    func createPreset(name: String, group: String, parts: Set<DevelopPreset.Part>) {
        let preset = DevelopPreset(name: name, group: group, parts: parts, settings: settings)
        do {
            try presetStore.save(preset)
        } catch {
            errorMessage = "Could not save the preset: \(error.localizedDescription)"
        }
        presets = presetStore.all()
    }

    func updatePreset(_ preset: DevelopPreset) {
        var updated = preset
        updated.settings = settings
        try? presetStore.save(updated)
        presets = presetStore.all()
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        var updated = preset
        updated.name = name
        try? presetStore.save(updated)
        presets = presetStore.all()
    }

    func deletePreset(_ preset: DevelopPreset) {
        try? presetStore.delete(preset.id)
        presets = presetStore.all()
    }

    // MARK: History and snapshots

    var canUndo: Bool { pendingStep != nil || history.canUndo }
    var canRedo: Bool { pendingStep == nil && history.canRedo }

    func undo() {
        commitPendingStep()
        guard history.canUndo else { return }
        go(to: history.position - 1)
    }

    func redo() {
        commitPendingStep()
        guard history.canRedo else { return }
        go(to: history.position + 1)
    }

    /// Shows the photo as it was at a history step (clicking a step in the History panel).
    func go(to position: Int) {
        commitPendingStep()
        guard history.steps.indices.contains(position) else { return }
        history.position = position
        settings = history.steps[position].settings
        committed = settings
        beforeImage = nil
        validateMaskSelection()
        changed(step: nil)
        if compareMode != .off { renderBeforeIfNeeded() }
    }

    func clearHistory() {
        commitPendingStep()
        history.clear()
        dirty = true
        flushSave()
    }

    func createSnapshot(named name: String) {
        commitPendingStep()
        history.snapshots.insert(DevelopHistory.Snapshot(name: name, settings: settings), at: 0)
        dirty = true
        flushSave()
    }

    func applySnapshot(_ snapshot: DevelopHistory.Snapshot) {
        guard assetID != nil else { return }
        settings = snapshot.settings
        validateMaskSelection()
        beforeImage = nil
        changed(step: "Snapshot: \(snapshot.name)")
    }

    func updateSnapshot(_ id: UUID) {
        guard let index = history.snapshots.firstIndex(where: { $0.id == id }) else { return }
        history.snapshots[index].settings = settings
        history.snapshots[index].date = Date()
        dirty = true
        flushSave()
    }

    func renameSnapshot(_ id: UUID, to name: String) {
        guard let index = history.snapshots.firstIndex(where: { $0.id == id }) else { return }
        history.snapshots[index].name = name
        dirty = true
        flushSave()
    }

    func deleteSnapshot(_ id: UUID) {
        history.snapshots.removeAll { $0.id == id }
        dirty = true
        flushSave()
    }

    /// Turns the change in progress into a history step now.
    private func commitPendingStep() {
        guard let step = pendingStep else { return }
        pendingStep = nil
        history.record(step, settings: settings, previous: committed)
        committed = settings
        dirty = true
    }

    private static func parameterName(_ parameter: DevelopSettings.Parameter) -> String {
        if let pair = parameter.hslBand { return "\(pair.0.rawValue) \(pair.1.rawValue)" }
        switch parameter.panel {
        case .colorGrading, .detail, .effects, .toneCurve:
            return "\(parameter.group) \(parameter.label)"
        default:
            return parameter.label == "Temp" ? "Temperature" : parameter.label
        }
    }

    private static func stepName(_ parameter: DevelopSettings.Parameter, value: Double) -> String {
        let formatted: String
        switch parameter {
        case .temperature: formatted = "\(Int(value.rounded())) K"
        case .exposure: formatted = String(format: "%+.2f", value)
        case .sharpenRadius: formatted = String(format: "%.1f", value)
        default:
            formatted = parameter.range.lowerBound >= 0 ? "\(Int(value.rounded()))" : String(format: "%+.0f", value)
        }
        return "\(parameterName(parameter)) \(formatted)"
    }

    private static func cropStepName(from old: DevelopSettings.Crop, to new: DevelopSettings.Crop) -> String {
        if new.isIdentity { return "Reset Crop" }
        if old.quarterTurns != new.quarterTurns { return "Rotate" }
        if old.flipHorizontal != new.flipHorizontal || old.flipVertical != new.flipVertical { return "Flip" }
        if old.angle != new.angle { return String(format: "Straighten %.1f°", new.angle) }
        return "Crop"
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard let session else { return }
        if rendering {
            needsRender = true
            return
        }
        rendering = true
        let settings = showingBefore ? beforeSettings : self.settings
        let cropping = !isCropping
        let assetID = self.assetID
        let overlay = isMasking && showMaskOverlay ? selectedMaskID : nil
        queue.async {
            let cgImage = session.render(settings, cropping: cropping, overlay: overlay)
            // The red overlay would skew the histogram; keep the last one while it shows.
            let histogram = overlay == nil ? cgImage.flatMap { Histogram(image: $0) } : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.rendering = false
                    if self.assetID == assetID, let cgImage {
                        self.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        if let histogram { self.histogram = histogram }
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
        guard wantsFullResolution, !showingBefore, !isCropping, let url = sourceURL, fullImageSettings != settings else { return }
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
        let before = beforeSettings
        queue.async {
            let cgImage = session.render(before)
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
        commitPendingStep()
        guard dirty, let assetID else { return }
        dirty = false
        let settings = self.settings
        do {
            try catalog.saveDevelop(settings, history: history, for: assetID)
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
    func refreshPreviews(for assetID: Int64, settings: DevelopSettings) {
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

// MARK: Masks

/// What a drag on the photo draws next: a new mask, or a part added to the selected one.
struct MaskTool: Equatable {
    var kind: DevelopSettings.MaskComponent.Kind
    var mode: DevelopSettings.MaskComponent.Mode = .add
    var newMask = true

    var hint: String {
        switch kind {
        case .linear: return "Drag on the photo from where the effect is full to where it fades out."
        case .radial: return "Drag on the photo from the center outward to draw the ellipse."
        case .brush: return "Paint on the photo. Hold ⌥ to erase; [ and ] change the size."
        case .luminance, .subject: return ""
        }
    }
}

extension DevelopController {
    typealias Mask = DevelopSettings.Mask
    typealias MaskComponent = DevelopSettings.MaskComponent

    var masks: [Mask] { settings.masks }

    var selectedMask: Mask? { settings.masks.first { $0.id == selectedMaskID } }

    var selectedComponent: MaskComponent? {
        selectedMask?.components.first { $0.id == selectedComponentID }
    }

    private func maskIndex(_ id: UUID?) -> Int? {
        settings.masks.firstIndex { $0.id == id }
    }

    /// Keeps the selection pointing at masks that exist after undo, presets or paste.
    fileprivate func validateMaskSelection() {
        guard let mask = selectedMask else {
            selectedMaskID = isMasking ? settings.masks.last?.id : nil
            selectedComponentID = nil
            return
        }
        if !mask.components.contains(where: { $0.id == selectedComponentID }) { selectedComponentID = nil }
    }

    /// Opens Masking with a tool ready, from the keyboard or the tool strip.
    func startMaskTool(_ kind: MaskComponent.Kind) {
        if !isMasking { isMasking = true }
        createMask(kind)
    }

    /// Create New Mask: drawn kinds wait for a drag on the photo; the others are made now.
    func createMask(_ kind: MaskComponent.Kind) {
        guard assetID != nil else { return }
        if kind.isDrawn {
            maskTool = MaskTool(kind: kind)
        } else {
            insert(MaskComponent(Self.defaultShape(kind)), tool: MaskTool(kind: kind))
        }
    }

    /// Add, Subtract or Intersect a part into the selected mask.
    func addComponent(_ kind: MaskComponent.Kind, mode: MaskComponent.Mode) {
        guard selectedMask != nil else { return createMask(kind) }
        let tool = MaskTool(kind: kind, mode: mode, newMask: false)
        if kind.isDrawn {
            maskTool = tool
        } else {
            insert(MaskComponent(Self.defaultShape(kind), mode: mode), tool: tool)
        }
    }

    private static func defaultShape(_ kind: MaskComponent.Kind) -> MaskComponent.Shape {
        switch kind {
        case .luminance: return .luminance(DevelopSettings.LuminanceRange(low: 50, high: 100))
        case .subject: return .subject
        case .brush: return .brush([])
        case .linear: return .linear(.init(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.5)))
        case .radial: return .radial(.init(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.15))
        }
    }

    /// Finishes drawing a part with the current tool.
    func finishDrawing(_ shape: MaskComponent.Shape) {
        guard let tool = maskTool, assetID != nil else { return }
        maskTool = nil
        insert(MaskComponent(shape, mode: tool.mode), tool: tool)
    }

    private func insert(_ component: MaskComponent, tool: MaskTool) {
        var component = component
        if tool.newMask || selectedMask == nil {
            component.mode = .add
            let mask = Mask(name: settings.nextMaskName(), components: [component])
            settings.masks.append(mask)
            selectedMaskID = mask.id
            selectedComponentID = component.id
            changed(step: "New Mask: \(component.kind.title)")
        } else if let index = maskIndex(selectedMaskID) {
            settings.masks[index].components.append(component)
            selectedComponentID = component.id
            let verb = component.mode == .add ? "Add" : component.mode == .subtract ? "Subtract" : "Intersect"
            changed(step: "\(verb) \(component.kind.title): \(settings.masks[index].name)")
        }
    }

    /// Changes a part of the selected mask, while dragging its handles or from the panel.
    func updateComponent(_ component: MaskComponent) {
        guard let index = maskIndex(selectedMaskID),
              let part = settings.masks[index].components.firstIndex(where: { $0.id == component.id }),
              settings.masks[index].components[part] != component else { return }
        settings.masks[index].components[part] = component
        changed(step: "Edit \(settings.masks[index].name)")
    }

    /// Adds a brush stroke to the selected brush part.
    func addStroke(_ stroke: DevelopSettings.MaskStroke) {
        guard var component = selectedComponent, case .brush(var strokes) = component.shape else { return }
        strokes.append(stroke)
        component.shape = .brush(strokes)
        updateComponent(component)
    }

    func select(mask id: UUID, component: UUID? = nil) {
        selectedMaskID = id
        selectedComponentID = component
        maskTool = nil
    }

    func setMaskValue(_ parameter: DevelopSettings.LocalParameter, to value: Double) {
        guard let index = maskIndex(selectedMaskID) else { return }
        settings.masks[index][parameter] = value
        let mask = settings.masks[index]
        let formatted = parameter == .exposure ? String(format: "%+.2f", mask[parameter])
            : String(format: "%+.0f", mask[parameter])
        changed(step: "\(mask.name) \(parameter.label == "Temp" ? "Temperature" : parameter.label) \(formatted)")
    }

    func setMaskAmount(_ amount: Double) {
        guard let index = maskIndex(selectedMaskID) else { return }
        settings.masks[index].amount = min(200, max(0, amount))
        changed(step: "\(settings.masks[index].name) Amount \(Int(settings.masks[index].amount.rounded()))%")
    }

    func resetMaskSliders() {
        guard let index = maskIndex(selectedMaskID) else { return }
        settings.masks[index].resetAdjustments()
        changed(step: "Reset \(settings.masks[index].name) Sliders")
    }

    func toggleHidden(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        settings.masks[index].isHidden.toggle()
        changed(step: "\(settings.masks[index].isHidden ? "Hide" : "Show") \(settings.masks[index].name)")
    }

    func invertMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        settings.masks[index].inverted.toggle()
        changed(step: "Invert \(settings.masks[index].name)")
    }

    func renameMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = maskIndex(id), !trimmed.isEmpty, trimmed != settings.masks[index].name else { return }
        settings.masks[index].name = trimmed
        changed(step: "Rename Mask: \(trimmed)")
    }

    func duplicateMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        var copy = settings.masks[index]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        copy.components = copy.components.map { component in
            var fresh = component
            fresh.id = UUID()
            return fresh
        }
        settings.masks.insert(copy, at: index + 1)
        selectedMaskID = copy.id
        selectedComponentID = nil
        changed(step: "Duplicate \(settings.masks[index].name)")
    }

    func deleteMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        let name = settings.masks[index].name
        settings.masks.remove(at: index)
        if selectedMaskID == id {
            selectedMaskID = settings.masks.last?.id
            selectedComponentID = nil
        }
        changed(step: "Delete \(name)")
    }

    func deleteAllMasks() {
        guard !settings.masks.isEmpty else { return }
        settings.masks = []
        selectedMaskID = nil
        selectedComponentID = nil
        maskTool = nil
        changed(step: "Delete All Masks")
    }

    /// Removes a part; the whole mask goes with its last part.
    func deleteComponent(_ id: UUID, in maskID: UUID) {
        guard let index = maskIndex(maskID) else { return }
        if settings.masks[index].components.count <= 1 { return deleteMask(maskID) }
        settings.masks[index].components.removeAll { $0.id == id }
        // The first part always adds.
        settings.masks[index].components[0].mode = .add
        if selectedComponentID == id { selectedComponentID = nil }
        changed(step: "Delete Part of \(settings.masks[index].name)")
    }

    /// Delete key in Masking: the selected part, or the selected mask.
    func deleteSelectedMaskPart() {
        guard let mask = selectedMask else { return }
        if let component = selectedComponentID {
            deleteComponent(component, in: mask.id)
        } else {
            deleteMask(mask.id)
        }
    }

    func setMode(_ mode: MaskComponent.Mode, of id: UUID, in maskID: UUID) {
        guard let index = maskIndex(maskID),
              let part = settings.masks[index].components.firstIndex(where: { $0.id == id }), part > 0 else { return }
        settings.masks[index].components[part].mode = mode
        changed(step: "Edit \(settings.masks[index].name)")
    }

    func invertComponent(_ id: UUID, in maskID: UUID) {
        guard let index = maskIndex(maskID),
              let part = settings.masks[index].components.firstIndex(where: { $0.id == id }) else { return }
        settings.masks[index].components[part].inverted.toggle()
        changed(step: "Invert Part of \(settings.masks[index].name)")
    }
}
