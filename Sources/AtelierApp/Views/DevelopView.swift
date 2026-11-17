import AppKit
import AtelierCore
import SwiftUI

/// The photo being developed, rendered live from the original, with optional before/after views.
struct DevelopImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @ObservedObject var develop: DevelopController
    /// The original has taken over 0.6 s to open, so the spinner shows over the photo.
    @State private var slowLoad = false
    @AppStorage(DevelopFrameHUD.preference) private var showFrameHUD = false
    /// With the Filmstrip showing, ⌃Tab's "photos" outline goes on the Filmstrip instead.
    @AppStorage(Filmstrip.visibleKey) private var filmstripVisible = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: theme.surround)
                if let image = develop.image {
                    if develop.isCropping {
                        CropEditorView(develop: develop, image: image)
                    } else if develop.isAIOpen {
                        AIBrushView(ai: model.ai, image: image, assetID: develop.assetID)
                    } else if develop.isMasking {
                        MaskEditorView(develop: develop, image: image, display: develop.displayImage ?? image,
                                       pixelSize: pixelSize, zoom: model.zoomState,
                                       onReport: onZoomReport)
                    } else if develop.isRemoving {
                        SpotEditorView(develop: develop, image: image, display: develop.displayImage ?? image,
                                       pixelSize: pixelSize, zoom: model.zoomState, onReport: onZoomReport)
                    } else if develop.isGuiding {
                        GuidedUprightView(develop: develop, image: image)
                    } else if develop.showingBefore || develop.compareMode == .off {
                        ZoomableImageView(image: develop.displayImage ?? image,
                                          pixelSize: pixelSize,
                                          zoom: model.zoomState,
                                          onReport: onZoomReport,
                                          menu: { model.photoMenu(includeZoom: true) },
                                          onPick: photoPick,
                                          onPickDrag: photoDrag,
                                          feed: develop.photoFeed)
                        if let picker = develop.picker {
                            PickerHint(text: develop.pickerMessage ?? picker.hint, isWarning: develop.pickerMessage != nil)
                        }
                    } else if develop.compareMode == .sideBySide {
                        // Both panes share the zoom and stay on the same spot, as in Lightroom.
                        HStack(spacing: 12) {
                            ComparePane(image: develop.displayBeforeImage, label: "Before", pixelSize: pixelSize,
                                        zoom: model.zoomState, onReport: onZoomReport,
                                        menu: { model.photoMenu(includeZoom: true) })
                            // Live slider frames go straight onto the After pane, as on the
                            // single photo view (`PhotoFeed`).
                            ComparePane(image: develop.displayImage ?? image, label: "After", pixelSize: pixelSize,
                                        zoom: model.zoomState, onReport: onZoomReport,
                                        menu: { model.photoMenu(includeZoom: true) }, feed: develop.photoFeed)
                        }
                        .padding(.horizontal, 8)
                    } else {
                        SliderCompareView(before: develop.displayBeforeImage, after: develop.displayImage ?? image,
                                          pixelSize: pixelSize, zoom: model.zoomState, onReport: onZoomReport,
                                          menu: { model.photoMenu(includeZoom: true) },
                                          position: $develop.sliderPosition, feed: develop.photoFeed)
                    }
                }
                // Only while what's on screen isn't the photo yet: nothing, or a thumbnail or the
                // previous photo for a while (a slow NAS original). Over the photo's own preview
                // the editable copy decodes quietly; the photo is already there (Rosh, Oct 31 and
                // Nov 9, 2026).
                if develop.isLoading, develop.image == nil || (develop.showsStandIn && slowLoad) {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let message = develop.errorMessage {
                    Text(message)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if develop.showingBefore {
                    Badge(text: "Before").padding(14)
                } else if develop.isLensBlurring {
                    Badge(text: "Lens Blur").padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showFrameHUD, !develop.isCropping, !develop.isAIOpen,
                   !develop.isGuiding, develop.image != nil {
                    DevelopFrameHUDOverlay(hud: develop.frameHUD, assetID: develop.assetID)
                        .frame(width: 264, height: 116)
                        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 7))
                        .allowsHitTesting(false)
                        .padding(12)
                }
            }
            .areaFocusFlash(.photo, enabled: !filmstripVisible)
            Divider()
            // Icons with tooltips at every width. Narrow columns drop the hint, then fold the
            // zoom buttons into a menu, so the bar always fits.
            AdaptiveControlBar(sizingKey: develop.compareMode == .slider) {
                bottomBar(showHint: true, compactZoom: false)
            } compact: {
                bottomBar(showHint: false, compactZoom: false)
            } minimum: {
                bottomBar(showHint: false, compactZoom: true)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { develop.open(model.focusedID) }
        .task(id: develop.isLoading ? develop.assetID : nil) {
            slowLoad = false
            guard develop.isLoading else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, develop.isLoading { slowLoad = true }
        }
        .onChange(of: develop.compareMode) { old, new in compareModeChanged(from: old, to: new) }
        .onReceive(model.zoomState.$level) { level in
            if level == .fit, develop.wantsFullResolution { develop.wantsFullResolution = false }
        }
        .onChange(of: CropOfPhoto(assetID: develop.assetID, crop: develop.crop)) { old, new in
            // The zoomed spot follows the photo through a crop (the crop tool, undo, a preset).
            guard old.assetID == new.assetID, let size = develop.sourceSize else { return }
            model.zoomState.viewport.recrop(from: old.crop, to: new.crop, sourceSize: size)
        }
    }

    private struct CropOfPhoto: Equatable {
        var assetID: Int64?
        var crop: DevelopSettings.Crop
    }

    /// The zoom and spot from before a compare view opened, brought back when it closes.
    private struct ZoomBeforeCompare {
        var level: ZoomLevel
        var center: CGPoint?
        var assetID: Int64?
    }
    @State private var zoomBeforeCompare: ZoomBeforeCompare?

    /// The compare views open at Fit; closing them returns to the zoom and spot you left, as
    /// long as it's the same photo. Switching between them keeps the spot.
    private func compareModeChanged(from old: CompareMode, to new: CompareMode) {
        let zoom = model.zoomState
        let center = zoom.viewport.visible.map { CGPoint(x: $0.midX, y: $0.midY) }
        if old == .off {
            zoomBeforeCompare = ZoomBeforeCompare(level: zoom.level, center: center, assetID: develop.assetID)
            zoom.level = .fit
        } else if new == .off {
            guard let saved = zoomBeforeCompare else { return }
            zoomBeforeCompare = nil
            guard saved.assetID == develop.assetID else { return }
            // The photo view for Off already exists by now, unsized; it takes the spot once
            // it has a size, so the zoom doesn't land on the photo's top-left corner.
            zoom.restoreCenter = saved.center
            if zoom.level != saved.level { zoom.level = saved.level } else { zoom.objectWillChange.send() }
        } else {
            zoom.restoreCenter = center
            zoom.objectWillChange.send()
        }
    }

    /// What a click on the photo does while a color picker is out.
    private var photoPick: ((CGPoint) -> Void)? {
        switch develop.picker {
        case .whiteBalance: return { point in develop.findWhiteBalance(at: point) }
        case .fringe: return { point in develop.pickFringe(at: point) }
        case .gradeColor: return { point in develop.pickGradeColor(at: point) }
        case .pointColor: return { point in develop.pickPointColor(at: point) }
        case .lensFocus: return { point in develop.pickLensFocus(at: point) }
        case .targetCurve, .targetColor, .targetGray, nil: return nil
        }
    }

    /// What a drag on the photo does while the Targeted Adjustment Tool is out.
    private var photoDrag: ((PhotoDrag) -> Void)? {
        guard develop.picker?.isTargeted == true else { return nil }
        return { drag in develop.targetedDrag(drag) }
    }

    private func onZoomReport(_ report: ZoomReport) {
        if model.zoomReport != report { model.zoomReport = report }
        // Scroll views report after layout. A late report from a zoomed pane must not
        // request full-resolution work after the shared zoom has already returned to Fit.
        let wantsFullResolution = model.zoomState.level != .fit && report.isZoomedPastFit
        if develop.wantsFullResolution != wantsFullResolution {
            develop.wantsFullResolution = wantsFullResolution
        }
    }

    private var pixelSize: CGSize? {
        guard let width = model.detail?.asset.width, let height = model.detail?.asset.height else { return nil }
        return develop.croppedPixelSize(assetSize: CGSize(width: width, height: height))
    }

    private var compareDisabled: Bool {
        develop.isCropping || develop.isAIOpen || develop.isMasking || develop.isGuiding || develop.isRemoving
    }

    private func bottomBar(showHint: Bool, compactZoom: Bool) -> some View {
        HStack(spacing: 10) {
            // The Lens Blur mode has its own Before, in its bar; only zoom here.
            if !develop.isLensBlurring {
                comparePicker
                    .disabled(compareDisabled)
            }
            if showHint, develop.compareMode == .slider, !develop.isLensBlurring {
                Text("Drag the divider to compare").foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 8)
            ZoomControls(zoom: model.zoomState, compact: compactZoom)
                .disabled(develop.isCropping || develop.isAIOpen || develop.isGuiding)
        }
    }

    /// Before and After as icons, each with a tooltip naming it and the key that cycles them.
    private var comparePicker: some View {
        let key = KeyBindings.display(KeyBindings.key(for: .compareMode))
        return IconSegmentedControl(segments: CompareMode.allCases.map { mode in
            IconSegmentedControl<CompareMode>.Segment(value: mode, symbol: mode.symbol, text: mode.label,
                                         help: "Before and After: \(mode.label) (\(key) cycles)")
        }, selection: $develop.compareMode)
        .fixedSize()
    }
}

