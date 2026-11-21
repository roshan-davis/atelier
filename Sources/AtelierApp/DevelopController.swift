import AppKit
import AtelierCore
import CoreImage
import Foundation
import IOSurface
import QuartzCore

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

/// A render waiting for its histogram and color scope to be counted.
private struct DevelopMeasureRequest {
    let image: CGImage
    let assetID: Int64?
    let count: Int
    /// The open it belongs to (`DevelopController.openGeneration`), so work from before a
    /// `reopen()` of the same photo is dropped.
    let generation: Int
    /// Counted from the cached preview the photo opened on, not from a render. Kept with the
    /// request, as requests replace each other while waiting.
    var fromPreview = false

    /// Newer renders outrank older ones; for the same render count, a render outranks the cached
    /// preview, whichever arrives first.
    var rank: Int { count * 2 + (fromPreview ? 0 : 1) }
}

/// The open photo's histogram and color scope. They change with every render, so they are
/// published here rather than on `DevelopController`, whose every change updates the whole
/// Develop window (reports/develop-slider-smoothness-design-2026-11-10.md, S2 and D2).
@MainActor
final class DevelopMeasures: ObservableObject {
    @Published fileprivate(set) var histogram: Histogram?
    @Published fileprivate(set) var colorScope: ColorScope?
}

/// What a live frame shows: frames requested for another key are dropped (`LiveFrameSink`).
private struct LiveFrameKey: Equatable {
    let assetID: Int64?
    let generation: Int
    let cropping: Bool
    let preview: SliderPreview?
    let renderBefore: Bool
}

/// Everything a proxy render's picture depends on (`DevelopController.scheduleRender`).
private struct ProxyRenderKey: Equatable {
    let settings: DevelopSettings
    let preview: SliderPreview?
    let renderBefore: Bool
    let cropping: Bool
    let overlay: UUID?
    let shadowClipping: Bool
    let highlightClipping: Bool
    let assetID: Int64?
    let generation: Int
    let session: ObjectIdentifier
    let lensBlur: Bool
}

/// A proxy render handed to the render queue (`DevelopController.submitRender`).
private struct ProxyRenderRequest {
    let session: DevelopSession
    let settings: DevelopSettings
    let preview: SliderPreview?
    let renderBefore: Bool
    let cropping: Bool
    let overlay: UUID?
    let clipping: (shadows: Bool, highlights: Bool)
    let assetID: Int64?
    let count: Int
    let measures: Bool
    let generation: Int
    let queuedAt: CFAbsoluteTime
    /// Set when the frame goes straight to the photo view (`PhotoFeed`); nil renders a CGImage.
    var surfaces: DisplaySurfaces?
    var fallback: PhotoFeed.Fallback? = nil
    /// Puts the frame on screen from the render queue, if it still matches (`liveEpoch`).
    var sink: LiveFrameSink? = nil
    var liveEpoch = 0
    /// Zoomed in with a sharp detail frame asked for: the stretched proxy frame stays hidden.
    var hidesFrame = false
    let measureJob: LatestJob<DevelopMeasureRequest>
    let measureQueue: DispatchQueue
    let histogramSink: HistogramSink
    let openGeneration: LockedValue<Int>
    let renderBeganAt: LockedValue<CFAbsoluteTime>
    /// Asked for with Lens Blur on (the mode open): its image must not be shown once the mode
    /// has closed, nor the other way round.
    var lensBlur = false
}

/// State for the Develop view: the open photo's settings, its live proxy render, and saving.
///
/// Rendering is "latest wins": while one render runs, further slider changes collapse into a
/// single follow-up render, so dragging a slider never queues up stale frames. The render queue
/// starts that follow-up itself, and live frames go straight from the GPU to the photo view
/// (`PhotoFeed`); `image` is published when the edit rests.
@MainActor
final class DevelopController: ObservableObject {
    /// Long edge of the live proxy, per the PRD.
    nonisolated static let proxySize = 2560

    @Published private(set) var assetID: Int64?
    @Published private(set) var settings = DevelopSettings()
    @Published private(set) var image: NSImage? {
        didSet { if image !== oldValue, showsPreviousPhoto, oldValue != nil { showsPreviousPhoto = false } }
    }
    /// `image` is still the previous photo, held so the view never clears between photos.
    private(set) var showsPreviousPhoto = false
    /// `image` is the whole, uncropped photo (rendered for the crop tool) rather than the crop.
    @Published private(set) var imageIsWhole = false
    /// The editable proxy is still decoding. Edits made meanwhile apply once it's ready; this
    /// alone is no reason to show a spinner (`showsStandIn` is).
    @Published private(set) var isLoading = false
    /// `image` stands in for the photo without being it: a small grid thumbnail or the previous
    /// photo. The cached preview and every render are the photo itself. The spinner over the
    /// photo follows this, not the decode, which also runs while the photo is already on screen
    /// (Rosh, Nov 9, 2026).
    @Published private(set) var showsStandIn = false
    @Published private(set) var errorMessage: String?
    /// The open photo's original changed on its share since import (AT-079c part 3): the banner
    /// over the photo with Use the New File and Use the Kept Copy.
    @Published var originalChanged: OriginalChangedError?
    /// The open photo is being edited from its smart preview, its original being offline
    /// (AT-079d); the histogram says "Smart Preview".
    @Published private(set) var editsSmartPreview = false
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
        /// Lens Blur's focus picker: the click sets the Focal Range.
        case lensFocus

        var hint: String {
            switch self {
            case .whiteBalance: return "Click something that should be neutral gray or white. Esc to cancel."
            case .fringe: return "Click a purple or green fringe. Zoom in to see it clearly. Esc to cancel."
            case .gradeColor: return "Click a spot whose color cast should turn neutral. Esc to cancel."
            case .pointColor: return "Click the color you want to change. Esc to cancel."
            case .targetCurve: return "Drag up or down on a tone to lighten or darken it. Esc when done."
            case .targetColor: return "Drag up or down on a color to change it. Esc when done."
            case .targetGray: return "Drag up or down on a color to make its gray lighter or darker. Esc when done."
            case .lensFocus: return "Click the part of the photo to keep in focus. Esc to cancel."
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
            // A picker works on the plain photo: tools close, but Lens Blur stays open (its focus
            // picker is one of them), leaving only its Refine.
            if isLensBlurring { switchTool(to: .lensBlur(refining: false)) } else { switchTool(to: nil) }
            showingBefore = false
            compareMode = .off
        }
    }
    /// Why the last click with the picker that is out set nothing.
    @Published var pickerMessage: String?
    /// Why Lens Blur's Subject focus set nothing, for its panel.
    @Published var lensBlurMessage: String?
    /// The Lens Blur mode (AT-074, Photo > Lens Blur…): the photo with its Lens Blur, and Lens
    /// Blur's controls in place of Develop's panels. Lens Blur renders only here
    /// (`DevelopSession.rendersLensBlur`), so Develop's sliders never re-run it; Save makes the
    /// Lens Blur photo, a TIFF stacked on the original (`LensBlurPhoto`). Leaving it any way but
    /// Save cancels: the photo goes back to how it was when the mode opened, history included
    /// (Rosh, Nov 16, 2026: "I am cancelling that, right?"). Opening another photo leaves it.
    /// See DevelopController+LensBlurMode.
    var isLensBlurring: Bool {
        get { tool?.isLensBlur ?? false }
        set { setTool(.lensBlur(refining: false), open: newValue) }
    }
    /// Save is rendering the Lens Blur photo.
    @Published var lensBlurSaving = false
    /// Why the last Save failed, for the Lens Blur panel.
    @Published var lensBlurSaveError: String?
    /// The open photo's Lens Blur photo, if one was saved, and the settings it was saved from
    /// (nil when unknown), to tell whether it is out of date.
    @Published var lensBlurPhoto: (id: Int64, madeFrom: DevelopSettings?)?
    /// What is still working in the Lens Blur mode, for the line under its bar: the blur's
    /// render, the full-size render, the depth model or Fine Edges (Rosh, Nov 16, 2026: "at least
    /// I know it is slow due that"). Nil when nothing is, and always outside the mode.
    @Published private(set) var lensBlurWork: String?
    private var lensBlurWorkCheck: DispatchWorkItem?
    /// The settings the open photo's stored previews were last made from (`flushSave`).
    private var lastPreviewSettings: (assetID: Int64, settings: DevelopSettings)?
    /// The photo as it was shown when Lens Blur opened, unblurred, put back at once when it
    /// closes if nothing but Lens Blur changed (`lensBlurModeChanged`).
    private var lensBlurReturn: LensBlurReturn?
    /// The photo's settings and history when the mode opened, put back when it closes without
    /// Save (`keepLensBlurChanges` after a Save drops them).
    private var lensBlurEntry: (assetID: Int64, generation: Int, settings: DevelopSettings, history: DevelopHistory)?
    /// Tells the library window the mode opened or closed (it lays the window out for it).
    var onLensBlurModeChanged: ((Bool) -> Void)?

    /// The HSL channel the Targeted Adjustment Tool changes (HSL / Color's view, or the one
    /// chosen from its menu in the All view).
    @Published var targetChannel: DevelopSettings.HSLChannel = .saturation
    /// A Targeted Adjustment drag in progress; see DevelopController+ColorTools.
    var targetDrag: TargetDrag?
    /// The Point Color swatch (0...3) the panel shows and the eyedropper fills.
    @Published var pointColorSwatch = 0 {
        didSet { if pointColorSwatch != oldValue, visualizesPointRange { sliderPreview = .pointColorRange(pointColorSwatch) } }
    }
    /// Lens Blur's Visualize Depth: the depth in color instead of the photo.
    @Published var visualizesDepth = false {
        didSet {
            guard visualizesDepth != oldValue else { return }
            if visualizesDepth { visualizesPointRange = false }
            sliderPreview = visualizesDepth ? .visualizeDepth : nil
        }
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
        didSet {
            if compareMode == .off {
                beforeRequest.value = nil
            } else {
                // The view enters Compare at Fit. Drop the previous view's zoom report before
                // it can launch full-size work alongside the two foreground comparison renders.
                if oldValue == .off { wantsFullResolution = false }
                renderBeforeIfNeeded()
            }
        }
    }
    /// The photo without edits, rendered once per open photo for the compare views.
    @Published private(set) var beforeImage: NSImage?
    private struct BeforeRenderRequest {
        struct Key: Equatable {
            let generation: Int
            let settings: DevelopSettings
        }

        let key: Key
        let assetID: Int64
        let session: DevelopSession
        let queuedAt: CFAbsoluteTime
        let openedAt: CFAbsoluteTime
    }

    /// One queue slot reads the newest request when it starts. Requests for passed photos or
    /// older geometry can be replaced without putting another render on the serial queue.
    private let beforeRequest = LockedValue<BeforeRenderRequest?>(nil)
    private var beforeRenderScheduled = false
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

    /// The histogram and color scope, on an object of their own (D2): each new count updates
    /// only the views that draw them, not every view watching the controller.
    let measures = DevelopMeasures()
    var histogram: Histogram? { measures.histogram }
    /// Where the render's colors sit on the Color Grading wheels.
    var colorScope: ColorScope? { measures.colorScope }

    /// Lightroom's Option-drag view, while Option is held on a slider that has one.
    @Published var sliderPreview: SliderPreview? = nil {
        didSet { if sliderPreview != oldValue { scheduleRender() } }
    }

    /// The crop tool is open: the photo renders whole and turned, but not straightened, under the
    /// crop frame; the crop view turns it by the angle so straightening is instant.
    /// The tool open over the photo, if any (AT-076 D1). Changed only through `switchTool(to:)`.
    @Published private(set) var tool: DevelopTool?

    var isCropping: Bool {
        get { tool == .crop }
        set { setTool(.crop, open: newValue) }
    }

    /// Opens `kind`, or closes it if it is the one open (closing Lens Blur closes its Refine too).
    private func setTool(_ kind: DevelopTool, open: Bool) {
        if open {
            switchTool(to: kind)
        } else if tool?.root == kind.root {
            switchTool(to: nil)
        }
    }

