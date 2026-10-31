import AppKit
import AtelierCore
import CoreImage
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
    /// `image` is the whole, uncropped photo (rendered for the crop tool) rather than the crop.
    @Published private(set) var imageIsWhole = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var asShotTemperature: Double = 5500
    /// The camera's tint, which the stored Tint is relative to; shown added, as Lightroom does.
    @Published private(set) var asShotTint: Double = 0
    /// The color pickers (eyedroppers) that act on a click on the photo, as in Lightroom: the
    /// White Balance Selector, Defringe's Fringe Color Selector, Color Grading's color picker and
    /// Point Color's eyedropper; and the Targeted Adjustment Tool for the Tone Curve, HSL and the
    /// B&W Mix, which acts on a drag. One is out at a time; each works on the same zoomable photo
    /// with a hint at the top, and Esc or a second click on its button puts it away.
    enum PhotoPicker {
        case whiteBalance, fringe, gradeColor, pointColor
        case targetCurve, targetColor, targetGray

        var hint: String {
            switch self {
            case .whiteBalance: return "Click something that should be neutral gray or white. Esc to cancel."
            case .fringe: return "Click a purple or green fringe. Zoom in to see it clearly. Esc to cancel."
            case .gradeColor: return "Click a spot whose color cast should turn neutral. Esc to cancel."
            case .pointColor: return "Click the color you want to change. Esc to cancel."
            case .targetCurve: return "Drag up or down on a tone to lighten or darken it. Esc when done."
            case .targetColor: return "Drag up or down on a color to change it. Esc when done."
            case .targetGray: return "Drag up or down on a color to make its gray lighter or darker. Esc when done."
            }
        }

        /// The Targeted Adjustment Tool, which acts on a drag rather than a click.
        var isTargeted: Bool { self == .targetCurve || self == .targetColor || self == .targetGray }
    }

    @Published var picker: PhotoPicker? {
        didSet {
            guard picker != oldValue else { return }
            pickerMessage = nil
            targetDrag = nil
            guard picker != nil else { return }
            isCropping = false
            isAIOpen = false
            isMasking = false
            isGuiding = false
            showingBefore = false
            compareMode = .off
        }
    }
    /// Why the last click with the picker that is out set nothing.
    @Published var pickerMessage: String?

    /// The HSL channel the Targeted Adjustment Tool changes (HSL / Color's view, or the one
    /// chosen from its menu in the All view).
    @Published var targetChannel: DevelopSettings.HSLChannel = .saturation
    /// A Targeted Adjustment drag in progress; see DevelopController+ColorTools.
    var targetDrag: TargetDrag?
    /// The Point Color swatch (0...3) the panel shows and the eyedropper fills.
    @Published var pointColorSwatch = 0 {
        didSet { if pointColorSwatch != oldValue, visualizesPointRange { sliderPreview = .pointColorRange(pointColorSwatch) } }
    }
    /// Point Color's Visualize Range: the photo gray except the colors the swatch selects.
    @Published var visualizesPointRange = false {
        didSet {
            guard visualizesPointRange != oldValue else { return }
            sliderPreview = visualizesPointRange ? .pointColorRange(pointColorSwatch) : nil
        }
    }
    /// The point curve under the pointer and its selected point, which the arrow keys nudge.
    var hoveredCurvePoint: (channel: DevelopSettings.CurveChannel, index: Int)?
    /// The Tone Curve's Copy Channel Settings, for Paste.
    @Published var copiedCurve: [DevelopSettings.CurvePoint]?
    /// Curves saved from the Tone Curve's menu, kept across photos and launches.
    @Published var savedCurves: [SavedCurve] = SavedCurve.load() {
        didSet { SavedCurve.save(savedCurves) }
    }

    /// The White Balance Selector is out: the next click on the photo makes that spot neutral.
    var isPickingWhiteBalance: Bool {
        get { picker == .whiteBalance }
        set { setPicker(.whiteBalance, newValue) }
    }
    /// Lens Corrections > Defringe's Fringe Color Selector is out: a click on a purple or green
    /// fringe sets that color's Hue range and Amount.
    var isPickingFringe: Bool {
        get { picker == .fringe }
        set { setPicker(.fringe, newValue) }
    }
    /// Color Grading's color picker is out: a click on the photo sets a wheel so that spot's color
    /// cast turns neutral.
    var isPickingGradeColor: Bool {
        get { picker == .gradeColor }
        set { setPicker(.gradeColor, newValue) }
    }

    private func setPicker(_ kind: PhotoPicker, _ out: Bool) {
        if out { picker = kind } else if picker == kind { picker = nil }
    }

    /// Auto or the White Balance Selector is measuring the photo.
    @Published private(set) var isFindingWhiteBalance = false
    /// The wheel the color picker sets; nil picks Shadows, Midtones or Highlights by the spot's tone.
    @Published var gradePickRegion: DevelopSettings.GradeRegion?
    @Published var showingBefore = false {
        didSet { if showingBefore != oldValue { scheduleRender() } }
    }

    @Published var compareMode: CompareMode = .off {
        didSet { if compareMode != .off { renderBeforeIfNeeded() } }
    }
    /// The photo without edits, rendered once per open photo for the compare views.
    @Published private(set) var beforeImage: NSImage?
    /// The photo without edits at full size, for zooming in the compare views.
    @Published private(set) var fullBeforeImage: NSImage?
    private var fullBeforeSettings: DevelopSettings?
    private var fullBeforeRendering = false
    private var fullBeforeNeedsRender = false

    /// The sharpest unedited image for the compare views.
    var displayBeforeImage: NSImage? {
        if let fullBeforeImage, fullBeforeSettings == beforeSettings { return fullBeforeImage }
        return beforeImage
    }
    /// Where the slider divides before (left) and after (right), 0...1.
    @Published var sliderPosition = 0.5

    @Published private(set) var histogram: Histogram?
    /// Where the render's colors sit on the Color Grading wheels.
    @Published private(set) var colorScope: ColorScope?

    /// Lightroom's Option-drag view, while Option is held on a slider that has one.
    @Published var sliderPreview: SliderPreview? = nil {
        didSet { if sliderPreview != oldValue { scheduleRender() } }
    }

    /// The crop tool is open: the photo renders whole and turned, but not straightened, under the
    /// crop frame; the crop view turns it by the angle so straightening is instant.
    @Published var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            if isCropping {
                showingBefore = false
                isAIOpen = false
                isMasking = false
                isGuiding = false
                picker = nil
            } else {
                showCropOfWholeImage()
            }
            scheduleRender()
        }
    }

    private static let cropContext = CIContext()

    /// On closing the crop tool, cuts the whole photo still showing to the new crop at once, so
    /// the main view never flashes the uncropped photo before the cropped render lands.
    private func showCropOfWholeImage() {
        guard imageIsWhole, let crop = settings.crop,
              let whole = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // The crop tool's image is already turned and flipped, but not straightened.
        var cut = crop
        cut.quarterTurns = 0
        cut.flipHorizontal = false
        cut.flipVertical = false
        let cropped = DevelopRenderer.applyGeometry(cut, to: CIImage(cgImage: whole))
        guard let cgImage = Self.cropContext.createCGImage(cropped, from: cropped.extent.integral, format: .RGBA8,
                                                           colorSpace: whole.colorSpace ?? DevelopRenderer.displaySpace)
        else { return }
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        imageIsWhole = false
    }

    /// The AI tool is open: the photo shows under the AI brush and the AI panel replaces Crop.
    @Published var isAIOpen = false {
        didSet {
            guard isAIOpen != oldValue else { return }
            // The AI tool works on the plain photo, without the clipping overlay.
            if showShadowClipping || showHighlightClipping { clippingOverlayChanged() }
            guard isAIOpen else { return }
            isCropping = false
            isMasking = false
            isGuiding = false
            picker = nil
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
                isGuiding = false
                picker = nil
                showingBefore = false
                compareMode = .off
                if selectedMaskID == nil { selectedMaskID = settings.masks.last?.id }
            } else {
                maskTool = nil
            }
            scheduleRender()
        }
    }
    /// Guided Upright is open: the guides are drawn on the photo as edited, crop included.
    @Published var isGuiding = false {
        didSet {
            guard isGuiding != oldValue else { return }
            if isGuiding {
                picker = nil
                isCropping = false
                isAIOpen = false
                isMasking = false
                showingBefore = false
                compareMode = .off
            }
            selectedGuide = nil
            scheduleRender()
        }
    }
    /// Guided tool > Show Whole Photo: the view zooms out, uncropped, so every guide shows,
    /// whatever the correction pushed out of the frame. View only; remembered.
    @Published var guidedShowsWholePhoto = UserDefaults.standard.bool(forKey: "guidedUprightShowsWholePhoto") {
        didSet {
            UserDefaults.standard.set(guidedShowsWholePhoto, forKey: "guidedUprightShowsWholePhoto")
            if isGuiding { scheduleRender() }
        }
    }
    /// The guide selected with a click, for Delete.
    @Published var selectedGuide: Int?
    /// Guided was opened with ⌥ held, so its correction keeps the crop and Transform sliders.
    private var guidedKeepsSettings = false
    /// Upright is looking for lines.
    @Published private(set) var isFindingLines = false
    /// Why the last Upright button changed nothing.
    @Published var uprightMessage: String?
    /// From the open photo's file, for Lens Corrections and Transform.
    @Published private(set) var lensName: String?
    @Published private(set) var lensCorrectionSupported = false
    @Published private(set) var isRAW = false
    private(set) var focalLength35 = 0.0
    /// ISO, focal length, aperture and shutter speed for the line under the histogram.
    @Published private(set) var shootingInfo: ShootingInfo?
    /// Lightroom's clipping overlay (J, or the histogram's triangles): clipped highlights red and
    /// clipped shadows blue on the photo. Off for each new launch, as in Lightroom.
    @Published var showHighlightClipping = false {
        didSet { if showHighlightClipping != oldValue { clippingOverlayChanged() } }
    }
    @Published var showShadowClipping = false {
        didSet { if showShadowClipping != oldValue { clippingOverlayChanged() } }
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
    /// A note under the Masks list, e.g. when Select Subject finds nothing.
    @Published var maskMessage: String?
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
        didSet {
            if wantsFullResolution, !oldValue {
                scheduleFullRender()
                scheduleFullBeforeRender()
            }
        }
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
        if isCropping || (isMasking && showMaskOverlay) || sliderPreview != nil { return image }
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
    /// Built-in packs hidden with Hide Group or Develop > Manage Presets….
    @Published var hiddenPresetGroups = Set(UserDefaults.standard.stringArray(forKey: "presets.hiddenGroups") ?? []) {
        didSet { UserDefaults.standard.set(hiddenPresetGroups.sorted(), forKey: "presets.hiddenGroups") }
    }
    /// The presets to list: all but the hidden packs.
    var visiblePresets: [DevelopPreset] {
        presets.filter { !$0.isBuiltIn || !hiddenPresetGroups.contains($0.group) }
    }
    /// The presets applied most recently, newest first, for the Recent group (an app preference).
    @Published private(set) var recentPresetIDs = (UserDefaults.standard.stringArray(forKey: "presets.recent") ?? [])
        .compactMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(recentPresetIDs.map(\.uuidString), forKey: "presets.recent") }
    }
    /// The Recent group's presets: hidden packs and deleted presets drop out.
    var recentPresets: [DevelopPreset] { RecentPresets.presets(recentPresetIDs, in: visiblePresets) }

    func removeFromRecent(_ preset: DevelopPreset) {
        recentPresetIDs.removeAll { $0 == preset.id }
    }

    func clearRecentPresets() {
        recentPresetIDs = []
    }
    /// The user's groups, User Presets first, for the group pickers.
    var userPresetGroups: [String] {
        var groups = [DevelopPreset.defaultGroup]
        for preset in presets where !preset.isBuiltIn && !groups.contains(preset.group) { groups.append(preset.group) }
        return groups
    }
    /// The preset last clicked on the open photo, for the Amount slider; cleared by any other edit.
    @Published private(set) var presetAmount: PresetAmount?
    private var settingPresetAmount = false
    /// The preset under the pointer, shown in the Navigator (not on the photo) until the pointer
    /// leaves it, as in Lightroom Classic.
    @Published private(set) var previewingPreset: DevelopPreset?
    /// The open photo with `previewingPreset` applied, rendered small for the Navigator.
    @Published private(set) var navigatorPreview: NSImage?
    /// Long edge of the Navigator's preset previews: small, so hovering feels instant.
    nonisolated static let navigatorSize = 560
    private var navigatorSession: DevelopSession?
    private var navigatorRendering = false
    private var navigatorNeedsRender = false
    private let navigatorQueue = DispatchQueue(label: "atelier.develop.navigator", qos: .userInitiated)
    /// Develop > New Preset… and Manage Presets… open these sheets in the Presets panel.
    @Published var showingNewPreset = false
    @Published var showingManagePresets = false

    struct PresetAmount: Equatable {
        let preset: DevelopPreset
        let assetID: Int64
        /// The photo's settings before the preset.
        let base: DevelopSettings
        /// Percent, 0 to 200.
        var amount: Double
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
    var onSettingsSaved: ((Int64) -> Void)?
    /// Unedited RAW files whose preview was replaced by a render this launch.
    private var developedPreviews = Set<Int64>()

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
        imageIsWhole = false
        beforeImage = nil
        histogram = nil
        shootingInfo = nil
        colorScope = nil
        fullImage = nil
        fullImageSettings = nil
        fullBeforeImage = nil
        fullBeforeSettings = nil
        fullSession = nil
        sourceURL = nil
        errorMessage = nil
        showingBefore = false
        isCropping = false
        isGuiding = false
        picker = nil
        uprightMessage = nil
        sourceSize = nil
        selectedMaskID = nil
        selectedComponentID = nil
        maskTool = nil
        maskMessage = nil
        presetAmount = nil
        previewingPreset = nil
        navigatorPreview = nil
        navigatorSession = nil
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
        Task.detached(priority: .userInitiated) {
            let info = ShootingInfo(url: url)
            await MainActor.run {
                if self.assetID == assetID { self.shootingInfo = info }
            }
        }
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
                    self.asShotTint = session.asShotTint
                    self.lensName = session.lensName
                    self.lensCorrectionSupported = session.lensCorrectionSupported
                    self.isRAW = session.isRAW
                    self.focalLength35 = session.focalLength35
                    // Keep the saved crop; photos saved when Constrain Crop enlarged the photo
                    // instead of cropping it get the largest crop.
                    if self.settings.constrainCrop, self.settings.crop?.hasCut == true {
                        self.constrainedGeometry = self.settings.lensGeometryKey
                    }
                    if self.constrainCropIfNeeded() {
                        self.dirty = true
                        self.scheduleSave()
                    }
                    self.scheduleRender()
                    // An unedited RAW's cached preview is the camera's embedded JPEG, which has no
                    // lens corrections, so it is framed a little wider than the render and the
                    // photo jumped when the render replaced it. Store the render as the preview
                    // (once per photo per launch) so the next visit opens on the same framing.
                    if session.isRAW, session.lensCorrectionSupported, self.settings.isNeutral,
                       self.developedPreviews.insert(assetID).inserted {
                        self.storePreviews(session: session, settings: self.settings, assetID: assetID)
                    }
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

    // MARK: Slider display

    /// What a Basic slider shows. As in Lightroom, Tint shows the camera's tint plus the change,
    /// and a JPEG, HEIC or TIFF has no real Kelvin, so its Temp is a relative -100...+100.
    func sliderValue(_ parameter: DevelopSettings.Parameter) -> Double {
        switch parameter {
        case .temperature where !isRAW:
            return settings.temperature.map { Self.relativeTemperature(kelvin: $0) } ?? 0
        case .tint: return asShotTint + settings.tint
        default: return value(parameter)
        }
    }

    func setSlider(_ parameter: DevelopSettings.Parameter, to shown: Double) {
        switch parameter {
        case .temperature where !isRAW:
            let relative = min(100, max(-100, shown.rounded()))
            guard assetID != nil else { return }
            settings.temperature = relative == 0 ? nil : Self.kelvin(relativeTemperature: relative)
            changed(step: "Temp \(relative == 0 ? "0" : String(format: "%+.0f", relative))")
        case .tint:
            let range = sliderRange(.tint)
            set(.tint, to: min(range.upperBound, max(range.lowerBound, shown)) - asShotTint)
        default:
            set(parameter, to: shown)
        }
    }

    func sliderRange(_ parameter: DevelopSettings.Parameter) -> ClosedRange<Double> {
        switch parameter {
        case .temperature where !isRAW: return -100...100
        case .tint: return isRAW ? -150...150 : -100...100
        default: return parameter.range
        }
    }

    func sliderDefault(_ parameter: DevelopSettings.Parameter) -> Double {
        switch parameter {
        case .temperature where !isRAW: return 0
        case .tint: return asShotTint
        default: return defaultValue(parameter)
        }
    }

    /// A relative Temp for non-RAW files, the same scale masks use: each 100 doubles or
    /// halves the Kelvin shift from 6500 K by a factor of 2^0.8.
    nonisolated static func kelvin(relativeTemperature relative: Double) -> Double {
        6500 * pow(2, relative / 100 * 0.8)
    }

    nonisolated static func relativeTemperature(kelvin: Double) -> Double {
        (log2(kelvin / 6500) / 0.8 * 100).rounded()
    }

    // MARK: White balance

    /// The White Balance menu's current entry: As Shot, a preset, or Custom.
    var whiteBalanceName: String {
        if settings.temperature == nil, settings.tint == 0 { return "As Shot" }
        if isRAW, let preset = WhiteBalance.presets.first(where: { matches($0) }) { return preset.name }
        return "Custom"
    }

    private func matches(_ preset: WhiteBalance.Preset) -> Bool {
        settings.temperature == preset.temperature && abs(settings.tint - (preset.tint - asShotTint).rounded()) < 0.5
    }

    func setWhiteBalanceAsShot() {
        guard assetID != nil, settings.temperature != nil || settings.tint != 0 else { return }
        settings.temperature = nil
        settings.tint = 0
        changed(step: "White Balance: As Shot")
    }

    func applyWhiteBalance(_ preset: WhiteBalance.Preset) {
        guard assetID != nil, !matches(preset) else { return }
        settings.temperature = preset.temperature
        settings.tint = (preset.tint - asShotTint).rounded()
        changed(step: "White Balance: \(preset.name)")
    }

    /// Auto white balance (⇧⌘U), or with `point` (0 to 1 from the top left of the shown photo)
    /// the White Balance Selector: makes that spot neutral.
    func findWhiteBalance(at point: CGPoint? = nil) {
        isPickingWhiteBalance = false
        guard let session, let assetID, !isFindingWhiteBalance else { return }
        let settings = self.settings
        let tint = asShotTint
        let area = point.map { CGRect(x: $0.x - 0.006, y: $0.y - 0.006, width: 0.012, height: 0.012) }
        isFindingWhiteBalance = true
        queue.async {
            let found = WhiteBalance.neutral(session: session, settings: settings, area: area, asShotTint: tint)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isFindingWhiteBalance = false
                    guard self.assetID == assetID, let found else { return }
                    self.settings.temperature = found.temperature
                    self.settings.tint = found.tint
                    self.changed(step: point == nil ? "White Balance: Auto" : "White Balance Selector")
                }
            }
        }
    }

    // MARK: Auto

    /// Auto is measuring the photo.
    @Published private(set) var isFindingAutoTone = false

    /// Sliders with an Auto value (Shift-double-click on the name, as in Lightroom).
    func canAuto(_ parameter: DevelopSettings.Parameter) -> Bool {
        parameter == .temperature || parameter == .tint || AutoTone.parameters.contains(parameter)
    }

    /// Basic > Auto, or with `only` that one slider. Temp and Tint run Auto white balance.
    func autoTone(only parameter: DevelopSettings.Parameter? = nil) {
        if parameter == .temperature || parameter == .tint {
            findWhiteBalance()
            return
        }
        guard let session, let assetID, !isFindingAutoTone else { return }
        let settings = self.settings
        isFindingAutoTone = true
        queue.async {
            let found = AutoTone.apply(session: session, settings: settings, only: parameter)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isFindingAutoTone = false
                    guard self.assetID == assetID, let found, found != self.settings else { return }
                    for tone in AutoTone.parameters where parameter == nil || parameter == tone {
                        self.settings[tone] = found[tone]
                    }
                    self.changed(step: parameter.map { "Auto \(Self.parameterName($0))" } ?? "Auto Tone")
                }
            }
        }
    }

    func set(_ parameter: DevelopSettings.Parameter, to value: Double) {
        guard assetID != nil else { return }
        settings[parameter] = value
        if (parameter.panel == .lensCorrections && !parameter.isDefringe) || parameter.panel == .transform { beforeImage = nil }
        let shown = parameter == .tint ? asShotTint + settings[parameter] : settings[parameter]
        changed(step: Self.stepName(parameter, value: shown))
        if beforeImage == nil, compareMode != .off { renderBeforeIfNeeded() }
    }

    func reset(_ parameter: DevelopSettings.Parameter) {
        guard assetID != nil else { return }
        switch parameter {
        case .temperature: settings.temperature = nil
        default: settings[parameter] = DevelopSettings.neutral[parameter]
        }
        changed(step: "Reset \(Self.parameterName(parameter))")
    }

    /// A group heading's reset (Tone, Presence, Sharpening, Region, ...), as one history step.
    func reset(group: String, parameters: [DevelopSettings.Parameter]) {
        guard assetID != nil else { return }
        let before = settings
        for parameter in parameters {
            if parameter == .temperature {
                settings.temperature = nil
            } else {
                settings[parameter] = DevelopSettings.neutral[parameter]
            }
        }
        guard settings != before else { return }
        if parameters.contains(where: { ($0.panel == .lensCorrections && !$0.isDefringe) || $0.panel == .transform }) {
            shapeChanged(step: "Reset \(group)")
        } else {
            changed(step: "Reset \(group)")
        }
    }

    // MARK: Color Grading

    /// A wheel's hue and saturation together, as one history step.
    func setGradeColor(_ region: DevelopSettings.GradeRegion, hue: Double, saturation: Double) {
        guard assetID != nil else { return }
        settings[region.hue] = hue
        settings[region.saturation] = saturation
        changed(step: "Color Grading \(region.rawValue) \(Int(settings[region.hue].rounded()))°, "
                + "\(Int(settings[region.saturation].rounded()))")
    }

    /// Resets a wheel's hue and saturation, and with `luminance` its Luminance too.
    func resetGrade(_ region: DevelopSettings.GradeRegion, luminance: Bool) {
        guard assetID != nil else { return }
        var parameters = [region.hue, region.saturation]
        if luminance { parameters.append(region.luminance) }
        for parameter in parameters { settings[parameter] = DevelopSettings.neutral[parameter] }
        changed(step: "Reset Color Grading \(region.rawValue)")
    }

    /// One wheel's settings, for Copy and Paste in a wheel's right-click menu.
    struct GradeWheelValues: Equatable {
        var hue: Double
        var saturation: Double
        var luminance: Double
    }

    @Published private(set) var copiedGradeWheel: GradeWheelValues?

    func copyGradeWheel(_ region: DevelopSettings.GradeRegion) {
        copiedGradeWheel = GradeWheelValues(hue: settings[region.hue], saturation: settings[region.saturation],
                                            luminance: settings[region.luminance])
    }

    func pasteGradeWheel(onto region: DevelopSettings.GradeRegion) {
        guard assetID != nil, let copied = copiedGradeWheel else { return }
        settings[region.hue] = copied.hue
        settings[region.saturation] = copied.saturation
        settings[region.luminance] = copied.luminance
        changed(step: "Paste Color Grading \(region.rawValue)")
    }

    /// The wheel under the pointer, which the arrow keys nudge.
    var hoveredGradeRegion: DevelopSettings.GradeRegion?

    /// Arrow keys over a wheel: Left and Right turn the hue, Up and Down change saturation.
    func nudgeGrade(_ region: DevelopSettings.GradeRegion, hue: Double, saturation: Double) {
        var newHue = (settings[region.hue] + hue).truncatingRemainder(dividingBy: 360)
        if newHue < 0 { newHue += 360 }
        setGradeColor(region, hue: newHue, saturation: min(100, max(0, settings[region.saturation] + saturation)))
    }

    /// Color Grading's color picker: sets a wheel so the clicked spot's color cast turns neutral.
    func pickGradeColor(at point: CGPoint) {
        let sharp = wantsFullResolution ? fullSession : nil
        guard let session = sharp ?? self.session, let assetID else { return }
        let settings = self.settings
        let region = gradePickRegion
        let pickQueue = sharp != nil ? fullQueue : queue
        pickQueue.async {
            let sample = session.color(at: point, settings: settings)
            let pick = sample.flatMap { ColorGrade.neutralizing($0, settings: settings, region: region) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, self.isPickingGradeColor else { return }
                    guard let pick else {
                        self.pickerMessage = sample == nil || region == nil
                            ? "Cannot read the color there. Click another spot."
                            : "That spot is hardly in the \(region!.rawValue). Click another spot, or use the 3-Way view."
                        return
                    }
                    self.isPickingGradeColor = false
                    self.setGradeColor(pick.region, hue: pick.hue, saturation: pick.saturation)
                }
            }
        }
    }

    func setPoints(_ points: [DevelopSettings.CurvePoint], for channel: DevelopSettings.CurveChannel) {
        guard assetID != nil else { return }
        settings.setPoints(points, for: channel)
        changed(step: "Tone Curve (\(channel.label))")
    }

    /// Several settings changed as one history step (the Targeted Adjustment Tool, Point Color).
    func setValues(_ values: [DevelopSettings.Parameter: Double], step: String) {
        guard assetID != nil else { return }
        for (parameter, value) in values { settings[parameter] = value }
        changed(step: step)
    }

    /// The finished photo's sRGB-encoded color around `point` (0...1 from the top left), rendered
    /// with `settings`, off the main thread; `done` runs on the main actor, unless another photo
    /// has opened by then.
    func sampleColor(at point: CGPoint, settings: DevelopSettings,
                     done: @escaping @MainActor (SIMD3<Double>?) -> Void) {
        let sharp = wantsFullResolution ? fullSession : nil
        guard let session = sharp ?? self.session, let assetID else { return }
        let pickQueue = sharp != nil ? fullQueue : queue
        pickQueue.async {
            let sample = session.color(at: point, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID else { return }
                    done(sample)
                }
            }
        }
    }

    func reset(_ panel: DevelopSettings.Panel) {
        guard assetID != nil else { return }
        switch panel {
        case .basic:
            settings.profile = .cameraMatching
            settings.monochrome = false
        case .toneCurve:
            for channel in DevelopSettings.CurveChannel.allCases { settings.setPoints([], for: channel) }
        case .lensCorrections:
            settings.lensProfileCorrections = true
            settings.removeChromaticAberration = false
        case .transform:
            settings.upright = nil
            settings.constrainCrop = false
            isGuiding = false
        default:
            break
        }
        settings.setPanel(panel, on: true)
        if panel == .lensCorrections || panel == .transform { beforeImage = nil }
        for parameter in panel.parameters {
            if parameter == .temperature {
                settings.temperature = nil
            } else {
                settings[parameter] = DevelopSettings.neutral[parameter]
            }
        }
        changed(step: "Reset \(panel.title)")
    }

    // MARK: Panel switches

    func isPanelOn(_ panel: DevelopSettings.Panel) -> Bool { settings.isOn(panel) }

    /// A panel header's switch, as in Lightroom: off hides the panel's effect and keeps its
    /// settings. Moving any of the panel's controls turns it back on (see `changed`).
    func setPanelOn(_ panel: DevelopSettings.Panel, _ on: Bool) {
        guard assetID != nil, panel.hasSwitch, on != isPanelOn(panel) else { return }
        // Its own history step, at once, so an edit right after it is compared with the panel off.
        commitPendingStep()
        settings.setPanel(panel, on: on)
        let step = "\(panel.title) \(on ? "On" : "Off")"
        if panel == .lensCorrections || panel == .transform {
            if !on { isGuiding = false }
            shapeChanged(step: step)
        } else {
            changed(step: step)
        }
        commitPendingStep()
    }

    func isModified(_ panel: DevelopSettings.Panel) -> Bool {
        if !settings.isOn(panel) { return true }
        switch panel {
        case .basic where settings.profile != .cameraMatching || settings.monochrome: return true
        case .toneCurve where settings.hasPointCurve: return true
        case .lensCorrections where !settings.lensProfileCorrections || settings.removeChromaticAberration: return true
        case .transform where settings.upright != nil || settings.constrainCrop: return true
        default: break
        }
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

    /// The photo without edits but with the same shape (lens corrections, Transform and crop),
    /// so before and after line up.
    private var beforeSettings: DevelopSettings {
        var before = settings.lensGeometryKey
        before.crop = settings.crop
        return before
    }

    // MARK: Profile, Lens Corrections and Transform

    /// Basic > Treatment: Color or Black & White (V).
    func setMonochrome(_ on: Bool) {
        guard assetID != nil, on != settings.monochrome else { return }
        settings.monochrome = on
        changed(step: on ? "Treatment: Black & White" : "Treatment: Color")
    }

    func setProfile(_ profile: DevelopSettings.Profile) {
        guard assetID != nil, profile != settings.profile else { return }
        settings.profile = profile
        changed(step: "Profile: \(profile.title)")
    }

    func setLensProfileCorrections(_ on: Bool) {
        guard assetID != nil, on != settings.lensProfileCorrections else { return }
        settings.lensProfileCorrections = on
        shapeChanged(step: on ? "Enable Profile Corrections" : "Disable Profile Corrections")
    }

    /// Lens Corrections > Remove Chromatic Aberration.
    func setRemoveChromaticAberration(_ on: Bool) {
        guard assetID != nil, on != settings.removeChromaticAberration else { return }
        settings.removeChromaticAberration = on
        changed(step: on ? "Remove Chromatic Aberration" : "Chromatic Aberration: Off")
    }

    /// A Defringe Hue range. `moving` is the end being dragged; nil moves the whole range.
    func setHueRange(_ color: DevelopSettings.FringeColor, low: Double, high: Double,
                     moving: DevelopSettings.Parameter? = nil) {
        guard assetID != nil else { return }
        var updated = settings
        updated.setHueRange(color, low: low.rounded(), high: high.rounded(), moving: moving)
        guard updated != settings else { return }
        settings = updated
        changed(step: "Defringe \(color.title) Hue \(Int(settings[color.hueLow]))/\(Int(settings[color.hueHigh]))")
    }

    func resetHueRange(_ color: DevelopSettings.FringeColor) {
        setHueRange(color, low: color.hueLow.defaultValue, high: color.hueHigh.defaultValue)
    }

    /// A click with the Fringe Color Selector at `point` (0...1 from the top left of the
    /// cropped photo). Measures the sharpest render on screen, so zooming in first helps.
    func pickFringe(at point: CGPoint) {
        let sharp = wantsFullResolution ? fullSession : nil
        guard let session = sharp ?? self.session, let assetID else { return }
        let settings = self.settings
        let pickQueue = sharp != nil ? fullQueue : queue
        pickQueue.async {
            let colors = session.fringeColors(at: point, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, self.isPickingFringe else { return }
                    guard let pick = Defringe.pick(colors, settings: self.settings) else {
                        self.pickerMessage = "Cannot set the purple or green fringe color. Click on a purple or green fringe."
                        return
                    }
                    var updated = self.settings
                    updated.setHueRange(pick.color, low: pick.hueLow, high: pick.hueHigh)
                    updated[pick.color.amount] = pick.amount
                    self.isPickingFringe = false
                    guard updated != self.settings else { return }
                    self.settings = updated
                    self.changed(step: "Defringe: \(pick.color.title) Fringe Color")
                }
            }
        }
    }

    func setConstrainCrop(_ on: Bool) {
        guard assetID != nil, on != settings.constrainCrop else { return }
        settings.constrainCrop = on
        shapeChanged(step: on ? "Constrain Crop" : "Unconstrain Crop")
    }

    /// An Upright button: nil is Off; Guided opens the guides tool; the others find the photo's
    /// lines and solve for them. As in Lightroom, applying a mode resets the crop and the manual
    /// Transform sliders unless `keepSettings` (⌥-click).
    func setUpright(_ mode: DevelopSettings.Upright.Mode?, keepSettings: Bool = false) {
        guard assetID != nil else { return }
        uprightMessage = nil
        guard let mode else {
            isGuiding = false
            guard settings.upright != nil else { return }
            settings.upright = nil
            shapeChanged(step: "Upright: Off")
            return
        }
        if mode == .guided {
            isGuiding = true
            guidedKeepsSettings = keepSettings
            if settings.upright?.mode != .guided { setGuides(settings.upright?.guides ?? []) }
            return
        }
        isGuiding = false
        guard let session, let sourceSize else { return }
        let settings = self.settings
        let assetID = self.assetID
        let focal = focalLength35
        isFindingLines = true
        queue.async {
            let lines = session.lines(for: settings)
            let upright = UprightSolver.solve(mode, lines: lines, size: sourceSize, focalLength35: focal)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isFindingLines = false
                    guard self.assetID == assetID else { return }
                    guard let upright else {
                        self.uprightMessage = "Not enough straight lines found for \(mode.title)."
                        return
                    }
                    if !keepSettings { self.clearForUpright() }
                    self.settings.upright = upright
                    self.shapeChanged(step: "Upright: \(mode.title)")
                }
            }
        }
    }

    /// Guided Upright's lines changed: solve again from them. The photo changes once there are
    /// two guides, as in Lightroom; that first correction resets the crop and Transform sliders.
    func setGuides(_ guides: [DevelopSettings.Guide]) {
        guard assetID != nil, let sourceSize else { return }
        let guides = Array(guides.prefix(DevelopSettings.Upright.maxGuides))
        let minimum = DevelopSettings.Upright.minGuides
        let wasCorrecting = settings.upright?.mode == .guided && (settings.upright?.guides.count ?? 0) >= minimum
        if guides.count >= minimum, !wasCorrecting, !guidedKeepsSettings { clearForUpright() }
        let lines = guides.map { LineSegment(start: CGPoint(x: $0.start.x, y: $0.start.y), end: CGPoint(x: $0.end.x, y: $0.end.y)) }
        var upright = UprightSolver.solve(.guided, lines: lines, size: sourceSize, focalLength35: focalLength35)
            ?? DevelopSettings.Upright(mode: .guided)
        upright.guides = guides
        let added = guides.count > (settings.upright?.guides.count ?? 0)
        settings.upright = upright
        if let selected = selectedGuide, selected >= guides.count { selectedGuide = nil }
        shapeChanged(step: added ? "Add Guide" : "Upright: Guided")
    }

    /// What applying an Upright mode resets in Lightroom: the crop's cut and straighten (turns
    /// and flips stay) and the manual Transform sliders.
    private func clearForUpright() {
        for parameter in DevelopSettings.Panel.transform.parameters {
            settings[parameter] = DevelopSettings.neutral[parameter]
        }
        guard var crop = settings.crop else { return }
        crop.angle = 0
        crop.x = 0
        crop.y = 0
        crop.width = 1
        crop.height = 1
        settings.crop = crop.isIdentity ? nil : crop
    }

    func deleteSelectedGuide() {
        guard let index = selectedGuide, var guides = settings.upright?.guides, guides.indices.contains(index) else { return }
        guides.remove(at: index)
        selectedGuide = nil
        setGuides(guides)
        DeleteFeedback.play(.remove)
    }

    /// The Transform's mapping between the corrected photo and the output.
    var lensGeometry: LensGeometry? {
        guard let sourceSize else { return nil }
        return LensGeometry(settings: settings, size: sourceSize, focalLength35: focalLength35)
    }

    /// Constrain Crop's test for the crop tool: whether a point on the upright, uncropped photo
    /// (0...1 from the top left) shows the photo rather than the gray fill. nil when it is off.
    var cropBounds: ((CGPoint) -> Bool)? {
        guard settings.constrainCrop, let geometry = lensGeometry else { return nil }
        return { geometry.showsPhoto(at: $0) }
    }

    /// The shape-deciding settings Constrain Crop last fitted the crop to.
    private var constrainedGeometry: DevelopSettings?

    /// Constrain Crop, as in Lightroom. When it is turned on or the correction changes, the crop
    /// becomes the largest one of its shape with no gray edge, placed where it fits best (so it
    /// grows back when a correction gets milder). Otherwise the crop is only kept inside the
    /// photo, so a crop drawn by hand stays. Returns whether the crop changed.
    @discardableResult
    private func constrainCropIfNeeded() -> Bool {
        guard let bounds = cropBounds else {
            constrainedGeometry = nil
            return false
        }
        let key = settings.lensGeometryKey
        let updated = key == constrainedGeometry ? crop.fitted(imageAspect: orientedAspect, onPhoto: bounds)
            : crop.largest(imageAspect: orientedAspect, onPhoto: bounds)
        constrainedGeometry = key
        guard updated != crop else { return false }
        settings.crop = updated
        return true
    }

    // The Guided tool works on the photo as edited, crop included, as in Lightroom, unless Show
    // Whole Photo is on. Guides are stored on the photo before the Transform (0...1 from the top
    // left); the view is the output (0...1 from its top left).

    /// What the Guided view renders: the edit, or with Show Whole Photo the whole corrected
    /// photo, uncropped and zoomed out as far as it needs.
    private func guidedViewSettings(_ settings: DevelopSettings) -> DevelopSettings {
        guard guidedShowsWholePhoto else { return settings }
        var view = settings
        view.crop = nil
        view.showsWholePhoto = true
        return view
    }

    private var guidedView: (geometry: LensGeometry, crop: DevelopSettings.Crop)? {
        guard let sourceSize else { return nil }
        let view = guidedViewSettings(settings)
        return (LensGeometry(settings: view, size: sourceSize, focalLength35: focalLength35),
                view.crop ?? DevelopSettings.Crop())
    }

    /// Where a point of the photo before the Transform shows in the Guided view.
    func guidedViewPoint(fromPhoto point: CGPoint) -> CGPoint? {
        guard let sourceSize, let view = guidedView else { return nil }
        let crop = view.crop
        let corrected = view.geometry.outputPoint(fromSource: point)
        let output = crop.outputPoint(fromSource: CGPoint(x: corrected.x * sourceSize.width, y: corrected.y * sourceSize.height),
                                      sourceSize: sourceSize)
        let turned = crop.orientedSize(sourceSize)
        return CGPoint(x: output.x / (turned.width * crop.width), y: output.y / (turned.height * crop.height))
    }

    /// The photo point (before the Transform) under a point of the Guided view.
    func guidedPhotoPoint(fromView point: CGPoint) -> CGPoint? {
        guard let sourceSize, let view = guidedView else { return nil }
        let crop = view.crop
        let turned = crop.orientedSize(sourceSize)
        let output = CGPoint(x: point.x * turned.width * crop.width, y: point.y * turned.height * crop.height)
        let upright = crop.sourcePoint(fromOutput: output, sourceSize: sourceSize)
        return view.geometry.sourcePoint(fromOutput: CGPoint(x: upright.x / sourceSize.width, y: upright.y / sourceSize.height))
    }

    /// Lightroom's ⌘⌥-drag in the Guided tool: moves the photo in its frame through X and Y
    /// Offset, to bring back what the correction pushed out. `dx`, `dy` are fractions of the
    /// view; `start` the offsets when the drag began.
    func dragTransformOffsets(from start: (x: Double, y: Double), dx: Double, dy: Double) {
        guard assetID != nil else { return }
        let crop = guidedView?.crop ?? self.crop
        // 100 moves the photo half the uncropped frame.
        settings[.transformOffsetX] = (start.x + dx * crop.width * 200).rounded()
        settings[.transformOffsetY] = (start.y + dy * crop.height * 200).rounded()
        beforeImage = nil
        changed(step: "Transform Offset")
    }

    /// An edit that changes the photo's shape, so the Before view has to follow.
    private func shapeChanged(step: String) {
        beforeImage = nil
        changed(step: step)
        if compareMode != .off { renderBeforeIfNeeded() }
    }

    /// The full-size photo's size after the crop, for 100% zoom. `assetSize` is the original's
    /// pixel size from the catalog.
    func croppedPixelSize(assetSize: CGSize?) -> CGSize? {
        guard let assetSize else { return nil }
        // Until the photo decodes, crop the catalog's size; returning it uncropped made a
        // cropped photo's 100% zoom jump when the decoded size arrived.
        guard let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else { return crop.outputSize(assetSize) }
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
            do {
                try catalog.saveDevelopSettings(newSettings, for: id, step: step)
                onSettingsSaved?(id)
            } catch {
                errorMessage = "Could not save: \(error.localizedDescription)"
                continue
            }
            refreshPreviews(for: id, settings: newSettings)
        }
        if let assetID, targets.contains(assetID) {
            settings = newSettings
            validateMaskSelection()
            changed(step: step, replacing: true)
        }
    }

    /// An edit to the open photo. `step` names it in the history; nil (undo, redo, jumping
    /// in the history) saves without adding a step. `replacing` is for whole settings put in
    /// place (a preset, a snapshot, Paste), whose panel switches stand as they come.
    private func changed(step: String?, replacing: Bool = false) {
        if step != nil, !replacing { turnOnEditedPanels() }
        if !settingPresetAmount { presetAmount = nil }
        constrainCropIfNeeded()
        dirty = true
        if let step { pendingStep = step }
        scheduleRender()
        scheduleSave()
    }

    /// As in Lightroom, changing anything in a panel that is off turns it back on, so an edit
    /// never goes unseen. Compares with the last history step, so a drag turns it on once.
    private func turnOnEditedPanels() {
        for panel in settings.disabledPanels
        where !committed.isOn(panel) && committed.contents(of: panel) != settings.contents(of: panel) {
            settings.setPanel(panel, on: true)
            if panel == .lensCorrections || panel == .transform { beforeImage = nil }
        }
    }

    // MARK: Presets

    /// Applies a preset to the open photo, or to each photo in `assetIDs` on top of its own
    /// settings. On the open photo alone, the Amount slider then scales it.
    func applyPreset(_ preset: DevelopPreset, onto assetIDs: [Int64]? = nil) {
        previewingPreset = nil
        navigatorPreview = nil
        let step = "Preset: \(preset.name)"
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        if !targets.isEmpty { recentPresetIDs = RecentPresets.adding(preset.id, to: recentPresetIDs) }
        for id in targets where id != assetID {
            let base = (try? catalog.developSettings(for: id)) ?? .neutral
            let newSettings = preset.applied(to: base)
            do {
                try catalog.saveDevelopSettings(newSettings, for: id, step: step)
                onSettingsSaved?(id)
            } catch {
                errorMessage = "Could not save: \(error.localizedDescription)"
                continue
            }
            refreshPreviews(for: id, settings: newSettings)
        }
        if let assetID, targets.contains(assetID) {
            let base = settings
            settings = preset.applied(to: settings)
            validateMaskSelection()
            beforeImage = nil
            changed(step: step, replacing: true)
            // Saved and in the history at once, so leaving the photo right away can't lose it.
            flushSave()
            if targets.count == 1 { presetAmount = PresetAmount(preset: preset, assetID: assetID, base: base, amount: 100) }
        }
    }

    /// The Amount slider: the last clicked preset at `amount` percent, in the same history step.
    func setPresetAmount(_ amount: Double) {
        guard var state = presetAmount, state.assetID == assetID else { return }
        state.amount = min(200, max(0, amount.rounded()))
        guard state.amount != presetAmount?.amount else { return }
        settings = state.preset.applied(to: state.base, amount: state.amount / 100)
        validateMaskSelection()
        let step = "Preset: \(state.preset.name)"
        settingPresetAmount = true
        if pendingStep == nil, history.position == history.steps.count - 1, history.steps.last?.name == step {
            // The preset's step is already in the history: change it rather than adding one.
            history.steps[history.position].settings = settings
            committed = settings
            changed(step: nil)
        } else {
            changed(step: step, replacing: true)
        }
        settingPresetAmount = false
        presetAmount = state
    }

    /// Hover preview: shows `preset` on the photo without changing anything; nil restores it.
    func previewPreset(_ preset: DevelopPreset?) {
        guard preset != previewingPreset, assetID != nil else { return }
        previewingPreset = preset
        if preset == nil { navigatorPreview = nil } else { renderNavigatorPreview() }
    }

    /// Renders the hovered preset small, on its own queue so it never waits behind the photo.
    /// Latest wins: hovers during a render collapse into one follow-up.
    private func renderNavigatorPreview() {
        guard let preset = previewingPreset, let url = sourceURL else { return }
        if navigatorRendering {
            navigatorNeedsRender = true
            return
        }
        navigatorRendering = true
        let settings = preset.applied(to: self.settings)
        let assetID = self.assetID
        let existing = navigatorSession
        navigatorQueue.async {
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: Self.navigatorSize)
            let cgImage = session?.render(settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.navigatorRendering = false
                    guard self.assetID == assetID else { return }
                    self.navigatorSession = session
                    if self.previewingPreset == preset, let cgImage {
                        self.navigatorPreview = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    }
                    if self.navigatorNeedsRender {
                        self.navigatorNeedsRender = false
                        self.renderNavigatorPreview()
                    }
                }
            }
        }
    }

    /// Saves the open photo's settings as a preset with the chosen parts. `replacing` keeps an
    /// existing preset's ID so photos and import settings that use it follow the new version.
    func createPreset(name: String, group: String, parts: Set<DevelopPreset.Part>, replacing: DevelopPreset? = nil) {
        let preset = DevelopPreset(id: replacing?.id ?? UUID(), name: name, group: group, parts: parts, settings: settings)
        savePresets([preset])
    }

    /// Update with Current Settings: the open photo's settings with the chosen parts.
    func updatePreset(_ preset: DevelopPreset, parts: Set<DevelopPreset.Part>) {
        var updated = preset
        updated.settings = settings
        updated.parts = parts
        savePresets([updated])
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        var updated = preset
        updated.name = name
        savePresets([updated])
    }

    func movePreset(_ preset: DevelopPreset, to group: String) {
        guard !preset.isBuiltIn, preset.group != group else { return }
        var updated = preset
        updated.group = group
        savePresets([updated])
    }

    /// Duplicate (and, for built-in presets, Duplicate to User Presets): an editable copy.
    func duplicatePreset(_ preset: DevelopPreset) {
        let group = preset.isBuiltIn ? DevelopPreset.defaultGroup : preset.group
        let names = Set(presets.filter { $0.group == group }.map { $0.name.lowercased() })
        var name = preset.isBuiltIn ? preset.name : "\(preset.name) Copy"
        var number = 2
        while names.contains(name.lowercased()) {
            name = preset.isBuiltIn ? "\(preset.name) \(number)" : "\(preset.name) Copy \(number)"
            number += 1
        }
        savePresets([DevelopPreset(name: name, group: group, parts: preset.parts, settings: preset.settings)])
    }

    func deletePreset(_ preset: DevelopPreset) {
        if presetFileChange({ try presetStore.delete(preset.id) }) { DeleteFeedback.play(.remove) }
    }

    func renamePresetGroup(_ group: String, to name: String) {
        presetFileChange { try presetStore.renameGroup(group, to: name) }
    }

    func deletePresetGroup(_ group: String) {
        if presetFileChange({ _ = try presetStore.deleteGroup(group) }) { DeleteFeedback.play(.remove) }
    }

    /// The user's preset in `group` named `name`, ignoring case, if there is one.
    func userPreset(named name: String, in group: String) -> DevelopPreset? {
        presets.first { !$0.isBuiltIn && $0.group == group && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func showPresetsInFinder() {
        if FileManager.default.fileExists(atPath: presetStore.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([presetStore.fileURL])
        } else {
            NSWorkspace.shared.open(presetStore.fileURL.deletingLastPathComponent())
        }
    }

    private func savePresets(_ changed: [DevelopPreset]) {
        presetFileChange { try presetStore.save(changed) }
    }

    /// Whether the change was saved.
    @discardableResult
    private func presetFileChange(_ change: () throws -> Void) -> Bool {
        defer { presets = presetStore.all() }
        do {
            try change()
            return true
        } catch {
            errorMessage = "Could not save presets: \(error.localizedDescription)"
            return false
        }
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
        // The step's crop is already constrained; keep it.
        constrainedGeometry = settings.constrainCrop ? settings.lensGeometryKey : nil
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
        changed(step: "Snapshot: \(snapshot.name)", replacing: true)
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
        DeleteFeedback.play(.remove)
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
        if let point = parameter.pointColor { return "Point Color \(point.swatch + 1) \(point.setting.label)" }
        if let band = parameter.grayBand { return "B&W \(band.rawValue)" }
        switch parameter.panel {
        case .colorGrading, .detail, .effects, .toneCurve, .lensCorrections:
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
        case .transformRotate: formatted = String(format: "%+.1f°", value)
        case .vignetteStyle: formatted = DevelopSettings.VignetteStyle(rawValue: Int(value))?.title ?? ""
        case .glowStyle: formatted = DevelopSettings.GlowStyle(rawValue: Int(value))?.title ?? ""
        case .grainType: formatted = DevelopSettings.GrainType(rawValue: Int(value))?.title ?? ""
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
        var settings = showingBefore ? beforeSettings : self.settings
        if isGuiding { settings = guidedViewSettings(settings) }
        let cropping = !isCropping
        if isCropping, var crop = settings.crop {
            crop.angle = 0
            settings.crop = crop
        }
        let assetID = self.assetID
        let overlay = isMasking && showMaskOverlay ? selectedMaskID : nil
        let preview = showingBefore ? nil : sliderPreview
        let clipping = overlay == nil && preview == nil ? clippingOverlay : (shadows: false, highlights: false)
        queue.async {
            let rendered = session.render(settings, cropping: cropping, overlay: overlay, preview: preview)
            // The red overlay or an Option-drag view would skew the histogram; keep the last one while it shows.
            let histogram = overlay == nil && preview == nil ? rendered.flatMap { Histogram(image: $0) } : nil
            let scope = overlay == nil && preview == nil ? rendered.flatMap { ColorScope(image: $0) } : nil
            let cgImage = rendered.map { Self.withClipping($0, clipping) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.rendering = false
                    // A render started before the crop tool opened or closed has the wrong shape; the
                    // next render replaces it.
                    if self.assetID == assetID, cropping != self.isCropping, let cgImage {
                        self.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.imageIsWhole = !cropping
                        if let histogram { self.histogram = histogram }
                        if let scope { self.colorScope = scope }
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

    /// The clipping overlay the next render paints: none on the Before view or while cropping or
    /// using the AI tool, which work on the plain photo.
    private var clippingOverlay: (shadows: Bool, highlights: Bool) {
        guard !showingBefore, !isCropping, !isAIOpen else { return (false, false) }
        return (showShadowClipping, showHighlightClipping)
    }

    nonisolated private static func withClipping(_ image: CGImage, _ clipping: (shadows: Bool, highlights: Bool)) -> CGImage {
        guard clipping.shadows || clipping.highlights else { return image }
        return ClippingOverlay.apply(to: image, shadows: clipping.shadows, highlights: clipping.highlights) ?? image
    }

    /// J: both overlays on, or both off when either is on.
    func toggleClippingOverlay() {
        let on = !(showShadowClipping || showHighlightClipping)
        showShadowClipping = on
        showHighlightClipping = on
    }

    private func clippingOverlayChanged() {
        // The full-size render has the old overlay painted in; show the proxy until it is redone.
        fullImageSettings = nil
        scheduleRender()
    }

    /// Full-resolution render for zoomed views, after the proxy settles. Latest wins.
    private func scheduleFullRender() {
        guard wantsFullResolution, !showingBefore, !isCropping, !isGuiding, let url = sourceURL, fullImageSettings != settings else { return }
        if fullRendering {
            fullNeedsRender = true
            return
        }
        fullRendering = true
        let settings = self.settings
        let assetID = self.assetID
        let existing = fullSession
        let clipping = clippingOverlay
        fullQueue.async {
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: nil)
            let cgImage = session?.render(settings).map { Self.withClipping($0, clipping) }
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
                    if self.fullBeforeNeedsRender {
                        self.fullBeforeNeedsRender = false
                        self.scheduleFullBeforeRender()
                    }
                }
            }
        }
    }

    /// Renders the unedited photo at full size while a compare view is zoomed past fit, sharing
    /// the full-size session with the edited render.
    private func scheduleFullBeforeRender() {
        guard wantsFullResolution, compareMode != .off, let url = sourceURL else { return }
        let before = beforeSettings
        guard fullBeforeSettings != before else { return }
        // Wait for the edited render when it is still opening the full-size photo, so the
        // photo isn't decoded twice at once.
        if fullBeforeRendering || (fullSession == nil && fullRendering) {
            fullBeforeNeedsRender = true
            return
        }
        fullBeforeRendering = true
        let assetID = self.assetID
        let existing = fullSession
        fullQueue.async {
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: nil)
            let cgImage = session?.render(before)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fullBeforeRendering = false
                    guard self.assetID == assetID, let session else { return }
                    if self.fullSession == nil { self.fullSession = session }
                    if let cgImage {
                        self.fullBeforeImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.fullBeforeSettings = before
                    }
                    if self.fullBeforeNeedsRender {
                        self.fullBeforeNeedsRender = false
                        self.scheduleFullBeforeRender()
                    }
                }
            }
        }
    }

    private func renderBeforeIfNeeded() {
        scheduleFullBeforeRender()
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
            onSettingsSaved?(assetID)
        } catch {
            dirty = true
            errorMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        if let session {
            storePreviews(session: session, settings: settings, assetID: assetID)
        }
    }

    /// Renders `settings` in the background and stores it as the photo's grid thumbnail and
    /// loupe preview.
    private func storePreviews(session: DevelopSession, settings: DevelopSettings, assetID: Int64) {
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
        case .object: return "Drag a box around the object to select it."
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
        case .subject: return .subject(DevelopSettings.Selection())
        case .object: return .subject(DevelopSettings.Selection(box: .init(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
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
        maskMessage = nil
        if case .subject(let selection) = component.shape { checkSubject(selection) }
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

    /// Runs Vision in the background and says so in the panel when it finds nothing.
    func checkSubject(_ selection: DevelopSettings.Selection) {
        guard let session else { return }
        let settings = self.settings
        let assetID = self.assetID
        queue.async {
            let found = session.findsSubject(selection, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, !found else { return }
                    self.maskMessage = selection.box == nil
                        ? "No subject stands out in this photo. Try Select Object and drag a box around what you want."
                        : "Nothing found in that box. Try a box that fits closer around the object."
                }
            }
        }
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
        DeleteFeedback.play(.remove)
    }

    func deleteAllMasks() {
        guard !settings.masks.isEmpty else { return }
        settings.masks = []
        selectedMaskID = nil
        selectedComponentID = nil
        maskTool = nil
        changed(step: "Delete All Masks")
        DeleteFeedback.play(.remove)
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
        DeleteFeedback.play(.remove)
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