/// What to click while a color picker is out, at the top of the photo; every picker uses it.
private struct PickerHint: View {
    let text: String
    var isWarning = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isWarning ? Color.orange : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .allowsHitTesting(false)
    }
}

/// The eyedropper button that takes a color picker out or puts it away; every picker uses it.
struct PickerButton: View {
    @ObservedObject var develop: DevelopController
    let kind: DevelopController.PhotoPicker
    /// The eyedropper, or a target for the Targeted Adjustment Tool.
    var symbol = "eyedropper"
    let help: String
    /// Runs before the picker comes out, to set what it picks for.
    var willPick: () -> Void = {}

    var body: some View {
        Button {
            if develop.picker == kind {
                develop.picker = nil
            } else {
                willPick()
                develop.picker = kind
            }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(develop.picker == kind ? Color.accentColor : Color.secondary)
        .disabled(develop.assetID == nil)
        .help(help)
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

struct ComparePane: View {
    let image: NSImage?
    let label: String
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?
    /// Set on the After pane: live slider frames are drawn into it (`PhotoFeed`).
    var feed: PhotoFeed? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                ZoomableImageView(image: image, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: menu,
                                  feed: feed)
            } else {
                BeforeLoadingView()
            }
            Badge(text: label).padding(8).allowsHitTesting(false)
        }
    }
}