    /// Moves from the open tool to `new`: what closing the old one and opening the new one take,
    /// in one place, so a new tool is one more case here rather than an edit to every other tool.
    func switchTool(to new: DevelopTool?) {
        let old = tool
        guard new != old else { return }
        tool = new
        // Closing.
        if old == .crop { showCropOfWholeImage() }
        if old?.masks == true, new?.masks != true {
            maskTool = nil
            if maskScope == .lensBlur {
                // Leaving Lens Blur's Refine: Masking opens on its own masks next time.
                maskScope = .look
                selectedMaskID = nil
                selectedComponentID = nil
            }
        }
        if old == .remove {
            selectedSpotID = nil
            visualizesSpots = false
        }
        if (old == .guidedUpright) != (new == .guidedUpright) { selectedGuide = nil }
        // The AI tool works on the plain photo, without the clipping overlay.
        if (old == .ai) != (new == .ai), showShadowClipping || showHighlightClipping { clippingOverlayChanged() }
        // Lens Blur opening or closing (closing puts the photo back as it was before Lens Blur,
        // so before another tool opens on it).
        if (old?.isLensBlur ?? false) != (new?.isLensBlur ?? false) { lensBlurModeChanged() }
        // Opening.
        if let new, new.root != old?.root || (new.masks && old?.masks != true) {
            picker = nil
            showingBefore = false
            // The crop tool keeps a compare view as it was.
            if new != .crop { compareMode = .off }
        }
        if new?.masks == true, old?.masks != true, selectedMaskID == nil { selectedMaskID = editedMasks.last?.id }
        let redraws: Set<DevelopTool> = [.crop, .masking, .guidedUpright, .lensBlur(refining: true)]
        if old.map(redraws.contains) == true || new.map(redraws.contains) == true { scheduleRender() }
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
    var isAIOpen: Bool {
        get { tool == .ai }
        set { setTool(.ai, open: newValue) }
    }

    /// The Masking tool is open: the photo shows under the mask pins and the Masks panel. Inside
    /// Lens Blur this is its Refine (`maskScope == .lensBlur`), and Lens Blur stays open.
    var isMasking: Bool {
        get { tool == .masking || tool == .lensBlur(refining: true) }
        set {
            if newValue {
                switchTool(to: isLensBlurring && maskScope == .lensBlur ? .lensBlur(refining: true) : .masking)
            } else if tool == .lensBlur(refining: true) {
                switchTool(to: .lensBlur(refining: false))
            } else if tool == .masking {
                switchTool(to: nil)
            }
        }
    }

    /// Guided Upright is open: the guides are drawn on the photo as edited, crop included.
    var isGuiding: Bool {
        get { tool == .guidedUpright }
        set { setTool(.guidedUpright, open: newValue) }
    }

    /// The Remove tool is open (Q, AT-066): Content-Aware, Heal and Clone spots are drawn and
    /// edited on the photo, and the Remove panel shows under the tool strip. See
    /// DevelopController+Spots.
    var isRemoving: Bool {
        get { tool == .remove }
        set { setTool(.remove, open: newValue) }
    }

    /// The spot selected on the photo (its outlines drawn solid; Delete removes it).
    @Published var selectedSpotID: UUID?
    /// Generative AI (AT-066 step 4): new Content-Aware spots are filled by the Remove Object
    /// recipe in ComfyUI. See DevelopController+SpotGeneration.
    @Published var spotGenerative = UserDefaults.standard.bool(forKey: "spots.generative") {
        didSet { UserDefaults.standard.set(spotGenerative, forKey: "spots.generative") }
    }
    /// Spots whose fill ComfyUI is making, with what it is doing.
    @Published var spotGenerations: [UUID: AIProgress] = [:]
    /// Why the last generated fill failed, for the Remove panel.
    @Published var spotGenerationError: String?
    var spotGenerationTasks: [UUID: Task<Void, Never>] = [:]
    /// What the next click or stroke makes, remembered like Lightroom's.
    @Published var spotMode = DevelopSettings.Spot.Mode(
        rawValue: UserDefaults.standard.string(forKey: "spots.mode") ?? "") ?? .contentAware {
        didSet { UserDefaults.standard.set(spotMode.rawValue, forKey: "spots.mode") }
    }
    /// The brush for new spots: Size is a fraction of the photo's long edge.
    @Published var spotSize = UserDefaults.standard.object(forKey: "spots.size") as? Double
        ?? DevelopSettings.Spot.defaultSize {
        didSet { UserDefaults.standard.set(spotSize, forKey: "spots.size") }
    }
    @Published var spotFeather = UserDefaults.standard.object(forKey: "spots.feather") as? Double
        ?? DevelopSettings.Spot.defaultFeather {
        didSet { UserDefaults.standard.set(spotFeather, forKey: "spots.feather") }
    }
    @Published var spotOpacity = UserDefaults.standard.object(forKey: "spots.opacity") as? Double ?? 100 {
        didSet { UserDefaults.standard.set(spotOpacity, forKey: "spots.opacity") }
    }
    /// The spots' outlines on the photo while the tool is open (Lightroom's Tool Overlay).
    @Published var showsSpotOverlay = UserDefaults.standard.object(forKey: "spots.showOverlay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSpotOverlay, forKey: "spots.showOverlay") }
    }
    /// Visualize Spots (A): white with the photo's edges in black, so dust stands out.
    @Published var visualizesSpots = false {
        didSet {
            guard visualizesSpots != oldValue else { return }
            sliderPreview = visualizesSpots ? .visualizeSpots(spotVisualizeAmount) : nil
        }
    }
    /// Visualize Spots' slider (0...100): higher shows fainter edges.
    @Published var spotVisualizeAmount = UserDefaults.standard.object(forKey: "spots.visualize") as? Double ?? 50 {
        didSet {
            UserDefaults.standard.set(spotVisualizeAmount, forKey: "spots.visualize")
            if visualizesSpots { sliderPreview = .visualizeSpots(spotVisualizeAmount) }
        }
    }
    /// The photo's brightness for picking spot sources, from the proxy it was read from.
    var spotBrightness: (image: ObjectIdentifier, map: BrightnessMap)?

    /// Replaces the open photo's spots as one history step named `step` (a drag that keeps
    /// the same name stays one step).
    func setSpots(_ spots: [DevelopSettings.Spot], step: String) {
        guard assetID != nil, spots != settings.spots else { return }
        settings.spots = spots
        changed(step: step)
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
    /// Which masks the mask tools edit: Masking's, or Lens Blur's Focus and Blur areas (Lens
    /// Blur's Refine mode, which is Masking's tools on those areas).
    @Published var maskScope: MaskScope = .look
    /// Tints the selected mask red on the photo (O).
    @Published var showMaskOverlay = UserDefaults.standard.bool(forKey: "masks.showOverlay") {
        didSet {
            UserDefaults.standard.set(showMaskOverlay, forKey: "masks.showOverlay")
            DevelopTimingLog.shared.log(assetID, "Show Overlay \(showMaskOverlay ? "on" : "off") "
                + "(full-size render \(fullRendering ? "running" : "idle"), render \(rendering ? "running" : "idle"))")
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
    /// The faces Select People finds on this photo, left to right (0 to 1 from the top left of the
    /// upright, uncropped photo); nil until it has looked.
    @Published var peopleFaces: [CGRect]?
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
                fullRelease?.cancel()
                fullRelease = nil
                scheduleFullRender()
                scheduleFullBeforeRender()
            } else if !wantsFullResolution, oldValue {
                endAwaitingSharp(because: "back to Fit")
                scheduleFullRelease()
            }
        }
    }
    /// Zoomed in, a newly opened photo is shown only once it is sharp: until its full-size image
    /// is in, the photo view keeps the last photo instead of the stretched preview and proxy
    /// (Rosh, Nov 21, 2026: "when I click on a new image, it is drawing low resolution then
    /// drawing the high resolution which is very annoying to watch"). The Filmstrip, Navigator and
    /// panels move to the new photo at once. Ends after `sharpOpenLimit` whatever happens.
    @Published private(set) var awaitingSharp = false
    private var sharpOpenTimeout: DispatchWorkItem?
    /// The longest a zoomed open waits for its full-size image (a heavy edit took 325 ms).
    static let sharpOpenLimit: TimeInterval = 1.0
    private var sharpOpenBegan: CFAbsoluteTime = 0
    /// Lets go of the full-size images a moment after the view goes back to Fit (AT-077).
    private var fullRelease: DispatchWorkItem?
    @Published private(set) var fullImage: NSImage?
    private var fullImageSettings: DevelopSettings?
    /// Something the full-size image was made without has arrived in the background
    /// (`backgroundWorkArrived`): render it again, though the settings are the same.
    private var fullImageIsStale = false
    private(set) var fullSession: DevelopSession?
    private var sourceURL: URL?
    private var fullRendering = false
    private var fullNeedsRender = false
    let fullQueue = DispatchQueue(label: "atelier.develop.full", qos: .userInitiated)
    /// Zoomed detail frames (`DevelopController+ZoomedDetail.swift`): latest wins, on `fullQueue`.
    let detailJob = LatestJob<ZoomedDetailRequest>()
    /// At most three screens' worth of surfaces, let go whenever no detail frame shows.
    let detailSurfaces = DisplaySurfaces(limit: 3)
    var detailCount = 0
    /// Detail frames came too slowly for this drag (an Exposure drag re-decoding the RAW): the
    /// proxy draws it alone, as before, until the edit rests.
    var detailGaveUp = false
    /// This drag's detail frames, for the limit and the timing log line when it rests.
    let detailStats = LockedValue(ZoomedDetailStats())
    /// Why the last live render asked for no detail frame, logged when it changes.
    var detailSkipReason: String?

    /// The sharpest image that matches the current settings.
    var displayImage: NSImage? {
        if isCropping || (isMasking && showMaskOverlay) || sliderPreview != nil { return image }
        if !showingBefore, let fullImage, fullImageSettings == settings { return fullImage }
        // Zoomed in during a drag the sharp detail frame shows the edit over the visible part;
        // the full-size image stays under it, a step behind but sharp, instead of the stretched
        // proxy flashing up each time a drag starts. The next full-size render replaces it.
        if !showingBefore, let fullImage, fullImageSettings != nil, usesZoomedDetail { return fullImage }
        return image
    }

    /// The open photo's history and snapshots. `committed` is the settings of the newest step,
    /// and `pendingStep` names the change waiting to become a step when the edit settles.
    @Published private(set) var history = DevelopHistory()
    private var committed = DevelopSettings()
    private var pendingStep: String?
    private var pointerEditInProgress = false
    private let isPrimaryButtonPressed: () -> Bool

    /// Built-in and user presets, shared across catalogs.
    @Published private(set) var presets: [DevelopPreset] = []
    private let presetStore = PresetStore(fileURL: PresetStore.defaultURL)
    /// The user's own Tone Curve and Color Grading presets, listed in those panels' Preset menus
    /// (`DevelopController+SectionPresets.swift`).
    @Published var userSectionPresets: [SectionPresetKind: [DevelopPreset]] = Dictionary(
        uniqueKeysWithValues: SectionPresetKind.allCases.map { ($0, PresetStore(section: $0).userPresets()) })
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

    let catalog: Catalog
    private let previews: PreviewCache
    /// Makes an original on a network share or in a cloud drive folder ready on this Mac before it
    /// decodes (AT-079b, AT-079c), with the status bar's progress and Cancel; set by `LibraryModel`.
    var prepareOriginal: (@MainActor (Int64) async -> OriginalPrep)?
    /// Reads the neighbours' originals on a share into the cache, behind the open photo.
    var prefetchOriginals: (@MainActor ([Int64]) -> Void)?
    /// Copies of remote originals on this Mac (AT-079c); readers prefer a checked copy.
    var originals: OriginalCache?
    /// The catalog's smart previews (AT-079d), edited from when an original is offline.
    var smartPreviews: SmartPreviewStore?
    /// Whether a photo's original needs that first (`url` is its original, nil while offline).
    var needsPreparing: (@MainActor (Int64, URL?) -> Bool)?
    private var session: DevelopSession?
    private var rendering = false
    /// Proxy renders, latest-wins; see `submitRender`.
    private let renderJob = LatestJob<ProxyRenderRequest>()
    /// The last request handed to the render queue, for the settled image (`publishWhenSettled`).
    private var lastRender: ProxyRenderRequest?
    /// What the last render asked for, so the crop tool skips renders that would draw the same.
    private var lastRenderKey: ProxyRenderKey?
    private var settleItem: DispatchWorkItem?
    /// How long an edit rests before its last live frame is published as `image`.
    private static let settleDelay: TimeInterval = 0.12
    /// Gives the photo view its live frames straight from the GPU; see `PhotoFeed`.
    let frameHUD = DevelopFrameHUD()
    lazy var photoFeed = PhotoFeed { [weak frameHUD] timing in frameHUD?.submit(timing) }
    private let displaySurfaces = DisplaySurfaces()
    /// What live frames were last requested for; a change drops frames still rendering.
    private var lastLiveKey: LiveFrameKey?
    /// A live frame didn't fit the photo on screen; frames take the ordinary path until the
    /// pointer edit ends or another photo opens.
    private var liveFramesOff = false
    /// For the timing log: when the running render started, and whether a long one, or an edit
    /// made before the editable copy was ready, has been logged.
    private let renderBeganAt = LockedValue(DevelopTimingLog.now())
    private var renderHangLogged = false
    private var editBeforeProxyLogged = false
    private var saveTask: Task<Void, Never>?
    /// A photo whose edits were saved before its editable copy was ready, so its Grid and Loupe
    /// previews still need refreshing.
    private var previewsOwed: Int64?
    private var dirty = false
    private let queue = DispatchQueue(label: "atelier.develop", qos: .userInteractive)
    /// Histogram and color scope, counted beside the render queue so the photo shows first.
    private let measureQueue = DispatchQueue(label: "atelier.develop.measure", qos: .userInitiated)
    /// Only the newest render waits to be measured. Counting takes longer than a render, so
    /// queueing one per render built a backlog that left the histogram spinning for seconds
    /// after moving through photos or dragging (Rosh, Nov 9, 2026).
    private let measureJob = LatestJob<DevelopMeasureRequest>()
    /// Puts the histogram's graph on screen from the measure queue (AT-040).
    let histogramSink = HistogramSink()
    /// Counts waiting to be published to SwiftUI, at most every `measurePublishInterval`.
    private var pendingMeasure: (histogram: Histogram?, scope: ColorScope?)?
    private var measurePublishedAt: CFTimeInterval = 0
    private var measurePublishScheduled = false
    /// Decodes for opening photos. Every photo passed with ← → used to queue its decode (and,
    /// for an unedited RAW, a preview render) on the render queue, so after moving quickly the
    /// photo, panels and histogram waited for every photo passed (Rosh, Nov 9, 2026). Now a
    /// decode starts only once ← → rest (`openRest`), and runs beside one still finishing.
    private static let openQueue = DispatchQueue(label: "atelier.develop.open", qos: .userInitiated,
                                                 attributes: .concurrent)
    /// How long ← → must rest before the photo is decoded, when they come faster than this.
    private static let openRest: TimeInterval = 0.15
    private var lastOpen = Date.distantPast
    /// The photos either side of the open one in the Filmstrip (set by `LibraryModel`), and
    /// their proxies, decoded and rendered once in the background after the open photo's first
    /// render, so ← or → to one of them opens at once instead of decoding the RAW again.
    /// Lightroom does the same for neighbouring photos.
    var neighbours: [Int64] = [] {
        didSet { if neighbours != oldValue, firstRenderDone { prefetchNeighboursWhenIdle() } }
    }
    private var prefetched: [Int64: DevelopSession] = [:]
    /// Counts changes to each photo's original (`sourceChanged`), so a preload that read the
    /// old file is dropped.
    private var sourceVersions: [Int64: Int] = [:]
    private var prefetching: Set<Int64> = []
    private var firstRenderDone = false
    private static let prefetchQueue = DispatchQueue(label: "atelier.develop.prefetch", qos: .utility)
    /// How long the photo must go without a render (an edit, a drag) before its neighbours are
    /// decoded, so they never share the CPU and GPU with your edits.
    nonisolated private static let prefetchDelay: TimeInterval = 0.8
    /// When a render was last asked for, readable from the preload queue.
    private let lastRenderRequest = LockedValue(Date.distantPast)
    /// For the timing log (`DevelopTimingLog`): when the open photo was opened, how many RAW
    /// decodes are running now, and whether its first histogram has been logged.
    private var openedAt = DevelopTimingLog.now()
    private let decodesRunning = LockedValue(0)
    private var histogramLogged = false
    /// The open photo, readable off the main thread so queued work for a photo already left is
    /// skipped.
    private let openAsset = LockedValue<Int64?>(nil)
    /// Counts opens, so a decode started by an earlier open of the same photo (A, B, then A
    /// again, or `reopen()` after Edit In) can't replace this open's session or set an error.
    private let openGeneration = LockedValue(0)
    /// Counts proxy renders, so an older histogram never replaces a newer one.
    private var renderCount = 0
    /// Renders that ran, and how long they took: the open photo's proxy renders, and other
    /// photos' preview refreshes (`refreshPreviews`). The agent render check reads them
    /// (AgentEditRenderTests, AT-050d).
    let proxyRenders = LockedValue(RenderTally())
    let refreshRenders = LockedValue(RenderTally())
    /// A proxy render is running or waiting to.
    var isRenderingProxy: Bool { rendering }
    /// The rank (`DevelopMeasureRequest.rank`) of what the shown histogram was counted from.
    private var measuredRank = 0
    var onPreviewsUpdated: ((Int64) -> Void)?
    var onSettingsSaved: ((Int64) -> Void)?
    /// Unedited RAW files whose preview was replaced by a render this launch.
    private var developedPreviews = Set<Int64>()

    init(catalog: Catalog, previews: PreviewCache,
         isPrimaryButtonPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        self.catalog = catalog
        self.previews = previews
        self.isPrimaryButtonPressed = isPrimaryButtonPressed
        presets = presetStore.all()
        // Fine Edges finds its matte in the background; render again once it is in. So does
        // Depth Range's depth map (until then the mask is empty).
        for name in [FineEdges.matteReady, DepthMap.ready] {
            observers.observe(name) { [weak self] _ in MainActor.assumeIsolated { self?.backgroundWorkArrived() } }
        }
        // Lens Blur's progress line follows the models starting and stopping.
        for name in [DepthMap.workingChanged, FineEdges.statusChanged] {
            observers.observe(name) { [weak self] _ in MainActor.assumeIsolated { self?.noteLensBlurWork() } }
        }
        // So does Content-Aware Remove's fill (until then the spot shows Heal), and AI Denoise's
        // noise picture (until then the photo shows Apple's noise reduction).
        for name in [ContentAwareFill.fillReady, AIDenoise.ready] {
            observers.observe(name) { [weak self] _ in MainActor.assumeIsolated { self?.renderFreshResult() } }
        }
        observers.observe(AIDenoise.statusChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiDenoiseStatusChanges += 1 }
        }
        // macOS says memory is low: Core Image's cache is already cleared (`RenderMemory`); let go
        // of the full-size images too unless the photo is zoomed in (AT-077).
        observers.observe(RenderMemory.pressure) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseFullResolution(because: "memory pressure") }
        }
    }

    /// Removed with the controller (AT-076 M4).
    private let observers = NotificationObservers()
    /// Counts AI Denoise's status changes, so the Detail panel shows the new one.
    @Published private var aiDenoiseStatusChanges = 0

    /// The line under Detail > AI Denoise: working, done or why it didn't run; nil for none.
    var aiDenoiseStatus: String? {
        _ = aiDenoiseStatusChanges
        return AIDenoise.statusText(for: session?.url, isRAW: isRAW, amount: settings[.aiDenoise])
    }

    /// AI Denoise is finding the open photo's noise.
    var isAIDenoising: Bool {
        _ = aiDenoiseStatusChanges
        guard let url = session?.url, settings[.aiDenoise] > 0 else { return false }
        return AIDenoise.status(for: url) == .working
    }

    // MARK: Opening

    /// A photo's original changed on disk (Edit In saved, an HDR came back): its kept or
    /// preloading proxy shows the old file, so drop it, and open it again if it is the open one.
    func sourceChanged(_ id: Int64) {
        prefetched[id] = nil
        sourceVersions[id, default: 0] += 1
        if assetID == id { reopen() }
    }

    /// Opens the current photo again, after its file changed on disk.
    func reopen() {
        let id = assetID
        open(nil)
        prefetched.removeAll()
        open(id)
    }

    /// The original of a photo being edited from its smart preview is back (its drive or share
    /// reconnected): open it again from the original, at full quality, with the edits as they are.
    /// Nothing happens while it is still offline. Called when volumes are refreshed (AT-079d).
    func reopenFromOriginalIfBack() {
        guard editsSmartPreview, let id = assetID,
              (try? catalog.readableURL(for: id, cache: originals)) != nil else { return }
        reopen()
    }

    /// `zoomedIn`: the photo view will show it past Fit (`LibraryModel.nextPhotoIsZoomedIn`), so it
    /// is shown only once its full-size image is in (`awaitingSharp`).
    func open(_ assetID: Int64?, zoomedIn: Bool = false) {
        guard assetID != self.assetID else { return }
        // The mode is for one photo: another photo cancels it, on the photo it was open on.
        if isLensBlurring { isLensBlurring = false }
        beforeRequest.value = nil
        flushSave()
        if let owed = previewsOwed, owed == self.assetID {
            // Its copy never got ready: render the saved look from its own decode.
            previewsOwed = nil
            refreshPreviews(for: owed, settings: settings)
        }
        // Kept for going straight back (← then →); dropped once it's no longer a neighbour.
        if let previous = self.assetID, let session { prefetched[previous] = session }
        self.assetID = assetID
        // A virtual copy uses its master's copy, so that one is spared.
        originals?.inUse = assetID.map { id in (try? catalog.originalID(for: id)) ?? id }
        openAsset.value = assetID
        openGeneration.value += 1
        histogramSink.reset(generation: openGeneration.value)
        let generation = openGeneration.value
        firstRenderDone = false
        liveFramesOff = false
        settleItem?.cancel()
        // Until the first render shows the photo, or opening fails.
        isLoading = false
        session = nil
        // Kept on screen until the next photo has an image (AT-019), never used as this photo's.
        let previousImage = image
        image = nil
        showsPreviousPhoto = false
        imageIsWhole = false
        beforeImage = nil
        // Ranks only compare within one open (requests carry the open's generation).
        measuredRank = 0
        measures.histogram = nil
        pendingMeasure = nil
        shootingInfo = nil
        measures.colorScope = nil
        fullImage = nil
        fullImageSettings = nil
        fullImageIsStale = false
        fullBeforeImage = nil
        fullBeforeSettings = nil
        let heldFullSize = fullSession != nil
        fullSession = nil
        fullRelease?.cancel()
        fullRelease = nil
        // The last photo's full-size stages in Core Image's cache (step 1, Lens Blur, depth) are
        // of no use now (AT-077). Only after a full-size session: stepping through photos at Fit
        // keeps the neighbours' cached step 1, and the budget bounds those anyway.
        if heldFullSize { RenderMemory.shared.releaseAllSoon(because: "another photo opened") }
        sourceURL = nil
        errorMessage = nil
        originalChanged = nil
        editsSmartPreview = false
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
        selectedSpotID = nil
        spotBrightness = nil
        spotGenerationError = nil
        peopleFaces = nil
        presetAmount = nil
        previewingPreset = nil
        navigatorPreview = nil
        navigatorSession = nil
        lensBlurPhoto = nil
        lensBlurSaveError = nil
        endAwaitingSharp(because: nil)
        guard let assetID else { return }
        // Zoomed in on the next photo though the last one was at Fit ("Return to its last zoom").
        if zoomedIn, !wantsFullResolution { wantsFullResolution = true }
        if wantsFullResolution, compareMode == .off, !isMasking, !isRemoving, !isLensBlurring {
            awaitingSharp = true
            sharpOpenBegan = DevelopTimingLog.now()
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.endAwaitingSharp(because: "timed out") }
            }
            sharpOpenTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharpOpenLimit, execute: timeout)
        }

        settings = (try? catalog.developSettings(for: assetID)) ?? .neutral
        if isMasking { selectedMaskID = editedMasks.last?.id }
        if isLensBlurring { loadLensBlurPhoto() }
        history = (try? catalog.developHistory(for: assetID)) ?? DevelopHistory()
        committed = settings
        pendingStep = nil
        // Show the cached preview immediately while the editable proxy decodes: decoded in
        // memory when it was shown or prefetched lately, else the grid thumbnail (also when there
        // is no preview yet), else the previous photo, until the preview is decoded off the main
        // thread or the proxy renders.
        let cachedPreview = previews.url(for: assetID, size: .preview)
        let hasPreview = previews.has(.preview, for: assetID)
        let url = try? catalog.readableURL(for: assetID, cache: originals)
        if hasPreview, let decoded = PreviewImages.shared.cached(assetID, at: cachedPreview) {
            image = decoded
            showsStandIn = false
        } else {
            var placeholder = ThumbnailLoader.shared.cached(assetID)
            // Only while something is coming to replace it.
            if placeholder == nil, hasPreview || url != nil, !isMasking, let previousImage {
                placeholder = previousImage
                showsPreviousPhoto = true
            }
            image = placeholder
            showsStandIn = placeholder != nil
            if hasPreview {
                Task {
                    let decoded = await PreviewImages.shared.load(assetID, at: cachedPreview)
                    // Not once the proxy has rendered, or for another photo.
                    guard self.assetID == assetID, self.image === placeholder, let decoded else { return }
                    self.image = decoded
                    self.showsStandIn = false
                    if self.histogram == nil { self.measurePreview(decoded, of: assetID) }
                }
            }
        }
        measurePreview(image, of: assetID)

        // On a network share or still in a cloud drive folder (AT-079b, AT-079c): the original is
        // made ready on this Mac first (its checked copy, read once into the cache, or downloaded by
        // the provider) while the preview stays up and browsable; a local original opens at once.
        // Reading it straight off the network would hold the decode queue for the whole transfer.
        if let prepareOriginal, needsPreparing?(assetID, url) == true {
            isLoading = true
            let openGeneration = self.openGeneration
            let now = Date()
            let rushing = now.timeIntervalSince(lastOpen) < Self.openRest
            lastOpen = now
            Task { @MainActor [weak self] in
                // Passing photos with ← → reads none of them; the one you stop on is read.
                if rushing { try? await Task.sleep(for: .seconds(Self.openRest)) }
                guard openGeneration.value == generation else { return }
                let prep = await prepareOriginal(assetID)
                guard let self, self.assetID == assetID, openGeneration.value == generation else { return }
                switch prep {
                case .ready(let ready):
                    self.decodeOpened(assetID, url: ready, generation: generation, afterPreparing: true)
                case .offline:
                    if let smart = self.smartPreviewURL(assetID) {
                        self.editsSmartPreview = true
                        self.decodeOpened(assetID, url: smart, generation: generation, afterPreparing: true)
                    } else {
                        self.isLoading = false
                        self.errorMessage = "The original is offline. Connect its drive to edit this photo."
                    }
                case .cancelled:
                    self.isLoading = false
                    self.errorMessage = "The original isn't on this Mac yet. Open the photo again to get it."
                case .failed(let message):
                    self.isLoading = false
                    self.errorMessage = message
                case .changed(let change):
                    self.isLoading = false
                    self.originalChanged = change
                }
            }
            return
        }
        guard let url else {
            if let smart = smartPreviewURL(assetID) {
                editsSmartPreview = true
                decodeOpened(assetID, url: smart, generation: generation, afterPreparing: false)
            } else {
                errorMessage = "The original is offline. Connect its drive to edit this photo."
            }
            return
        }
        decodeOpened(assetID, url: url, generation: generation, afterPreparing: false)
    }

    /// Decodes the open photo's proxy from `url`, its original or the copy on this Mac.
    /// The photo's smart preview, when it has one (virtual copies share their master's).
    func smartPreviewURL(_ assetID: Int64) -> URL? {
        guard let smartPreviews else { return nil }
        let fileID = (try? catalog.originalID(for: assetID)) ?? assetID
        return smartPreviews.has(fileID) ? smartPreviews.url(for: fileID) : nil
    }

    private func decodeOpened(_ assetID: Int64, url: URL, generation: Int, afterPreparing: Bool) {
        sourceURL = url
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let info = ShootingInfo(url: url)
            await MainActor.run {
                if self.assetID == assetID { self.shootingInfo = info }
            }
        }
        // While ← → are pressed in quick succession the cached preview shows and nothing is
        // decoded; the photo you stop on starts decoding once you rest. A single move starts at once.
        let now = Date()
        let rushing = !afterPreparing && now.timeIntervalSince(lastOpen) < Self.openRest
        lastOpen = now
        openedAt = DevelopTimingLog.now()
        histogramLogged = false
        editBeforeProxyLogged = false
        let preloaded = prefetched[assetID] != nil
        DevelopTimingLog.shared.log(assetID, describing: url, "open ", (preloaded ? ", proxy preloaded" : rushing ? ", arrows still moving: decode waits for a rest" : "")
            + ". Busy: \(decodesRunning.value) RAW decodes, render \(rendering ? "running" : "idle"), "
            + "full-size render \(fullRendering ? "running" : "idle"), preloading \(prefetching.count)")
        // A neighbour decoded while you looked at the last photo: no wait at all.
        if let session = prefetched.removeValue(forKey: assetID) {
            finishOpen(assetID, generation: generation, session: session)
            return
        }
        let openGeneration = self.openGeneration
        let decodesRunning = self.decodesRunning
        let openedAt = self.openedAt
        let start = {
            // Left (or opened again) before it started: don't decode it for this open.
            guard openGeneration.value == generation else { return }
            // Zoomed in, the full-size photo decodes beside the proxy rather than after its first
            // render, so the photo is sharp as soon as it can be.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if openGeneration.value == generation, self.wantsFullResolution { self.scheduleFullRender() }
                }
            }
            // Its own queue, beside any decode still running for a photo already left, so the
            // photo you stopped on never waits for one you passed.
            Self.openQueue.async {
                guard openGeneration.value == generation else {
                    DevelopTimingLog.shared.log(assetID, "decode skipped: moved on")
                    return
                }
                let began = DevelopTimingLog.now()
                let others = decodesRunning.value
                decodesRunning.value += 1
                DevelopRenderer.shared.cameraMatch(for: url)
                let matched = DevelopTimingLog.now()
                let session = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.proxySize, interactive: true)
                decodesRunning.value -= 1
                DevelopTimingLog.shared.log(assetID, "decode began +\(Int(((began - openedAt) * 1000).rounded())) ms "
                    + "(beside \(others) other decodes): camera match \(Int(((matched - began) * 1000).rounded())) ms, "
                    + "proxy open \(DevelopTimingLog.ms(since: matched)) ms" + (session == nil ? ", FAILED" : ""))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finishOpen(assetID, generation: generation, session: session) }
                }
            }
        }
        if rushing {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openRest, execute: start)
        } else {
            start()
        }
    }

    /// Puts a decoded proxy to work, if its photo is still the open one.
    private func finishOpen(_ assetID: Int64, generation: Int, session: DevelopSession?) {
        guard self.assetID == assetID, openGeneration.value == generation else {
            if self.assetID == assetID {
                DevelopTimingLog.shared.log(assetID, "decode from an earlier open of this photo dropped")
            }
            return
        }
        DevelopTimingLog.shared.log(assetID, "proxy ready +\(DevelopTimingLog.ms(since: openedAt)) ms")
        guard let session else {
            self.isLoading = false
            if self.showsPreviousPhoto { self.image = nil }
            self.errorMessage = "This file can't be opened for editing."
            return
        }
        self.session = session
        session.rendersLensBlur = isLensBlurring
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
        if self.compareMode != .off { self.renderBeforeIfNeeded() }
        warmUp(session: session, assetID: assetID, generation: generation)
        // An unedited RAW's cached preview is the camera's embedded JPEG, which has no
        // lens corrections, so it is framed a little wider than the render and the
        // photo jumped when the render replaced it. Store the render as the preview
        // (once per photo per launch) so the next visit opens on the same framing.
        if previewsOwed == assetID {
            previewsOwed = nil
            self.storePreviews(session: session, settings: self.settings, assetID: assetID)
        } else if session.isRAW, session.lensCorrectionSupported, self.settings.isNeutral,
           self.developedPreviews.insert(assetID).inserted {
            self.storePreviews(session: session, settings: self.settings, assetID: assetID, optional: true)
        }
    }

    /// Builds Core Image's programs for the tools this photo doesn't use yet, so the first drag
    /// of one doesn't hold its first frame while they compile (`DevelopRenderer.warmUp`, AT-039
    /// D3a). Background priority, on its own queue beside the live renders; stops when another
    /// photo opens.
    private func warmUp(session: DevelopSession, assetID: Int64, generation: Int) {
        let settings = settings, scale = session.renderScale, openGeneration = openGeneration
        Self.warmUpQueue.async {
            guard openGeneration.value == generation else { return }
            let began = DevelopTimingLog.now()
            let count = DevelopRenderer.shared.warmUp(settings, scale: scale) { openGeneration.value == generation }
            DevelopTimingLog.shared.log(assetID, "warm-up: \(count) pipelines in \(DevelopTimingLog.ms(since: began)) ms")
        }
    }

    private static let warmUpQueue = DispatchQueue(label: "atelier.develop.warm-up", qos: .utility)

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
        if (parameter.panel == .lensCorrections && !parameter.isDefringe) || parameter.panel == .transform, beforeImage != nil { beforeImage = nil }
        let shown = parameter == .tint ? asShotTint + settings[parameter] : settings[parameter]
        changed(step: Self.stepName(parameter, value: shown))
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

    func copyGradeWheel(_ values: GradeWheelValues) {
        copiedGradeWheel = values
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
    /// Whose wheel it is: the photo's Color Grading panel or a mask's.
    var hoveredGradeTarget: GradeTarget = .photo

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
        case .lensBlur:
            settings.lensBlurAreas = []
            finishLensBlurRefine()
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
        case .lensBlur where !settings.lensBlurAreas.isEmpty: return true
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
    }

    /// The photo without edits but with the same shape (lens corrections, Transform and crop),
    /// so before and after line up.
    private var beforeSettings: DevelopSettings {
        // In the Lens Blur mode, Before is the photo without its Lens Blur.
        if isLensBlurring {
            var before = settings
            before[.lensBlurApply] = 0
            return before
        }
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
    /// As in Lightroom, Spot Removal isn't pasted: each photo keeps its own Remove tool spots.
    func pasteSettings(onto assetIDs: [Int64]? = nil) {
        guard let clipboard else { return }
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        do {
            let current = try currentSettings(for: targets)
            var each: [Int64: DevelopSettings] = [:]
            for id in targets {
                var pasted = clipboard
                pasted.spots = current[id]?.spots ?? []
                each[id] = pasted
            }
            try apply(each: each, step: "Paste Settings")
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Clears all edits on the photos (Lightroom's Reset).
    func resetSettings(of assetIDs: [Int64]) {
        apply(.neutral, onto: assetIDs, step: "Reset All")
    }

    func apply(_ newSettings: DevelopSettings, onto assetIDs: [Int64]?, step: String) {
        let targets = assetIDs ?? assetID.map { [$0] } ?? []
        saveToOthers(targets, step: step) { _, _ in newSettings }
        if let assetID, targets.contains(assetID) {
            settings = newSettings
            validateMaskSelection()
            changed(step: step, replacing: true)
        }
    }

    /// Changes the saved settings of the photos in `ids` other than the open one, in one catalog
    /// transaction (AT-076 P2): all of them or, if one fails, none, with "Could not save".
    private func saveToOthers(_ ids: [Int64], step: String,
                              _ change: (Int64, DevelopSettings) throws -> DevelopSettings?) {
        do {
            try saveToOthersOrThrow(ids, step: step, change)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    private func saveToOthersOrThrow(_ ids: [Int64], step: String,
                                     _ change: (Int64, DevelopSettings) throws -> DevelopSettings?) throws {
        let others = ids.filter { $0 != assetID }
        guard !others.isEmpty else { return }
        let saved = try catalog.updateDevelop(others, step: step, change)
        for id in others {
            guard let settings = saved[id] else { continue }
            onSettingsSaved?(id)
            refreshPreviews(for: id, settings: settings)
        }
    }

    /// Each photo's own new settings as one history step named `step` (agents, AT-050d). The
    /// open photo's change in progress becomes its own step first, so this step never swallows it.
    func apply(each newSettings: [Int64: DevelopSettings], step: String) throws {
        if staged != nil {
            // An atomic agent batch: held until the batch ends (`commitStaged`).
            staged?.merge(newSettings) { $1 }
            return
        }
        if let assetID, newSettings[assetID] != nil { flushSave() }
        try saveToOthersOrThrow(newSettings.keys.sorted(), step: step) { id, _ in newSettings[id] }
        if let assetID, let open = newSettings[assetID] {
            settings = open
            validateMaskSelection()
            beforeImage = nil
            changed(step: step, replacing: true)
            flushSave()
        }
    }

    /// Settings as they stand: the open photo's as on screen (an edit in progress included),
    /// the others' as saved.
    func currentSettings(for ids: [Int64]) throws -> [Int64: DevelopSettings] {
        var result: [Int64: DevelopSettings] = [:]
        for id in ids {
            if let held = staged?[id] { result[id] = held; continue }
            result[id] = id == assetID ? settings : try catalog.developSettings(for: id)
        }
        return result
    }

    /// An atomic agent batch (AT-050j) holds its Develop changes here, so they land as one
    /// history step per photo if every step succeeds, and leave nothing if one fails.
    private var staged: [Int64: DevelopSettings]?

    func beginStaging() { staged = [:] }

    /// Applies what the batch held, as one step named `step`.
    func commitStaged(step: String) throws {
        guard let held = staged else { return }
        staged = nil
        if !held.isEmpty { try apply(each: held, step: step) }
    }

    func discardStaged() { staged = nil }

    /// The person is dragging a slider, handle or the photo: agent edits wait for it to end.
    var isEditingByHand: Bool { pointerEditInProgress || targetDrag != nil }

    /// An edit to the open photo. `step` names it in the history; nil (undo, redo, jumping
    /// in the history) saves without adding a step. `replacing` is for whole settings put in
    /// place (a preset, a snapshot, Paste), whose panel switches stand as they come.
    private func changed(step: String?, replacing: Bool = false) {
        if step != nil, !replacing { turnOnEditedPanels() }
        // Only when it changes: assigning a published property updates every watching view.
        if !settingPresetAmount, presetAmount != nil { presetAmount = nil }
        constrainCropIfNeeded()
        dirty = true
        if let step { pendingStep = step }
        scheduleRender()
        if beforeImage == nil, compareMode != .off { renderBeforeIfNeeded() }
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
        // Each photo's preset goes on top of its own saved settings, read in the same transaction
        // (a photo whose settings can't be read is never given the preset on neutral).
        saveToOthers(targets, step: step) { _, base in preset.applied(to: base) }
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
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: Self.navigatorSize, interactive: true)
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

    /// Shows `message` in the Develop error banner (for the controller's extensions).
    func reportError(_ message: String) {
        errorMessage = message
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

    static func parameterName(_ parameter: DevelopSettings.Parameter) -> String {
        if let pair = parameter.hslBand { return "\(pair.0.rawValue) \(pair.1.rawValue)" }
        if let point = parameter.pointColor { return "Point Color \(point.swatch + 1) \(point.setting.label)" }
        if let band = parameter.grayBand { return "B&W \(band.rawValue)" }
        switch parameter.panel {
        case .colorGrading, .detail, .effects, .toneCurve, .lensCorrections, .calibration:
            return "\(parameter.group) \(parameter.label)"
        case .lensBlur:
            switch parameter {
            case .lensBlurAmount: return "Lens Blur Amount"
            case .lensBlurFocusNear: return "Focal Range Near"
            case .lensBlurFocusFar: return "Focal Range Far"
            default: return "Lens Blur \(parameter.label)"
            }
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
        guard let session else {
            // Shown once the editable copy is ready (`finishOpen` renders the latest settings).
            if assetID != nil, isLoading, !editBeforeProxyLogged {
                editBeforeProxyLogged = true
                DevelopTimingLog.shared.log(assetID, "edit made before the editable copy was ready; it shows when the copy is ready")
            }
            return
        }
        lastRenderRequest.value = Date()
        settleItem?.cancel()
        if rendering {
            // Every later edit waits behind a render that hasn't come back (Rosh, Nov 9, 2026:
            // B&W and sliders didn't reach the photo). Logged so a hang shows in the trace.
            let running = DevelopTimingLog.now() - renderBeganAt.value
            if running > 2, !renderHangLogged {
                renderHangLogged = true
                DevelopTimingLog.shared.log(assetID, "edit waiting: the render before it has run \(Int(running * 1000)) ms "
                    + "(showing \(showingBefore ? "Before" : "After"))")
            }
        }
        let preview = sliderPreview
        let renderBefore = showingBefore && preview == nil
        var settings = renderBefore ? beforeSettings : self.settings
        if isGuiding { settings = guidedViewSettings(settings) }
        let cropping = !isCropping
        if isCropping, let crop = settings.crop {
            // The crop tool shows the whole photo upright and turns and frames it in the view, so
            // only turns and flips reach the render (`cropToolView`).
            settings.crop = crop.cropToolView
        }
        // In Lens Blur's Refine the overlay shows the Focus area when no area is selected, so
        // Show Overlay always shows something (Rosh, Nov 16, 2026: it often showed nothing).
        let overlay = isMasking && showMaskOverlay
            ? (selectedMaskID ?? (maskScope == .lensBlur ? (lensBlurArea(.focus) ?? lensBlurArea(.blur))?.id : nil))
            : nil
        // With the red overlay on, the photo under it is shown without the blur: the overlay is
        // for seeing the mask, and leaving out the blur's render makes it come up at once instead
        // of after the blur (the blur is back as soon as the overlay is off).
        if overlay != nil, isLensBlurring { settings[.lensBlurApply] = 0 }
        let clipping = overlay == nil && preview == nil ? clippingOverlay : (shadows: false, highlights: false)
        // Dragging the crop frame, its corners or the angle changes nothing the crop tool renders.
        // Rendering it anyway read every frame back from the GPU and handed SwiftUI a new
        // full-size image per tick, which made the drag stutter (Rosh, Nov 20, 2026).
        let key = ProxyRenderKey(settings: settings, preview: preview, renderBefore: renderBefore, cropping: cropping,
                                 overlay: overlay, shadowClipping: clipping.shadows,
                                 highlightClipping: clipping.highlights, assetID: assetID,
                                 generation: openGeneration.value, session: ObjectIdentifier(session),
                                 lensBlur: isLensBlurring)
        if isCropping, key == lastRenderKey { return }
        lastRenderKey = key
        rendering = true
        noteLensBlurWork()
        renderCount += 1
        frameHUD.scheduled(renderCount)
        // Once the photo is up, live frames go straight from the GPU to the photo view (see
        // `PhotoFeed`); the first render is published the ordinary way, as it ends the stand-in.
        let direct = photoFeed.isAttached && firstRenderDone && cropping && !liveFramesOff && !awaitingSharp
        // A frame still rendering for another photo, the Before view, the crop tool or an
        // Option view must not reach the screen once this one is asked for.
        let liveKey = LiveFrameKey(assetID: assetID, generation: openGeneration.value, cropping: cropping,
                                   preview: preview, renderBefore: renderBefore)
        if liveKey != lastLiveKey {
            lastLiveKey = liveKey
            photoFeed.sink.invalidate()
            photoFeed.detail.invalidate()
        }
        // Zoomed in, the visible part is rendered sharp from the full-size photo beside the proxy,
        // whose stretched frame then stays hidden under it.
        let underDetail = direct && overlay == nil && scheduleZoomedDetail(settings, clipping: clipping)
        var request = ProxyRenderRequest(
            session: session, settings: settings, preview: preview, renderBefore: renderBefore, cropping: cropping,
            overlay: overlay, clipping: clipping, assetID: assetID, count: renderCount,
            measures: overlay == nil && preview == nil && !isLensBlurring, generation: openGeneration.value,
            queuedAt: DevelopTimingLog.now(), surfaces: direct ? displaySurfaces : nil,
            fallback: liveFramesOff && photoFeed.isAttached && firstRenderDone && cropping ? .liveFramesOff : nil,
            sink: direct ? photoFeed.sink : nil, liveEpoch: photoFeed.sink.currentEpoch,
            measureJob: measureJob, measureQueue: measureQueue, histogramSink: histogramSink,
            openGeneration: openGeneration, renderBeganAt: renderBeganAt, lensBlur: isLensBlurring)
        request.hidesFrame = underDetail
        submitRender(request)
    }

    /// Hands `request` to the render queue, latest-wins: a request still waiting is replaced, and
    /// the queue starts the next render as soon as one finishes, without waiting for the main
    /// thread (which used to hand out every follow-up render, so a busy main thread held the GPU
    /// idle). Each render is a block of its own on the queue, so the Before photo and stored
    /// previews still get their turn between frames.
    private func submitRender(_ request: ProxyRenderRequest) {
        lastRender = request
        guard renderJob.submit(request) else { return }
        let job = renderJob
        let queue = self.queue
        queue.async { Self.renderNext(job: job, on: queue, controller: self) }
    }

    /// Renders the newest waiting request on the render queue, posts it to the main thread and
    /// queues itself again; the drain ends when nothing is waiting.
    private nonisolated static func renderNext(job: LatestJob<ProxyRenderRequest>, on queue: DispatchQueue,
                                               controller: DevelopController) {
        guard let request = job.take() else { return }
        let renderBegan = DevelopTimingLog.now()
        let renderClock = CACurrentMediaTime()
        request.renderBeganAt.value = renderBegan
        var surface: IOSurface?
        var cgImage: CGImage?
        var plain: CGImage?
        var fallback = request.fallback
        var outcome: LiveFrameSink.Outcome?
        var renderedAt: CFTimeInterval?
        var shownAt: CFTimeInterval?
        RenderSignposts.measure("Proxy render") {
            if let surfaces = request.surfaces, let sink = request.sink,
               let frame = request.session.renderToSurface(request.settings, cropping: request.cropping,
                                                           overlay: request.overlay, preview: request.preview,
                                                           shadowClipping: request.clipping.shadows,
                                                           highlightClipping: request.clipping.highlights,
                                                           surfaces: surfaces, onPoolFull: { fallback = .poolFull },
                                                           onRendered: { rendered in
                    // On screen now, from this thread: the main thread may be busy (D1). The
                    // histogram's small copy is made after this, never before.
                    renderedAt = CACurrentMediaTime()
                    let result = sink.present(rendered, count: request.count, epoch: request.liveEpoch, pool: surfaces,
                                              hidden: request.hidesFrame)
                    outcome = result
                    if result == .shown { shownAt = CACurrentMediaTime() }
                }) {
                surface = frame.surface
                plain = frame.plain
            } else if let rendered = request.session.renderForDisplay(request.settings, cropping: request.cropping,
                                                                      overlay: request.overlay, preview: request.preview,
                                                                      shadowClipping: request.clipping.shadows,
                                                                      highlightClipping: request.clipping.highlights) {
                cgImage = rendered.image
                plain = rendered.plain
            }
        }
        let readyAt = renderedAt ?? CACurrentMediaTime()
        controller.proxyRenders.update { $0.record(readyAt - renderClock) }
        let renderTook = DevelopTimingLog.ms(since: renderBegan)
        if renderTook > 300 || (surface == nil && cgImage == nil) {
            DevelopTimingLog.shared.log(request.assetID, surface == nil && cgImage == nil ? "render FAILED after \(renderTook) ms"
                : "slow render: \(renderTook) ms (waited \(Int(((renderBegan - request.queuedAt) * 1000).rounded())) ms for the render queue)")
        }
        // The red overlay or an Option-drag view would skew the histogram; keep the last one
        // while it shows. It is counted after the photo is on its way, beside the next render.
        if request.measures, let plain {
            Self.measure(DevelopMeasureRequest(image: plain, assetID: request.assetID, count: request.count,
                                          generation: request.generation),
                    job: request.measureJob, on: request.measureQueue, sink: request.histogramSink,
                    openGeneration: request.openGeneration) { measured, histogram, scope, took in
                MainActor.assumeIsolated { controller.applyMeasure(measured, histogram: histogram, scope: scope, took: took) }
            }
        }
        let timing = PhotoFeed.RenderTiming(count: request.count, readyAt: readyAt, duration: readyAt - renderClock,
                                           queueWait: max(0, renderBegan - request.queuedAt), shownAt: shownAt)
        // A live frame is already on screen (or was dropped and its surface returned); the main
        // thread only does the bookkeeping.
        let live = surface == nil ? nil : outcome
        DispatchQueue.main.async { [fallback] in
            MainActor.assumeIsolated {
                controller.finishRender(request, live: live, cgImage: cgImage, fallback: fallback,
                                        renderBegan: renderBegan, timing: timing)
            }
        }
        queue.async { Self.renderNext(job: job, on: queue, controller: controller) }
    }

    private func finishRender(_ request: ProxyRenderRequest, live: LiveFrameSink.Outcome?, cgImage: CGImage?,
                              fallback: PhotoFeed.Fallback?,
                              renderBegan: CFAbsoluteTime, timing: PhotoFeed.RenderTiming) {
        // Nothing newer has been asked for.
        let latest = request.count == renderCount
        if latest { rendering = false }
        // A render that failed may be asked for again with the same settings.
        if latest, live == nil, cgImage == nil { lastRenderKey = nil }
        renderHangLogged = false
        // Rendered from this open's copy, not one from before a `reopen()` of the same photo (the
        // old file). A render started before the crop tool opened or closed has the wrong shape;
        // the next render replaces it.
        let current = assetID == request.assetID && openGeneration.value == request.generation
        let fits = current && request.cropping != isCropping && request.preview == sliderPreview
            && request.renderBefore == (showingBefore && sliderPreview == nil)
            && request.lensBlur == isLensBlurring
        var shownLive = false
        switch live {
        case .shown:
            shownLive = true
            photoFeed.frameShown(timing)
        case .wrongShape, .noView:
            guard fits else { break }
            // Another shape than the photo on screen (an Aspect or crop change), or the view is
            // gone: frames take the ordinary path until the edit ends, and this one is redone
            // that way.
            liveFramesOff = true
            if latest {
                var ordinary = request
                ordinary.surfaces = nil
                ordinary.sink = nil
                ordinary.fallback = .liveFramesOff
                rendering = true
                submitRender(ordinary)
                return
            }
        case .stale:
            // Dropped because the photo view changed under it (attached again, another mode). If
            // nothing newer is coming, show this edit the ordinary way so the photo isn't left on
            // an older frame.
            if latest, fits {
                var ordinary = request
                ordinary.surfaces = nil
                ordinary.sink = nil
                rendering = true
                submitRender(ordinary)
                return
            }
        case nil:
            break
        }
        if fits, let cgImage {
            if let fallback { frameHUD.fallback(fallback, count: request.count) }
            let shown = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            image = shown
            photoFeed.published(shown, count: request.count, timing: timing)
            showsStandIn = false
            imageIsWhole = !request.cropping
        }
        if current, !firstRenderDone {
            // The photo itself is on screen now (or its render failed): no spinner.
            isLoading = false
            DevelopTimingLog.shared.log(request.assetID, "first render: waited \(Int(((renderBegan - request.queuedAt) * 1000).rounded())) ms "
                + "for the render queue, rendered in \(DevelopTimingLog.ms(since: renderBegan)) ms, "
                + "photo shown +\(DevelopTimingLog.ms(since: openedAt)) ms")
            firstRenderDone = true
            prefetchNeighboursWhenIdle()
        }
        guard latest else { return }
        // A live frame is a drag in progress: the full-size render waits for the settled render
        // (`publishWhenSettled`), whose finish lands here again. Started after every live frame,
        // it ran 24 MP renders beside the drag's on the GPU for settings never shown, since the
        // zoomed photo shows the full-size image only once it matches (AT-039 D4).
        if shownLive {
            publishWhenSettled(request)
            return
        }
        scheduleFullRender()
        if compareMode != .off { scheduleFullBeforeRender() }
    }

    /// Once the edit rests, renders the last live frame's settings the ordinary way and publishes
    /// that image, so everything that reads `image` (and the photo at rest) is exactly as before.
    /// Any newer edit cancels it; a drag publishes nothing until it pauses.
    private func publishWhenSettled(_ request: ProxyRenderRequest) {
        settleItem?.cancel()
        let count = request.count
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.renderCount == count, var settled = self.lastRender, settled.count == count else { return }
                self.zoomedDetailSettled()
                settled.surfaces = nil
                settled.sink = nil
                settled.fallback = nil
                self.rendering = true
                self.submitRender(settled)
            }
        }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }

    /// Preloads the neighbours once the photo has gone `prefetchDelay` without a render, checking
    /// again until it has.
    private func prefetchNeighboursWhenIdle() {
        let assetID = self.assetID
        var wait = Self.prefetchDelay - Date().timeIntervalSince(lastRenderRequest.value)
        // The Before photo of a compare view comes first.
        if beforeRequest.value != nil { wait = max(wait, Self.prefetchDelay) }
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard self.assetID == assetID else { return }
                self.prefetchNeighboursWhenIdle()
            }
            return
        }
        prefetchNeighbours()
    }

    /// Decodes the neighbours' proxies and renders each once (which keeps the decoded photo in
    /// the session), one at a time at utility priority, never for a photo you've already left.
    private func prefetchNeighbours() {
        guard let current = assetID else { return }
        prefetchOriginals?(neighbours)
        let wanted = Set(neighbours)
        prefetched = prefetched.filter { wanted.contains($0.key) }
        let openAsset = self.openAsset
        let decodesRunning = self.decodesRunning
        let lastRenderRequest = self.lastRenderRequest
        for id in neighbours where prefetched[id] == nil && !prefetching.contains(id) {
            // Only from this Mac: a placeholder in a cloud drive folder (AT-079b) or an original on a
            // share not cached yet (AT-079c) would hold a decode slot for the whole transfer. Shares'
            // neighbours are read into the cache instead (`prefetchOriginals`, below).
            guard let url = try? catalog.readableURL(for: id, cache: originals),
                  needsPreparing?(id, url) != true else { continue }
            let settings = (try? catalog.developSettings(for: id)) ?? .neutral
            let sourceVersion = sourceVersions[id, default: 0]
            prefetching.insert(id)
            Self.prefetchQueue.async {
                var session: DevelopSession?
                var editing = false
                // Moved on before its turn: the next photo's neighbours are wanted instead. Editing
                // since: wait for the next quiet moment (prefetching is cleared, so it's asked again).
                if openAsset.value == current,
                   Date().timeIntervalSince(lastRenderRequest.value) >= Self.prefetchDelay {
                    let began = DevelopTimingLog.now()
                    decodesRunning.value += 1
                    session = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.proxySize, interactive: true)
                    _ = session?.renderForDisplay(settings)
                    decodesRunning.value -= 1
                    DevelopTimingLog.shared.log(id, "preloaded as a neighbour of #\(current) in \(DevelopTimingLog.ms(since: began)) ms")
                } else if openAsset.value == current {
                    editing = true
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.prefetching.remove(id)
                        // Skipped for an edit: try again once editing pauses.
                        if editing, self.assetID == current { self.prefetchNeighboursWhenIdle() }
                        guard let session else { return }
                        guard self.neighbours.contains(id), self.assetID != id,
                              self.sourceVersions[id, default: 0] == sourceVersion else { return }
                        self.prefetched[id] = session
                    }
                }
            }
        }
    }

    /// Counts a histogram and color scope off the main thread, latest-wins. A request for a
    /// photo already left (a late render of the last photo) is dropped before it can replace the
    /// open photo's waiting request. `apply` must not depend on the request it was passed with:
    /// the drain applies whichever request it takes with the first caller's closure.
    private nonisolated static func measure(_ request: DevelopMeasureRequest, job: LatestJob<DevelopMeasureRequest>,
                                            on queue: DispatchQueue, sink: HistogramSink, openGeneration: LockedValue<Int>,
                                            apply: @escaping @Sendable (DevelopMeasureRequest, Histogram?, ColorScope?, Int) -> Void) {
        // Not for an earlier open, and never in place of a waiting request that outranks it (the
        // render's count must not be replaced by the preview that arrived late).
        guard job.submit(request, if: { new, pending in
            guard new.generation == openGeneration.value else { return false }
            guard let pending, pending.generation == new.generation else { return true }
            return new.rank >= pending.rank
        }) else { return }
        queue.async {
            while let request = job.take() {
                let began = DevelopTimingLog.now()
                let (histogram, picture, scope) = RenderSignposts.measure("Histogram") { () -> (Histogram?, CGImage?, ColorScope?) in
                    let histogram = Histogram(image: request.image)
                    return (histogram, histogram.flatMap { HistogramPicture.make($0) }, ColorScope(image: request.image))
                }
                let took = DevelopTimingLog.ms(since: began)
                // The graph goes on screen from here (`HistogramSink`); the main thread gets the
                // counts for the clipping triangles, curve backdrops and wheels.
                if let picture { sink.present(picture, generation: request.generation, rank: request.rank) }
                DispatchQueue.main.async { apply(request, histogram, scope, took) }
            }
        }
    }

    private func applyMeasure(_ request: DevelopMeasureRequest, histogram: Histogram?, scope: ColorScope?, took: Int) {
        guard assetID == request.assetID, openGeneration.value == request.generation,
              request.rank >= measuredRank else { return }
        let fromPreview = request.fromPreview
        if !histogramLogged || fromPreview {
            if !fromPreview { histogramLogged = true }
            DevelopTimingLog.shared.log(request.assetID, "histogram from the \(fromPreview ? "cached preview" : "first render"): "
                + "counted in \(took) ms, shown +\(DevelopTimingLog.ms(since: openedAt)) ms")
        }
        measuredRank = request.rank
        guard histogram != nil || scope != nil else { return }
        // At most one SwiftUI update for the counts per `measurePublishInterval` during a drag,
        // the newest at its end; the graph itself is already on screen (`HistogramSink`). The
        // first count of a photo goes out at once.
        pendingMeasure = (histogram ?? pendingMeasure?.histogram, scope ?? pendingMeasure?.scope)
        let wait = Self.measurePublishInterval - (CACurrentMediaTime() - measurePublishedAt)
        if wait <= 0 || measures.histogram == nil {
            publishPendingMeasure()
        } else if !measurePublishScheduled {
            measurePublishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.measurePublishScheduled = false
                    self?.publishPendingMeasure()
                }
            }
        }
    }

    /// How often the counts reach SwiftUI during a drag: the clipping triangles, the Tone Curve
    /// backdrops and the wheels' scope update about ten times a second, the graph at every frame.
    private static let measurePublishInterval: CFTimeInterval = 0.1

    private func publishPendingMeasure() {
        guard let pending = pendingMeasure else { return }
        pendingMeasure = nil
        measurePublishedAt = CACurrentMediaTime()
        frameHUD.histogramPublished()
        if let histogram = pending.histogram { measures.histogram = histogram }
        if let scope = pending.scope { measures.colorScope = scope }
    }

    /// Until the photo's first render is counted, the histogram comes from the cached preview
    /// it opens on, as Lightroom does, so it doesn't spin while you move through photos or the
    /// photo decodes (Rosh, Nov 9, 2026). Any render's count replaces it.
    private func measurePreview(_ preview: NSImage?, of assetID: Int64) {
        guard let preview, !showsPreviousPhoto,
              let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Self.measure(DevelopMeasureRequest(image: cgImage, assetID: assetID, count: renderCount,
                                           generation: openGeneration.value, fromPreview: true),
                     job: measureJob, on: measureQueue, sink: histogramSink, openGeneration: openGeneration) { request, histogram, scope, took in
            MainActor.assumeIsolated { self.applyMeasure(request, histogram: histogram, scope: scope, took: took) }
        }
    }

    /// The clipping overlay the next render paints: none on the Before view or while cropping or
    /// using the AI tool, which work on the plain photo.
    private var clippingOverlay: (shadows: Bool, highlights: Bool) {
        guard !showingBefore, !isCropping, !isAIOpen else { return (false, false) }
        return (showShadowClipping, showHighlightClipping)
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

    /// The comparison proxies come first. The full-size queue also uses Core Image and can
    /// compete with the foreground queue even though it runs on a separate thread.
    private var canRenderFullResolution: Bool {
        wantsFullResolution && (compareMode == .off || (firstRenderDone && beforeRequest.value == nil))
    }

    /// Lets the photo view show the open photo again (`awaitingSharp`); logs how long it waited.
    private func endAwaitingSharp(because reason: String?) {
        sharpOpenTimeout?.cancel()
        sharpOpenTimeout = nil
        guard awaitingSharp else { return }
        awaitingSharp = false
        if let reason {
            DevelopTimingLog.shared.log(assetID, "zoomed open shown \(reason) +\(DevelopTimingLog.ms(since: sharpOpenBegan)) ms")
        }
    }

    /// Back at Fit: the full-size images and session go after a few seconds (zooming in again
    /// within that keeps them), so a photo looked at closely once doesn't hold hundreds of MB
    /// until another photo opens (AT-077).
    private func scheduleFullRelease() {
        fullRelease?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseFullResolution(because: "back to Fit") }
        }
        fullRelease = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    /// Drops the full-size images and session now, unless the view is zoomed in (then nothing
    /// changes). Also on leaving Develop and on memory pressure.
    func releaseFullResolution(because reason: String) {
        fullRelease?.cancel()
        fullRelease = nil
        guard !wantsFullResolution else { return }
        let held = fullImage != nil || fullBeforeImage != nil || fullSession != nil
        fullImage = nil
        fullImageSettings = nil
        fullImageIsStale = false
        fullBeforeImage = nil
        fullBeforeSettings = nil
        fullSession = nil
        fullNeedsRender = false
        fullBeforeNeedsRender = false
        photoFeed.detail.invalidate()
        detailSurfaces.drain()
        if held {
            RenderMemory.shared.clear(because: reason)
            DevelopTimingLog.shared.log(assetID, "full size let go (\(reason))")
        }
    }

    /// Full-resolution render for zoomed views, after the proxy settles. Latest wins. Not while
    /// the mask overlay shows: the photo is then the proxy with the red tint (`displayImage`), so
    /// a full-size render would never be seen, and on a heavy photo (Lens Blur with Focus areas)
    /// it held the GPU after every brush stroke, so turning Show Overlay on or off waited
    /// seconds for it (Rosh, Nov 16, 2026). Turning the overlay off renders, which lands here.
    private func scheduleFullRender() {
        guard canRenderFullResolution, sliderPreview == nil, !showingBefore, !isCropping, !isGuiding,
              !(isMasking && showMaskOverlay), let url = sourceURL,
              fullImageSettings != settings || fullImageIsStale else { return }
        if fullRendering {
            fullNeedsRender = true
            return
        }
        fullRendering = true
        noteLensBlurWork()
        fullImageIsStale = false
        let settings = self.settings
        let assetID = self.assetID
        let existing = fullSession
        let clipping = clippingOverlay
        let blurs = isLensBlurring
        fullQueue.async {
            let began = DevelopTimingLog.now()
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: nil, interactive: true)
            session?.rendersLensBlur = blurs
            let cgImage = RenderSignposts.measure("Full-size render") {
                session?.renderForDisplay(settings, shadowClipping: clipping.shadows,
                                          highlightClipping: clipping.highlights)?.image
            }
            DevelopTimingLog.shared.log(assetID, "full-size render (zoomed in)\(existing == nil ? " with full decode" : "")"
                + "\(blurs ? " with Lens Blur" : ""): \(DevelopTimingLog.ms(since: began)) ms")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fullRendering = false
                    // Back at Fit meanwhile: the full size was let go (`releaseFullResolution`).
                    guard self.assetID == assetID, self.wantsFullResolution, let session else { return }
                    self.fullSession = session
                    session.rendersLensBlur = self.isLensBlurring
                    // Rendered before the Lens Blur mode opened or closed: render again.
                    if let cgImage, blurs == self.isLensBlurring {
                        self.fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.fullImageSettings = settings
                        self.endAwaitingSharp(because: "sharp")
                    } else if cgImage != nil {
                        self.fullNeedsRender = true
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
        guard canRenderFullResolution, compareMode != .off, let url = sourceURL else { return }
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
            let began = DevelopTimingLog.now()
            let session = existing ?? DevelopRenderer.shared.session(for: url, maxPixelSize: nil, interactive: true)
            let cgImage = RenderSignposts.measure("Full-size Before render") { session?.render(before) }
            DevelopTimingLog.shared.log(assetID, "full-size Before render: \(DevelopTimingLog.ms(since: began)) ms")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fullBeforeRendering = false
                    guard self.assetID == assetID, self.wantsFullResolution, let session else { return }
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
        guard beforeImage == nil, let assetID, let session else {
            scheduleFullBeforeRender()
            return
        }
        let key = BeforeRenderRequest.Key(generation: openGeneration.value, settings: beforeSettings)
        guard beforeRequest.value?.key != key else { return }
        lastRenderRequest.value = Date()
        beforeRequest.value = BeforeRenderRequest(key: key, assetID: assetID, session: session,
                                                  queuedAt: DevelopTimingLog.now(), openedAt: openedAt)
        scheduleBeforeRender()
    }

    private func scheduleBeforeRender() {
        guard !beforeRenderScheduled, beforeRequest.value != nil else { return }
        beforeRenderScheduled = true
        let beforeRequest = self.beforeRequest
        let lastRenderRequest = self.lastRenderRequest
        queue.async {
            let request = beforeRequest.value
            let began = DevelopTimingLog.now()
            let cgImage = request.flatMap { request in
                RenderSignposts.measure("Before proxy render") { request.session.render(request.key.settings) }
            }
            if let request {
                lastRenderRequest.value = Date()
                DevelopTimingLog.shared.log(request.assetID, "Before render: waited \(Int(((began - request.queuedAt) * 1000).rounded())) ms "
                    + "for the render queue, rendered in \(DevelopTimingLog.ms(since: began)) ms, "
                    + "finished +\(DevelopTimingLog.ms(since: request.openedAt)) ms after open"
                    + (cgImage == nil ? " (failed)" : ""))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.beforeRenderScheduled = false
                    if let request, beforeRequest.value?.key == request.key {
                        beforeRequest.value = nil
                        if let cgImage {
                            self.beforeImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        }
                        if !self.rendering { self.scheduleFullRender() }
                        self.scheduleFullBeforeRender()
                    }
                    self.scheduleBeforeRender()
                }
            }
        }
    }

    // MARK: Saving

    /// All mouse-driven tools share this boundary, including AppKit overlays.
    func beginPointerEdit() {
        commitPendingStep()
        pointerEditInProgress = true
    }

    func endPointerEdit() {
        guard pointerEditInProgress, !isPrimaryButtonPressed() else { return }
        pointerEditInProgress = false
        liveFramesOff = false
        if dirty { flushSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            if self.pointerEditInProgress, self.isPrimaryButtonPressed() {
                // A stationary pointer can still be part of a drag. The timer also handles
                // mouse-up events consumed by a native control's tracking loop.
                self.scheduleSave()
            } else if self.pointerEditInProgress {
                self.endPointerEdit()
            } else {
                self.flushSave()
            }
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
            let began = DevelopTimingLog.now()
            try catalog.saveDevelop(settings, history: history, for: assetID)
            // On main, so reads that follow see it; timed so AT-039 D5 can tell whether moving it
            // off main is worth a pending-save layer.
            DevelopTimingLog.shared.log(assetID, "saved: \(DevelopTimingLog.ms(since: began)) ms on main, "
                + "\(history.steps.count) history steps")
            onSettingsSaved?(assetID)
        } catch {
            dirty = true
            errorMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        // Lens Blur never shows in the stored previews, so an edit that changed only Lens Blur
        // leaves them as they are (each one was a full render and a JPEG write per Lens Blur edit).
        let onlyLensBlur = lastPreviewSettings.map { $0.assetID == assetID
            && Self.withoutLensBlur($0.settings) == Self.withoutLensBlur(settings) } ?? false
        lastPreviewSettings = (assetID, settings)
        if onlyLensBlur {
            return
        } else if let session {
            storePreviews(session: session, settings: settings, assetID: assetID)
        } else {
            // Saved while the editable copy is still decoding: refresh Grid and Loupe once it's
            // ready (`finishOpen`), or from the saved settings if the photo is left first (`open`).
            previewsOwed = assetID
        }
    }

    /// Renders `settings` in the background and stores it as the photo's grid thumbnail and
    /// loupe preview. `optional` is the unedited RAW's lens-corrected preview made on first open,
    /// which is skipped once you've moved on (it's made again next visit); saved edits always
    /// refresh both sizes, or Grid and Loupe would keep showing the old look.
    private func storePreviews(session: DevelopSession, settings: DevelopSettings, assetID: Int64,
                               optional: Bool = false) {
        let previews = self.previews
        let openAsset = self.openAsset
        let revisions = previewRevisions
        // Optional work never claims a revision: if it's skipped, it mustn't make a saved edit's
        // (required) write look obsolete. It writes only while no newer saved write was asked for.
        let revision = optional ? (previewRevisions.value[assetID] ?? 0) : nextPreviewRevision(for: assetID)
        // Not on the live render queue: a 28–35 ms preview render there held the next drag's
        // first frames (AT-039 D5).
        Self.previewQueue.async {
            // Moving on quickly through photos: the optional first-open preview can wait.
            if optional, openAsset.value != assetID {
                DispatchQueue.main.async {
                    // Not stored, so make it again on the next visit.
                    MainActor.assumeIsolated { _ = self.developedPreviews.remove(assetID) }
                }
                return
            }
            let began = DevelopTimingLog.now()
            defer { DevelopTimingLog.shared.log(assetID, "preview stored\(optional ? " (lens-corrected, first open)" : " (saved edit)"): \(DevelopTimingLog.ms(since: began)) ms on the preview queue") }
            // The original's own previews never show its Lens Blur (only the Lens Blur photo
            // does), also while the Lens Blur mode has the session rendering it.
            var unblurred = settings
            unblurred[.lensBlurApply] = 0
            if let cgImage = session.render(unblurred) {
                Self.writePreviews(cgImage, for: assetID, revision: revision, previews: previews, revisions: revisions)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onPreviewsUpdated?(assetID) }
            }
        }
    }

    /// Grid and Loupe previews of the open photo, rendered beside the live renders instead of
    /// between them.
    private static let previewQueue = DispatchQueue(label: "atelier.develop.previews", qos: .utility)
    /// Other photos' preview refreshes (`refreshPreviews`), two at a time.
    private static let refreshQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "atelier.develop.refresh"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    /// Each photo's latest preview write asked for (`nextPreviewRevision`). Writes come from the
    /// render queue and from independent decodes (`refreshPreviews`), so an older one can finish
    /// last; it is dropped instead of overwriting the newer saved look.
    private let previewRevisions = LockedValue<[Int64: Int]>([:])
    private nonisolated static let previewWriteLock = NSLock()

    private func nextPreviewRevision(for assetID: Int64) -> Int {
        var revisions = previewRevisions.value
        let next = (revisions[assetID] ?? 0) + 1
        revisions[assetID] = next
        previewRevisions.value = revisions
        return next
    }

    /// Stores both preview sizes, unless a newer write for the photo has been asked for since.
    private nonisolated static func writePreviews(_ cgImage: CGImage, for assetID: Int64, revision: Int,
                                                  previews: PreviewCache, revisions: LockedValue<[Int64: Int]>) {
        previewWriteLock.lock()
        defer { previewWriteLock.unlock() }
        guard (revisions.value[assetID] ?? 0) == revision else {
            DevelopTimingLog.shared.log(assetID, "older preview write dropped: a newer saved look was asked for")
            return
        }
        try? previews.store(cgImage, for: assetID, size: .preview)
        try? previews.store(cgImage, for: assetID, size: .thumbnail)
    }

    /// Re-renders previews for a photo that is not open, after pasting settings onto it.
    /// Two at a time, and skipped when a newer edit of the same photo was saved before its turn
    /// came: an agent's edit of hundreds of photos, or several quick ones, mustn't start a decode
    /// per photo per edit all at once (AT-050d; each was its own block on a global queue before).
    func refreshPreviews(for assetID: Int64, settings: DevelopSettings) {
        guard let url = try? catalog.readableURL(for: assetID, cache: originals) else { return }
        let previews = self.previews
        let revisions = previewRevisions
        let revision = nextPreviewRevision(for: assetID)
        let tally = refreshRenders
        Self.refreshQueue.addOperation {
            guard (revisions.value[assetID] ?? 0) == revision else {
                tally.update { $0.skipped += 1 }
                return
            }
            let began = CACurrentMediaTime()
            guard let session = DevelopRenderer.shared.session(for: url, maxPixelSize: Self.proxySize),
                  let cgImage = session.render(settings) else { return }
            tally.update { $0.record(CACurrentMediaTime() - began) }
            Self.writePreviews(cgImage, for: assetID, revision: revision, previews: previews, revisions: revisions)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onPreviewsUpdated?(assetID) }
            }
        }
    }
}