private struct BeforeLoadingView: View {
    var body: some View {
        ProgressView()
            .accessibilityLabel("Loading Before image")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The edited photo with the original revealed to the left of a draggable divider. Both zoom
/// and pan together: drag the photo to move around, drag the divider to compare.
struct SliderCompareView: View {
    @Environment(\.theme) private var theme
    let before: NSImage?
    let after: NSImage
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?
    @Binding var position: Double
    /// Live slider frames are drawn into the After photo, under the Before one (`PhotoFeed`).
    var feed: PhotoFeed? = nil

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dividerX = size.width * position
            ZStack(alignment: .topLeading) {
                ZoomableImageView(image: after, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: menu,
                                  feed: feed)
                if let before {
                    ZoomableImageView(image: before, pixelSize: pixelSize, zoom: zoom, visibleWidth: CGFloat(position),
                                      onReport: onReport, menu: menu)
                } else if dividerX > 0 {
                    BeforeLoadingView()
                        .frame(width: dividerX, height: size.height)
                        .background(Color(nsColor: theme.surround.withAlphaComponent(1)))
                        .clipped()
                        .allowsHitTesting(false)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: size.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: dividerX, y: size.height / 2)
                    .allowsHitTesting(false)
                // A strip wider than the line, so the divider is easy to grab.
                Color.clear
                    .frame(width: 20, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("slider")).onChanged { value in
                        guard size.width > 0 else { return }
                        position = min(1, max(0, value.location.x / size.width))
                    })
                    .cursor(.columnResize)
                    .position(x: dividerX, y: size.height / 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(Color.black))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: dividerX, y: size.height / 2)
                    .allowsHitTesting(false)
                Badge(text: "Before")
                    .fixedSize()
                    .position(x: 52, y: 22)
                    .opacity(position > 0.12 ? 1 : 0)
                    .allowsHitTesting(false)
                Badge(text: "After")
                    .fixedSize()
                    .position(x: size.width - 46, y: 22)
                    .opacity(position < 0.88 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named("slider"))
        }
    }
}