// MARK: Masks

/// What a drag on the photo draws next: a new mask, or a part added to the selected one.
/// Which masks the mask tools edit (see `DevelopController.editedMasks`).
enum MaskScope: Equatable {
    case look, lensBlur
}

struct MaskTool: Equatable {
    var kind: DevelopSettings.MaskComponent.Kind
    var mode: DevelopSettings.MaskComponent.Mode = .add
    var newMask = true
    /// In Lens Blur's Refine: the area (Focus or Blur) the part goes into.
    var role: DevelopSettings.LensBlurRole?

    var hint: String {
        switch kind {
        case .linear: return "Drag on the photo from where the effect is full to where it fades out."
        case .radial: return "Drag on the photo from the center outward to draw the ellipse."
        case .brush: return "Paint on the photo. Hold ⌥ to erase; [ and ] change the size."
        case .object: return "Drag a box around the object to select it."
        case .color: return "Click a color on the photo, or drag over an area to pick its range of colors."
        case .luminance, .depth, .subject, .sky, .background, .people: return ""
        }
    }
}

extension DevelopController {
    typealias Mask = DevelopSettings.Mask
    typealias MaskComponent = DevelopSettings.MaskComponent

    var masks: [Mask] { editedMasks }

    /// The masks the mask tools work on: Masking's (`settings.masks`), or Lens Blur's Focus and
    /// Blur areas (`settings.lensBlurAreas`) while refining Lens Blur. Every mask tool (parts,
    /// brushes, edge controls, delete, undo) goes through this, so both share one code path.
    var editedMasks: [Mask] {
        get { maskScope == .lensBlur ? settings.lensBlurAreas : settings.masks }
        set {
            if maskScope == .lensBlur { settings.lensBlurAreas = newValue } else { settings.masks = newValue }
        }
    }