/// The Develop panels in the right column: collapsible like Lightroom's, with solo mode.
struct DevelopPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController
    @AppStorage(Preferences.expandedPanels) private var expandedList: String
    @AppStorage(Preferences.soloMode) private var soloMode: Bool

    private var expanded: Set<String> {
        Set(expandedList.split(separator: ",").map(String.init))
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { open in
            var set = expanded
            if open {
                // Solo mode keeps one adjustment panel open; the histogram stays independent.
                if soloMode, id != "histogram" { set = set.filter { $0 == "histogram" } }
                set.insert(id)
            } else {
                set.remove(id)
            }
            expandedList = set.sorted().joined(separator: ",")
        })
    }

    private func groups(in panel: DevelopSettings.Panel) -> [(String, [DevelopSettings.Parameter])] {
        var result: [(String, [DevelopSettings.Parameter])] = []
        for parameter in panel.parameters {
            if result.last?.0 == parameter.group {
                result[result.count - 1].1.append(parameter)
            } else {
                result.append((parameter.group, [parameter]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
            ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    // The Lens Blur mode is an inline app: its own controls only. Develop's
                    // histogram (which drags Basic's sliders) and tool strip stay in Develop.
                    if !develop.isLensBlurring {
                        PanelSection(title: "Histogram", isExpanded: isExpanded("histogram"), soloMode: $soloMode,
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            HistogramView(develop: develop)
                        }
                        ToolStrip(develop: develop)
                    }
                    if develop.isCropping {
                        PanelSection(title: "Crop & Straighten", isExpanded: .constant(true), soloMode: $soloMode,
                                     isModified: develop.settings.crop != nil, reset: { develop.setCrop(Crop()) },
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            CropPanel(develop: develop)
                        }
                    }
                    if develop.isRemoving {
                        PanelSection(title: "Remove", isExpanded: .constant(true), soloMode: $soloMode,
                                     isModified: !develop.spots.isEmpty, reset: { develop.deleteAllSpots() },
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            RemovePanel(develop: develop)
                        }
                    }
                    // Lens Blur's Refine shows inside the Lens Blur panel, where its button is.
                    if develop.isMasking, develop.maskScope == .look {
                        PanelSection(title: "Masking", isExpanded: .constant(true), soloMode: $soloMode,
                                     isModified: !develop.masks.isEmpty, reset: { develop.deleteAllMasks() },
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            MasksPanel(develop: develop)
                        }
                    }
                    if develop.isAIOpen {
                        PanelSection(title: "AI", isExpanded: .constant(true), soloMode: $soloMode,
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            AIPanel(ai: model.ai)
                        }
                    }
                    if develop.isLensBlurring {
                        // The Lens Blur mode: its controls in place of Develop's panels (AT-074).
                        PanelSection(title: "Lens Blur", isExpanded: .constant(true), soloMode: $soloMode,
                                     isModified: develop.isModified(.lensBlur), reset: { develop.reset(.lensBlur) },
                                     isOn: Binding(get: { develop.isPanelOn(.lensBlur) },
                                                   set: { develop.setPanelOn(.lensBlur, $0) }),
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            LensBlurPanel(develop: develop)
                        }
                    }
                    // Lens Blur is edited only in its mode (Photo > Lens Blur…, the tool strip).
                    ForEach(develop.isLensBlurring ? [DevelopSettings.Panel]() : DevelopSettings.Panel.allCases.filter { $0 != .lensBlur },
                            id: \.self) { panel in
                        PanelSection(title: panel.title, isExpanded: isExpanded(panel.rawValue), soloMode: $soloMode,
                                     isModified: develop.isModified(panel), reset: { develop.reset(panel) },
                                     isOn: panel.hasSwitch
                                        ? Binding(get: { develop.isPanelOn(panel) }, set: { develop.setPanelOn(panel, $0) })
                                        : nil,
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            switch panel {
                            case .basic:
                                VStack(alignment: .leading, spacing: 7) {
                                    TreatmentRow(develop: develop)
                                    ProfileRow(develop: develop)
                                    ParameterGroups(panel: panel, develop: develop)
                                }
                            case .lensCorrections:
                                LensCorrectionsPanel(develop: develop)
                            case .transform:
                                TransformPanel(develop: develop)
                            case .toneCurve:
                                ToneCurvePanel(develop: develop)
                            case .hsl:
                                HSLPanel(develop: develop)
                            case .colorGrading:
                                ColorGradingPanel(develop: develop)
                            case .effects:
                                EffectsPanel(develop: develop)
                            default:
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(groups(in: panel), id: \.0) { group in
                                        GroupHeading(title: group.0) { develop.reset(group: group.0, parameters: group.1) }
                                        ForEach(group.1, id: \.self) { parameter in
                                            ParameterSlider(parameter: parameter, develop: develop)
                                            if parameter == .aiDenoise { AIDenoiseStatus(develop: develop) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // Lay everything out at exactly the panel's measured width so nothing spills past it.
                .frame(width: geometry.size.width)
                // Tab order follows where controls sit in the panel, whatever the scroll.
                .coordinateSpace(.named(keyboardFocusSpace))
            }
            // A slider that gets keyboard focus (Tab, ⌃Tab) scrolls itself into view.
            .environment(\.keyboardScroll, scroll)
            }
            }
            Divider()
            if develop.isLensBlurring {
                LensBlurModeBar(develop: develop)
            } else {
                developBar
            }
        }
        .disabled(develop.assetID == nil)
    }

    private var developBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Copy") { develop.copySettings() }
                    .help("Copy this photo's settings (⇧⌘C)")
                Button("Paste") { develop.pasteSettings() }
                    .disabled(develop.clipboard == nil)
                    .help("Paste settings onto this photo (⇧⌘V)")
                Spacer()
                Toggle("Before", isOn: $develop.showingBefore)
                    .toggleStyle(.button)
                    .help("Show the photo without edits (\\)")
                Button("Reset") { develop.resetAll() }
                    .help("Clear all edits on this photo (⇧⌘R)")
            }
            Text("Edits save automatically and never change the original. Double-click a slider's name to reset it; click its value to type one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }

    private func expandAll() {
        soloMode = false
        expandedList = (["histogram"] + DevelopSettings.Panel.allCases.filter { $0 != .lensBlur }.map(\.rawValue))
            .joined(separator: ",")
    }

    private func collapseAll() {
        expandedList = ""
    }
}

/// Lightroom's histogram: RGB from the current render, with clipping triangles in the top corners
/// (click one to show that clipping on the photo, J for both) and the tone regions under the
/// pointer: hover to see which slider a region is, drag left or right to change it, double-click
/// to reset it. The photo's ISO, focal length, aperture and shutter speed sit underneath.
private struct HistogramView: View {
    @ObservedObject var develop: DevelopController
    @AppStorage(Preferences.showClipping) private var showClipping: Bool
    @State private var hovered: ToneRegion?
    /// The region being dragged and its slider's value when the drag began.
    @State private var drag: (region: ToneRegion, start: Double)?

    private var histogram: Histogram? { develop.histogram }
    private var active: ToneRegion? { drag?.region ?? hovered }

    var body: some View {
        MeasuresReader(develop.measures) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                graph(width: geometry.size.width)
            }
            .frame(height: 90)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if histogram == nil, develop.assetID != nil { ProgressView().controlSize(.small) }
            }
            .overlay(alignment: .topLeading) {
                triangle(shadows: true)
            }
            .overlay(alignment: .topTrailing) {
                triangle(shadows: false)
            }
            infoLine
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 14)
        }
    }

    private func graph(width: CGFloat) -> some View {
        HistogramGraph(histogram: nil, sink: develop.histogramSink, highlight: active?.span)
        .equatable()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = canAdjust ? ToneRegion.at(point.x / max(1, width)) : nil
            case .ended: hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard canAdjust else { return }
                    let current: (region: ToneRegion, start: Double)
                    if let drag {
                        current = drag
                    } else {
                        let region = ToneRegion.at(value.startLocation.x / max(1, width))
                        current = (region, develop.sliderValue(region.parameter))
                        drag = current
                    }
                    develop.setSlider(current.region.parameter,
                                      to: current.region.value(from: current.start, moved: value.translation.width / max(1, width)))
                }
                .onEnded { _ in drag = nil }
        )
        // double-click only: nothing here or around it takes a single click, so no click waits.
        .onTapGesture(count: 2, coordinateSpace: .local) { point in
            guard canAdjust else { return }
            develop.reset(ToneRegion.at(point.x / max(1, width)).parameter)
        }
        .cursor(.slide)
        .help("Drag a tone region left or right to change it: Blacks, Shadows, Exposure, Highlights or Whites. "
              + "Double-click a region to reset it.")
    }

    private var canAdjust: Bool { develop.assetID != nil && histogram != nil }

    /// What the line under the graph says: the region under the pointer and its value, or how
    /// the photo was taken, spread across the width as in Lightroom.
    @ViewBuilder
    private var infoLine: some View {
        if let active {
            Text("\(active.parameter.label)  \(active.format(develop.sliderValue(active.parameter)))")
                .foregroundStyle(.primary)
        } else {
            ShootingInfoLine(info: develop.shootingInfo)
        }
    }

    /// Lightroom's clipping triangle: dim when nothing clips, lit in the color of the clipped
    /// channels (white when all three clip). Click to show that clipping on the photo.
    private func triangle(shadows: Bool) -> some View {
        let share = shadows ? histogram?.shadowClipping : histogram?.highlightClipping
        let channels = shadows ? histogram?.shadowChannels : histogram?.highlightChannels
        let color = HistogramGraph.clipColor(channels)
        let isOn = shadows ? develop.showShadowClipping : develop.showHighlightClipping
        let percent = share.map { String(format: "%.1f%%", $0 * 100) }
        return HStack(spacing: 3) {
            if !shadows, showClipping, let share, share >= 0.005, let percent { clipText(percent) }
            Button {
                if shadows { develop.showShadowClipping.toggle() } else { develop.showHighlightClipping.toggle() }
            } label: {
                HistogramGraph.triangle(shadows: shadows, color: color)
                    .background(isOn ? Color.white.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn ? Color.white.opacity(0.7) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(develop.assetID == nil)
            .help(HistogramGraph.clipHelp(shadows: shadows, histogram: histogram)
                  + " Click to \(isOn ? "hide" : "show") it on the photo (J).")
            if shadows, showClipping, let share, share >= 0.005, let percent { clipText(percent) }
        }
        .padding(3)
    }

    private func clipText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
    }
}

/// The RGB graph itself, shared by Develop and the Library's right panel. `highlight` lights a
/// band of it (a tone region under the pointer), as a fraction of its width.
///
/// It shows one finished picture of the three channels (`HistogramPicture`). In Develop the
/// measure queue puts it on screen itself (`sink`, `HistogramSink`), so the graph keeps up with
/// the photo whatever the main thread is doing; elsewhere it is made here, once per histogram.
/// Equatable, so a redraw of the panel around it leaves the graph alone.
struct HistogramGraph: View, Equatable {
    let histogram: Histogram?
    var sink: HistogramSink? = nil
    var highlight: ClosedRange<CGFloat>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let highlight {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: geometry.size.width * (highlight.upperBound - highlight.lowerBound))
                        .offset(x: geometry.size.width * highlight.lowerBound)
                }
                if let sink {
                    HistogramLayerView(sink: sink)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                } else if let image = histogram.flatMap(Self.picture(for:)) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .accessibilityHidden(true)
    }

    nonisolated static func == (lhs: HistogramGraph, rhs: HistogramGraph) -> Bool {
        lhs.highlight == rhs.highlight && lhs.sink === rhs.sink
            && (lhs.sink != nil || lhs.histogram == rhs.histogram)
    }

    /// The last picture made here, for the histogram it shows.
    @MainActor private static var made: (histogram: Histogram, image: CGImage)?

    @MainActor private static func picture(for histogram: Histogram) -> CGImage? {
        if let made, made.histogram == histogram { return made.image }
        guard let image = HistogramPicture.make(histogram) else { return nil }
        made = (histogram, image)
        return image
    }

    /// Lightroom's clipping triangle color: dim when nothing clips, else the clipped channels'
    /// color (white when all three clip).
    static func clipColor(_ channels: [Double]?) -> Color {
        let clipped = (channels ?? [0, 0, 0]).map { $0 >= 0.0005 }
        guard clipped.contains(true) else { return Color.white.opacity(0.3) }
        return Color(red: clipped[0] ? 1 : 0.2, green: clipped[1] ? 1 : 0.2, blue: clipped[2] ? 1 : 0.2)
    }

    /// What a triangle's tooltip says: how much is pure black or white (what the overlay marks),
    /// or that only some channels clip (saturated colors, which keep their detail).
    static func clipHelp(shadows: Bool, histogram: Histogram?) -> String {
        let tone = shadows ? "black" : "white"
        let share = (shadows ? histogram?.shadowClipping : histogram?.highlightClipping) ?? 0
        let channels = (shadows ? histogram?.shadowChannels : histogram?.highlightChannels) ?? []
        if share > 0 {
            return String(format: "%.1f%% of the photo is pure \(tone) (clipped).", share * 100)
        }
        if channels.contains(where: { $0 >= 0.0005 }) {
            return "Nothing is pure \(tone), but some saturated colors have a channel at \(tone); the triangle's color shows which."
        }
        return "Nothing is pure \(tone)."
    }

    /// The triangle glyph, pointing into its corner.
    static func triangle(shadows: Bool, color: Color) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 7, weight: .bold))
            .rotationEffect(.degrees(shadows ? -45 : 45))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
    }
}