    var selectedMask: Mask? { editedMasks.first { $0.id == selectedMaskID } }

    var selectedComponent: MaskComponent? {
        selectedMask?.components.first { $0.id == selectedComponentID }
    }

    private func maskIndex(_ id: UUID?) -> Int? {
        editedMasks.firstIndex { $0.id == id }
    }

    /// Keeps the selection pointing at masks that exist after undo, presets or paste.
    fileprivate func validateMaskSelection() {
        guard let mask = selectedMask else {
            selectedMaskID = isMasking ? editedMasks.last?.id : nil
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
        // Refining Lens Blur there are only the two areas: a new part goes into the selected
        // one (Focus by default), so the mask keys (K, M, ⇧M...) work there too.
        if maskScope == .lensBlur {
            return addLensBlurPart(kind, to: selectedMask?.lensBlurRole ?? .focus, mode: .add)
        }
        if kind.isDrawn {
            maskTool = MaskTool(kind: kind)
        } else {
            insert(MaskComponent(Self.defaultShape(kind)), tool: MaskTool(kind: kind))
        }
    }

    /// A mask, matte or depth map found in the background (by the proxy's session or the
    /// full-size one) is in: render again, the full-size image too. Its settings haven't
    /// changed, so without forgetting them the zoomed photo kept the render made before it
    /// arrived: in the Lens Blur mode, the photo unblurred until the depth was found, or a Focus
    /// area without its Fine Edges.
    private func backgroundWorkArrived() {
        // The full-size image stays on screen until the new one is in, rather than the proxy.
        fullImageIsStale = true
        renderFreshResult()
    }

    /// Renders again with the same settings, for work that finished in the background (a fill,
    /// a model's mask), which the crop tool's skip of unchanged renders must not hold back.
    private func renderFreshResult() {
        lastRenderKey = nil
        scheduleRender()
    }

    // MARK: Lens Blur mode

    /// Opening or closing the Lens Blur mode: the other tools close, the live sessions start or
    /// stop rendering Lens Blur, and the photo renders again (the full-size render too).
    private func lensBlurModeChanged() {
        DevelopTimingLog.shared.log(assetID, (isLensBlurring ? "Lens Blur mode opened" : "Lens Blur mode closed")
            + " (full-size render \(fullRendering ? "running" : "idle"), render \(rendering ? "running" : "idle"))")
        let restored: Bool
        if isLensBlurring {
            commitPendingStep()
            lensBlurEntry = assetID.map { ($0, openGeneration.value, settings, history) }
            lensBlurReturn = shownUnblurred()
            restored = false
            isCropping = false
            isAIOpen = false
            isGuiding = false
            isRemoving = false
            if isMasking, maskScope == .look { isMasking = false }
            picker = nil
            showingBefore = false
            compareMode = .off
            // The mode is where Lens Blur is edited: a switched-off panel would show nothing.
            if !settings.isOn(.lensBlur) { setPanelOn(.lensBlur, true) }
            loadLensBlurPhoto()
            // A photo that never had Lens Blur blurs as soon as the mode opens (Apply, which also
            // focuses on the subject), rather than looking as if nothing works. After the entry
            // above, so Cancel takes it back.
            if lensBlurNeverUsed { setLensBlurApplied(true) }
        } else {
            visualizesDepth = false
            finishLensBlurRefine()
            if picker == .lensFocus { picker = nil }
            lensBlurSaveError = nil
            revertLensBlurChanges()
            restored = restoreUnblurred()
        }
        session?.rendersLensBlur = isLensBlurring
        fullSession?.rendersLensBlur = isLensBlurring
        // The Navigator isn't shown in the mode: never pay for a second blur there.
        navigatorSession?.rendersLensBlur = false
        // Blurred frames still on their way must not land after Close (nor unblurred ones after
        // opening the mode).
        photoFeed.sink.invalidate()
        if !restored { fullImageSettings = nil }
        if !isLensBlurring {
            lensBlurWorkCheck?.cancel()
            lensBlurWorkCheck = nil
            lensBlurWork = nil
        }
        beforeImage = nil
        // Closing lets go of every Lens Blur result Core Image kept (AT-077: they used to pile up
        // until the Mac ran out of memory). The photo on screen was put back above; the next
        // render decodes step 1 again in the background.
        // The depth and Fine Edges models are unloaded too: their runs' working memory is several
        // GB (Mac check of PR #157).
        if !isLensBlurring { RenderMemory.shared.releaseAllSoon(because: "Lens Blur closed") }
        scheduleRender()
        onLensBlurModeChanged?(isLensBlurring)
    }

    /// Lens Blur off and at its defaults (Amount, Focal Range, no Focus or Blur areas): the photo
    /// never had it.
    private var lensBlurNeverUsed: Bool {
        settings[.lensBlurApply] < 0.5 && settings.lensBlurAreas.isEmpty
            && [DevelopSettings.Parameter.lensBlurAmount, .lensBlurFocusNear, .lensBlurFocusFar]
                .allSatisfy { settings[$0] == $0.defaultValue }
    }

    /// After a Save: what the mode changed is kept, so closing it no longer cancels anything.
    func keepLensBlurChanges() {
        guard let entry = lensBlurEntry, entry.assetID == assetID else { return }
        commitPendingStep()
        lensBlurEntry = (entry.assetID, entry.generation, settings, history)
    }

    /// Whether closing now would throw anything away.
    var lensBlurHasChanges: Bool {
        guard let entry = lensBlurEntry, entry.assetID == assetID else { return false }
        return entry.settings != settings
    }

    /// Cancel: the settings and history as they were when the mode opened (snapshots made
    /// meanwhile stay), saved at once.
    private func revertLensBlurChanges() {
        defer { lensBlurEntry = nil }
        guard let entry = lensBlurEntry, entry.assetID == assetID, entry.generation == openGeneration.value else { return }
        saveTask?.cancel()
        pendingStep = nil
        guard entry.settings != settings || entry.history.steps.count != history.steps.count else { return }
        let snapshots = history.snapshots
        settings = entry.settings
        history = entry.history
        history.snapshots = snapshots
        committed = settings
        validateMaskSelection()
        dirty = true
        DevelopTimingLog.shared.log(assetID, "Lens Blur cancelled: its changes undone")
        flushSave()
    }

    /// Something may have started or stopped: the progress line is checked a moment later and
    /// then every 0.4 s while anything works, so a quick render shows nothing, a drag doesn't
    /// make it flicker, and SwiftUI hears of it at most a few times a second.
    func noteLensBlurWork() {
        guard isLensBlurring || lensBlurWork != nil else { return }
        guard lensBlurWorkCheck == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lensBlurWorkCheck = nil
                let now = self.lensBlurWorkNow()
                if self.lensBlurWork != now { self.lensBlurWork = now }
                if now != nil { self.noteLensBlurWork() }
            }
        }
        lensBlurWorkCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func lensBlurWorkNow() -> String? {
        guard isLensBlurring else { return nil }
        if FineEdges.isWorking { return "Fine Edges is finding the hair…" }
        if DepthMap.isWorking { return "Finding the depth…" }
        if fullRendering { return "Rendering the blur at full size…" }
        if rendering { return "Rendering the blur…" }
        return nil
    }

    struct LensBlurReturn {
        let assetID: Int64
        let generation: Int
        /// The settings without Lens Blur: the same means the same unblurred photo.
        let unblurred: DevelopSettings
        let image: NSImage
        let fullImage: NSImage?
    }

    /// What is on screen now, unblurred, to put back when the mode closes. Nil while a stand-in
    /// or nothing is shown.
    private func shownUnblurred() -> LensBlurReturn? {
        // Only the edited photo as it rests: not Before, a crop, an Option view, a guide or the
        // mask overlay, which `image` may be showing instead.
        guard let assetID, let image, firstRenderDone, !showsStandIn, !showsPreviousPhoto, !imageIsWhole,
              !showingBefore, sliderPreview == nil, !isCropping, !isGuiding, !(isMasking && showMaskOverlay)
        else { return nil }
        let full = fullImageSettings == settings && !fullImageIsStale ? fullImage : nil
        return LensBlurReturn(assetID: assetID, generation: openGeneration.value,
                              unblurred: Self.withoutLensBlur(settings), image: image, fullImage: full)
    }

    /// On Close: the photo as it was before the mode, at once, when only Lens Blur changed since
    /// (Rosh, Nov 16, 2026: Close took seconds to take the blur away, waiting behind the blurred
    /// renders still running). The render that follows draws the same picture.
    private func restoreUnblurred() -> Bool {
        defer { lensBlurReturn = nil }
        guard let saved = lensBlurReturn, saved.assetID == assetID, saved.generation == openGeneration.value,
              saved.unblurred == Self.withoutLensBlur(settings) else { return false }
        image = saved.image
        // As new as every blurred frame, so the view takes it over the frame layer; the render
        // asked for next (one count on) can still replace it.
        photoFeed.published(saved.image, count: renderCount)
        if let full = saved.fullImage {
            fullImage = full
            fullImageSettings = settings
        } else {
            fullImageSettings = nil
        }
        DevelopTimingLog.shared.log(assetID, "Lens Blur closed: the unblurred photo put back at once"
            + (saved.fullImage == nil ? "" : " (full size too)"))
        return true
    }