/// The histogram's tone regions, left to right, as in Lightroom: each is a Basic Tone slider.
private enum ToneRegion: CaseIterable {
    case blacks, shadows, exposure, highlights, whites

    var parameter: DevelopSettings.Parameter {
        switch self {
        case .blacks: return .blacks
        case .shadows: return .shadows
        case .exposure: return .exposure
        case .highlights: return .highlights
        case .whites: return .whites
        }
    }

    /// Where the region sits, as a fraction of the histogram's width.
    var span: ClosedRange<CGFloat> {
        switch self {
        case .blacks: return 0...0.12
        case .shadows: return 0.12...0.35
        case .exposure: return 0.35...0.65
        case .highlights: return 0.65...0.88
        case .whites: return 0.88...1
        }
    }

    static func at(_ fraction: CGFloat) -> ToneRegion {
        allCases.first { fraction < $0.span.upperBound } ?? .whites
    }

    /// A drag across the whole histogram moves the slider by half its range (5 stops of
    /// Exposure, 100 on the others), in the slider's own steps.
    func value(from start: Double, moved fraction: CGFloat) -> Double {
        let range = parameter.range
        let step = self == .exposure ? 0.01 : 1
        let raw = start + Double(fraction) * (range.upperBound - range.lowerBound) / 2
        return min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
    }