    /// `settings` with Lens Blur's own settings back at their neutral values.
    static func withoutLensBlur(_ settings: DevelopSettings) -> DevelopSettings {
        var plain = settings
        for parameter in DevelopSettings.Panel.lensBlur.parameters { plain[parameter] = DevelopSettings.neutral[parameter] }
        plain.lensBlurAreas = []
        plain.setPanel(.lensBlur, on: true)
        return plain
    }

    // MARK: Lens Blur Refine

    /// Opens Lens Blur's Refine: Masking's tools on Lens Blur's own Focus and Blur areas, with
    /// the Lens Blur refine panel and Done. The areas never show in Masking.
    func startLensBlurRefine() {
        guard assetID != nil else { return }
        if isMasking, maskScope == .lensBlur { return }
        if isMasking { isMasking = false }
        maskScope = .lensBlur
        selectedMaskID = nil
        selectedComponentID = nil
        isMasking = true
    }

    func finishLensBlurRefine() {
        guard maskScope == .lensBlur else { return }
        isMasking = false
    }

    /// The Focus or Blur area, if the photo has it.
    func lensBlurArea(_ role: DevelopSettings.LensBlurRole) -> Mask? {
        settings.lensBlurAreas.first { $0.lensBlurRole == role }
    }

    /// Adds (or subtracts) a part to Lens Blur's Focus or Blur area, making the area with its
    /// first part. Drawn kinds wait for a drag on the photo, as in Masking.
    func addLensBlurPart(_ kind: MaskComponent.Kind, to role: DevelopSettings.LensBlurRole, mode: MaskComponent.Mode) {
        guard assetID != nil, maskScope == .lensBlur else { return }
        let existing = lensBlurArea(role)
        guard existing != nil || mode == .add else { return }
        selectedMaskID = existing?.id
        selectedComponentID = nil
        let tool = MaskTool(kind: kind, mode: mode, newMask: existing == nil, role: role)
        if kind.isDrawn {
            maskTool = tool
        } else {
            insert(MaskComponent(Self.lensBlurShape(kind), mode: mode), tool: tool)
        }
    }

    /// A new part's start in Lens Blur's Refine: a person whole (hair and clothes too, not only
    /// skin) and AI selections with a tight edge and Fine Edges, since the edge between sharp and
    /// blurred is what shows (Rosh, Nov 16, 2026: Select People selected only skin).
    private static func lensBlurShape(_ kind: MaskComponent.Kind) -> MaskComponent.Shape {
        switch kind {
        case .people: return .people(DevelopSettings.PeopleSelection(parts: [.entirePerson], feather: 3, fineEdges: true))
        case .subject: return .subject(DevelopSettings.Selection(feather: 3, fineEdges: true))
        default: return defaultShape(kind)
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
        case .color: return .color(DevelopSettings.ColorRange())
        case .depth: return .depth(DevelopSettings.DepthRange())
        case .sky: return .sky(DevelopSettings.SkySelection())
        case .subject: return .subject(DevelopSettings.Selection())
        case .background: return .subject(DevelopSettings.Selection(background: true))
        case .object: return .subject(DevelopSettings.Selection(box: .init(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
        case .people: return .people(DevelopSettings.PeopleSelection())
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
        if case .people = component.shape { findPeople(reportNone: true) }
        if case .sky = component.shape { checkSky() }
        if tool.newMask || selectedMask == nil {
            component.mode = .add
            var mask = Mask(name: settings.nextMaskName(), components: [component])
            var step = "New Mask: \(component.kind.title)"
            if maskScope == .lensBlur {
                // A Lens Blur area: Focus or Blur, and Lens Blur on with it.
                let role = tool.role ?? .focus
                mask.name = role.title
                mask.lensBlurRole = role
                settings[.lensBlurApply] = 1
                step = "Lens Blur \(role.title): \(component.kind.title)"
            }
            editedMasks.append(mask)
            selectedMaskID = mask.id
            selectedComponentID = component.id
            changed(step: step)
        } else if let index = maskIndex(selectedMaskID) {
            editedMasks[index].components.append(component)
            selectedComponentID = component.id
            let verb = component.mode == .add ? "Add" : component.mode == .subtract ? "Subtract" : "Intersect"
            changed(step: "\(verb) \(component.kind.title): \(editedMasks[index].name)")
        }
    }

    /// Changes a part of the selected mask, while dragging its handles or from the panel.
    /// `step` names the history step (default "Edit Mask n").
    func updateComponent(_ component: MaskComponent, step: String? = nil) {
        guard let index = maskIndex(selectedMaskID),
              let part = editedMasks[index].components.firstIndex(where: { $0.id == component.id }),
              editedMasks[index].components[part] != component else { return }
        editedMasks[index].components[part] = component
        changed(step: step ?? "Edit \(editedMasks[index].name)")
    }

    /// Color Range: picks the color in `box` (top-left fractions of the upright, uncropped
    /// photo; a click is an empty box at the point). With the Color Range tool ready it makes the
    /// part; with a Color Range part selected it replaces its colors, or adds one when `adding`
    /// (⇧-click), as in Lightroom. The color is read in the background, from the photo the mask
    /// is found on.
    func pickColorRange(in box: DevelopSettings.MaskRect, adding: Bool) {
        let sharp = wantsFullResolution ? fullSession : nil
        guard let session = sharp ?? self.session, let assetID else { return }
        let target = maskTool == nil ? selectedComponentID : nil
        if target != nil, adding, case .color(let range) = selectedComponent?.shape,
           range.samples.count >= DevelopSettings.ColorRange.maxSamples {
            maskMessage = "A Color Range holds up to five colors. ⌥-click one on the photo to remove it first."
            return
        }
        let pickQueue = sharp != nil ? fullQueue : queue
        let settings = self.settings
        pickQueue.async {
            let sample = session.colorSample(in: box, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, let sample else { return }
                    if target == nil, self.maskTool?.kind == .color {
                        self.finishDrawing(.color(DevelopSettings.ColorRange(samples: [sample])))
                        return
                    }
                    guard let target, var component = self.selectedComponent, component.id == target,
                          case .color(var range) = component.shape,
                          let mask = self.selectedMask else { return }
                    self.maskMessage = nil
                    if adding {
                        guard range.samples.count < DevelopSettings.ColorRange.maxSamples else { return }
                        range.samples.append(sample)
                    } else {
                        range.samples = [sample]
                    }
                    component.shape = .color(range)
                    self.updateComponent(component, step: "\(adding ? "Add Color" : "Pick Color"): \(mask.name)")
                }
            }
        }
    }

    /// Depth Range: sets the selected part's range from the depths in `box` (top-left fractions
    /// of the upright, uncropped photo; a click is an empty box at the point): a click takes the
    /// depth there, a drag the depths under it, and ⇧ (`adding`) widens the range to take them in,
    /// as Lightroom's Depth Range picker does. Read in the background; the first pick on a photo
    /// waits for its depth (under a second).
    func pickDepthRange(in box: DevelopSettings.MaskRect, area: Bool, adding: Bool) {
        guard let session, let assetID, let target = selectedComponentID,
              case .depth = selectedComponent?.shape else { return }
        guard DepthMap.isInstalled else {
            maskMessage = "Depth Range needs the depth model: click Download in the Depth Range settings below."
            return
        }
        let settings = self.settings
        queue.async {
            let depths = session.depths(in: box, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, var component = self.selectedComponent, component.id == target,
                          case .depth(let range) = component.shape, let mask = self.selectedMask else { return }
                    guard let depths, let picked = range.picking(depths, area: area, adding: adding) else {
                        self.maskMessage = DepthMap.failure ?? "No depth was found for this photo."
                        return
                    }
                    self.maskMessage = nil
                    component.shape = .depth(picked)
                    self.updateComponent(component, step: "\(adding ? "Add Depth" : "Pick Depth"): \(mask.name)")
                }
            }
        }
    }

    // MARK: Lens Blur

    /// Lens Blur's Apply. Turned on with the Focal Range at its default, it first focuses on the
    /// subject, as Lightroom's Apply does (one history step either way).
    func setLensBlurApplied(_ on: Bool) {
        guard assetID != nil else { return }
        let atDefault = settings[.lensBlurFocusNear] == DevelopSettings.Parameter.lensBlurFocusNear.defaultValue
            && settings[.lensBlurFocusFar] == DevelopSettings.Parameter.lensBlurFocusFar.defaultValue
        setValues([.lensBlurApply: on ? 1 : 0], step: on ? "Lens Blur: Apply" : "Lens Blur: Off")
        if on, atDefault { focusLensBlurOnSubject() }
    }

    /// Lens Blur's Subject focus: the Focal Range from the depths under the subject Select Subject
    /// finds. Read in the background (the first time on a photo it finds the depth, then the
    /// subject, in about a second).
    func focusLensBlurOnSubject() {
        guard let session, let assetID else { return }
        guard DepthMap.isInstalled else {
            lensBlurMessage = "Lens Blur needs the depth model: click Download in the Lens Blur panel."
            return
        }
        lensBlurMessage = nil
        let settings = self.settings
        // Asked in the mode: its answer is dropped if the mode was closed (Cancel) meanwhile.
        let inMode = isLensBlurring
        queue.async {
            let depths = session.subjectDepths(settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, !inMode || self.isLensBlurring else { return }
                    guard let depths, let range = LensBlur.focalRange(for: depths) else {
                        self.lensBlurMessage = DepthMap.failure
                            ?? "No subject found. Click the focus picker, then the part of the photo to keep sharp."
                        return
                    }
                    self.setValues([.lensBlurFocusNear: range.near, .lensBlurFocusFar: range.far],
                                   step: "Lens Blur: Subject Focus")
                }
            }
        }
    }

    /// Lens Blur's focus picker: the Focal Range from the depths around `point` (0...1 from the
    /// top left of the cropped photo). The picker stays out, so another click moves the focus.
    func pickLensFocus(at point: CGPoint) {
        guard let session, let assetID else { return }
        guard DepthMap.isInstalled else {
            pickerMessage = "Lens Blur needs the depth model: click Download in the Lens Blur panel."
            return
        }
        let settings = self.settings
        queue.async {
            let depths = session.focusDepths(at: point, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, self.picker == .lensFocus else { return }
                    guard let depths, let range = LensBlur.focalRange(for: depths) else {
                        self.pickerMessage = DepthMap.failure ?? "No depth was found for this photo."
                        return
                    }
                    self.pickerMessage = nil
                    var values: [DevelopSettings.Parameter: Double] = [.lensBlurFocusNear: range.near,
                                                                        .lensBlurFocusFar: range.far]
                    if self.settings[.lensBlurApply] < 0.5 { values[.lensBlurApply] = 1 }
                    self.setValues(values, step: "Lens Blur: Focus")
                }
            }
        }
    }