    func format(_ value: Double) -> String {
        if self == .exposure { return String(format: "%+.2f", value) }
        return value == 0 ? "0" : String(format: "%+.0f", value)
    }
}

struct ParameterSlider: View {
    let parameter: DevelopSettings.Parameter
    let develop: DevelopController
    /// Read here, when the panel builds the slider, not in `body`: SwiftUI runs `body` only when
    /// the view's stored values change, and `parameter` and `develop` never do, so a value read
    /// in `body` froze the knob (Rosh, Nov 10, 2026).
    private let shown: ParameterSliderState

    init(parameter: DevelopSettings.Parameter, develop: DevelopController) {
        self.parameter = parameter
        self.develop = develop
        shown = ParameterSliderState(parameter, develop)
    }

    /// Panels watch the controller and build their sliders again for every change; each slider
    /// compares what it shows and skips its row when that is unchanged, so a drag redraws the
    /// dragged slider rather than every slider in every open panel (AT-039 D2).
    var body: some View {
        ParameterSliderRow(parameter: parameter, develop: develop, shown: shown).equatable()
    }
}

/// What a `ParameterSlider` row shows; the row is drawn again only when this changes.
private struct ParameterSliderState: Equatable {
    let value: Double
    let range: ClosedRange<Double>
    let origin: Double
    let isRAW: Bool
    /// The hue a Color Grading Saturation track is tinted with.
    let tintHue: Double?

    @MainActor
    init(_ parameter: DevelopSettings.Parameter, _ develop: DevelopController) {
        value = develop.sliderValue(parameter)
        range = develop.sliderRange(parameter)
        origin = develop.sliderDefault(parameter)
        isRAW = develop.isRAW
        tintHue = DevelopSettings.GradeRegion.allCases.first(where: { $0.saturation == parameter }).map { develop.value($0.hue) }
    }
}

private struct ParameterSliderRow: View, Equatable {
    let parameter: DevelopSettings.Parameter
    let develop: DevelopController
    let shown: ParameterSliderState

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.parameter == b.parameter && a.develop === b.develop && a.shown == b.shown
    }

    private var binding: Binding<Double> {
        Binding(get: { develop.sliderValue(parameter) }, set: { develop.setSlider(parameter, to: $0) })
    }

    private func formatted(_ value: Double) -> String {
        switch parameter {
        case .temperature where !shown.isRAW: return value == 0 ? "0" : String(format: "%+.0f", value)
        case .temperature: return "\(Int(value.rounded())) K"
        case .exposure: return String(format: "%+.2f", value)
        case .sharpenRadius: return String(format: "%.1f", value)
        case .transformRotate: return value == 0 ? "0.0" : String(format: "%+.1f", value)
        default:
            if parameter.range.lowerBound >= 0 { return "\(Int(value.rounded()))" }
            return value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }

    var body: some View {
        let preview = SliderPreview(parameter: parameter)
        SliderRow(label: parameter.label, value: binding, range: shown.range, step: step,
                  origin: shown.origin, gradient: trackGradient,
                  logarithmic: parameter == .temperature && shown.isRAW,
                  format: formatted, valueWidth: parameter == .temperature ? 58 : 44,
                  reset: { develop.reset(parameter) },
                  auto: develop.canAuto(parameter) ? { develop.autoTone(only: parameter) } : nil,
                  trackHelp: preview?.hint ?? "",
                  onOption: preview.map { preview in { (held: Bool) in develop.sliderPreview = held ? preview : nil } })
    }

    private func hue(_ degrees: Double) -> Color {
        Color(hue: degrees.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.8, brightness: 0.9)
    }

    /// Colored tracks where Lightroom has them.
    private var trackGradient: [Color]? {
        if let pair = parameter.hslBand {
            let (channel, band) = pair
            let color = Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.95)
            switch channel {
            case .hue:
                return [Color(hue: ((band.hue - 30 + 360).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.85, brightness: 0.95),
                        color,
                        Color(hue: ((band.hue + 30).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.85, brightness: 0.95)]
            case .saturation: return [Color.gray, color]
            case .luminance: return [Color.black, color, Color.white]
            }
        }
        if let band = parameter.grayBand {
            return [Color.black, Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.95), Color.white]
        }
        if DevelopSettings.GradeRegion.allCases.contains(where: { $0.hue == parameter }) {
            return (0...6).map { Color(hue: Double($0) / 6, saturation: 0.8, brightness: 0.9) }
        }
        if let hue = shown.tintHue {
            return [Color.gray, Color(hue: hue / 360, saturation: 0.8, brightness: 0.9)]
        }
        switch parameter {
        case .temperature: return [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)]
        case .tint: return [Color(red: 0.3, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.85)]
        case .vibrance, .saturation: return [Color.gray, Color(red: 1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.6, blue: 1)]
        // Calibration, as Lightroom colors it: Hue runs from one neighbor to the other.
        case .calibrationShadowsTint: return [Color(red: 0.3, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.85)]
        case .calibrationRedHue: return [hue(330), hue(0), hue(30)]
        case .calibrationGreenHue: return [hue(80), hue(120), hue(170)]
        case .calibrationBlueHue: return [hue(195), hue(235), hue(275)]
        case .calibrationRedSat: return [Color.gray, hue(0)]
        case .calibrationGreenSat: return [Color.gray, hue(120)]
        case .calibrationBlueSat: return [Color.gray, hue(235)]
        default: return nil
        }
    }

    private var step: Double {
        switch parameter {
        case .temperature: return shown.isRAW ? 50 : 1
        case .exposure: return 0.05
        case .sharpenRadius, .transformRotate: return 0.1
        default: return 1
        }
    }
}

/// The one slider row every slider in Atelier uses: the name (double-click resets, Shift-double-
/// click sets Auto where there is one), a slim Lightroom-style track (⌥ while dragging shows the
/// slider's view where it has one), and the value (click it to type one).
/// Lightroom's tool strip under the histogram.
private struct ToolStrip: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(spacing: 14) {
            tool("crop", title: "Crop & Straighten (R)", active: develop.isCropping,
                 modified: develop.settings.crop != nil) {
                develop.isCropping.toggle()
            }
            tool("bandage", title: "Remove: Content-Aware, Heal and Clone spots (Q)", active: develop.isRemoving,
                 modified: !develop.spots.isEmpty) {
                develop.isRemoving.toggle()
            }
            tool("circle.dashed", title: "Masking: Linear Gradient, Radial Gradient, Brush, Luminance Range, Select Subject (⇧W)",
                 active: develop.isMasking, modified: !develop.masks.isEmpty) {
                develop.isMasking.toggle()
            }
            tool("wand.and.stars", title: "AI: Remove Object, Replace Background, Upscale", active: develop.isAIOpen,
                 modified: false) {
                develop.isAIOpen.toggle()
            }
            tool("camera.aperture", title: "Lens Blur: blur by depth, saved as a new photo (Photo > Lens Blur…)",
                 active: develop.isLensBlurring, modified: develop.value(.lensBlurApply) >= 0.5) {
                if develop.isLensBlurring { model.closeLensBlur() } else { model.openLensBlur() }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tool(_ symbol: String, title: String, active: Bool, modified: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 24)
                .background(active ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topTrailing) {
                    if modified { Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -2, y: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