    /// Select Sky: finds the depth in the background and says so in the panel when there is no
    /// sky (no far part of the photo reaches its top edge).
    func checkSky() {
        guard let session, DepthMap.isInstalled else { return }
        let settings = self.settings
        let assetID = self.assetID
        queue.async {
            let found = session.findsSky(settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID, found == false else { return }
                    self.maskMessage = "No sky found: no far part of this photo reaches its top edge. "
                        + "Try Color Range or a Linear Gradient."
                }
            }
        }
    }

    /// Color Range: takes pick `index` out of the selected part (⌥-click on the photo, or the
    /// swatch's menu in the panel).
    func removeColorSample(_ index: Int) {
        guard var component = selectedComponent, case .color(var range) = component.shape,
              range.samples.indices.contains(index), let mask = selectedMask else { return }
        range.samples.remove(at: index)
        component.shape = .color(range)
        maskMessage = nil
        updateComponent(component, step: "Remove Color: \(mask.name)")
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
                    if selection.background {
                        self.maskMessage = "No subject stands out in this photo, so there is no background to tell apart. "
                            + "Try Color Range, a Linear Gradient or a Brush."
                    } else {
                        self.maskMessage = selection.box == nil
                            ? "No subject stands out in this photo. Try Select Object and drag a box around what you want."
                            : "Nothing found in that box. Try a box that fits closer around the object."
                    }
                }
            }
        }
    }

    /// Runs Select People's Vision search in the background for the panel's person list, and
    /// says so when it finds no one.
    func findPeople(reportNone: Bool = false) {
        guard let session else { return }
        if let peopleFaces {
            if reportNone, peopleFaces.isEmpty { maskMessage = Self.noPeopleMessage }
            return
        }
        let settings = self.settings
        let assetID = self.assetID
        queue.async {
            _ = PeopleParts.isAvailable  // loads the built-in model once, so the panel can say whether it runs
            let faces = session.peopleFaces(settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.assetID == assetID else { return }
                    self.peopleFaces = faces
                    if reportNone, faces.isEmpty { self.maskMessage = Self.noPeopleMessage }
                }
            }
        }
    }

    static let noPeopleMessage = "No people found. Try Select Subject or a Brush."

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
        editedMasks[index][parameter] = value
        let mask = editedMasks[index]
        let formatted = parameter == .exposure ? String(format: "%+.2f", mask[parameter])
            : String(format: "%+.0f", mask[parameter])
        changed(step: "\(mask.name) \(parameter.label == "Temp" ? "Temperature" : parameter.label) \(formatted)")
    }

    /// Changes one mask as one history step named `step` (with the mask's name in front).
    func updateMask(_ id: UUID, step: String, _ change: (inout Mask) -> Void) {
        guard let index = maskIndex(id) else { return }
        let before = editedMasks[index]
        change(&editedMasks[index])
        guard editedMasks[index] != before else { return }
        changed(step: "\(editedMasks[index].name) \(step)")
    }

    func setMaskAmount(_ amount: Double) {
        guard let index = maskIndex(selectedMaskID) else { return }
        editedMasks[index].amount = min(200, max(0, amount))
        changed(step: "\(editedMasks[index].name) Amount \(Int(editedMasks[index].amount.rounded()))%")
    }

    func resetMaskSliders() {
        guard let index = maskIndex(selectedMaskID) else { return }
        editedMasks[index].resetAdjustments()
        changed(step: "Reset \(editedMasks[index].name) Sliders")
    }

    func toggleHidden(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        editedMasks[index].isHidden.toggle()
        changed(step: "\(editedMasks[index].isHidden ? "Hide" : "Show") \(editedMasks[index].name)")
    }

    func invertMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        editedMasks[index].inverted.toggle()
        changed(step: "Invert \(editedMasks[index].name)")
    }

    func renameMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = maskIndex(id), !trimmed.isEmpty, trimmed != editedMasks[index].name else { return }
        editedMasks[index].name = trimmed
        changed(step: "Rename Mask: \(trimmed)")
    }

    func duplicateMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        var copy = editedMasks[index]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        copy.components = copy.components.map { component in
            var fresh = component
            fresh.id = UUID()
            return fresh
        }
        editedMasks.insert(copy, at: index + 1)
        selectedMaskID = copy.id
        selectedComponentID = nil
        changed(step: "Duplicate \(editedMasks[index].name)")
    }

    func deleteMask(_ id: UUID) {
        guard let index = maskIndex(id) else { return }
        let name = editedMasks[index].name
        editedMasks.remove(at: index)
        if selectedMaskID == id {
            selectedMaskID = editedMasks.last?.id
            selectedComponentID = nil
        }
        changed(step: "Delete \(name)")
        DeleteFeedback.play(.remove)
    }

    func deleteAllMasks() {
        guard !editedMasks.isEmpty else { return }
        editedMasks = []
        selectedMaskID = nil
        selectedComponentID = nil
        maskTool = nil
        changed(step: "Delete All Masks")
        DeleteFeedback.play(.remove)
    }

    /// Removes a part; the whole mask goes with its last part.
    func deleteComponent(_ id: UUID, in maskID: UUID) {
        guard let index = maskIndex(maskID) else { return }
        if editedMasks[index].components.count <= 1 { return deleteMask(maskID) }
        editedMasks[index].components.removeAll { $0.id == id }
        // The first part always adds.
        editedMasks[index].components[0].mode = .add
        if selectedComponentID == id { selectedComponentID = nil }
        changed(step: "Delete Part of \(editedMasks[index].name)")
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
              let part = editedMasks[index].components.firstIndex(where: { $0.id == id }), part > 0 else { return }
        editedMasks[index].components[part].mode = mode
        changed(step: "Edit \(editedMasks[index].name)")
    }

    func invertComponent(_ id: UUID, in maskID: UUID) {
        guard let index = maskIndex(maskID),
              let part = editedMasks[index].components.firstIndex(where: { $0.id == id }) else { return }
        editedMasks[index].components[part].inverted.toggle()
        changed(step: "Invert Part of \(editedMasks[index].name)")
    }
}

/// How many renders ran and how long they took, for the agent render check (AT-050d).
struct RenderTally: Sendable {
    var count = 0
    var seconds = 0.0
    var longest = 0.0
    /// Refreshes dropped because a newer edit of the photo came first.
    var skipped = 0

    mutating func record(_ duration: Double) {
        count += 1
        seconds += duration
        longest = max(longest, duration)
    }

    var meanMS: Double { count == 0 ? 0 : seconds * 1000 / Double(count) }
}
