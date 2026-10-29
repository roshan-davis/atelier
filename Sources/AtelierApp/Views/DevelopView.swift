import AppKit
import AtelierCore
import SwiftUI

/// The photo being developed, rendered live from the original, with optional before/after views.
struct DevelopImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @ObservedObject var develop: DevelopController

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
                                       onReport: { report in
                                           if model.zoomReport != report { model.zoomReport = report }
                                           if develop.wantsFullResolution != report.isZoomedPastFit {
                                               develop.wantsFullResolution = report.isZoomedPastFit
                                           }
                                       })
                    } else if develop.isGuiding {
                        GuidedUprightView(develop: develop, image: image)
                    } else if develop.isPickingWhiteBalance {
                        WhiteBalancePickerView(develop: develop, image: image)
                    } else if develop.showingBefore || develop.compareMode == .off {
                        ZoomableImageView(image: develop.displayImage ?? image,
                                          pixelSize: pixelSize,
                                          zoom: model.zoomState,
                                          onReport: onZoomReport,
                                          menu: { model.photoMenu(includeZoom: true) },
                                          onPick: develop.isPickingFringe ? { (point: CGPoint) in develop.pickFringe(at: point) } : nil)
                        if develop.isPickingFringe {
                            FringePickerHint(develop: develop)
                        }
                    } else if develop.compareMode == .sideBySide {
                        // Both panes share the zoom and stay on the same spot, as in Lightroom.
                        HStack(spacing: 12) {
                            ComparePane(image: develop.displayBeforeImage, label: "Before", pixelSize: pixelSize,
                                        zoom: model.zoomState, onReport: onZoomReport,
                                        menu: { model.photoMenu(includeZoom: true) })
                            ComparePane(image: develop.displayImage ?? image, label: "After", pixelSize: pixelSize,
                                        zoom: model.zoomState, onReport: onZoomReport,
                                        menu: { model.photoMenu(includeZoom: true) })
                        }
                        .padding(.horizontal, 8)
                    } else {
                        SliderCompareView(before: develop.displayBeforeImage, after: develop.displayImage ?? image,
                                          pixelSize: pixelSize, zoom: model.zoomState, onReport: onZoomReport,
                                          menu: { model.photoMenu(includeZoom: true) },
                                          position: $develop.sliderPosition)
                    }
                }
                if develop.isLoading {
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
                }
            }
            Divider()
            // Narrow columns drop the words first, then the hint, so the bar always fits.
            ViewThatFits(in: .horizontal) {
                bottomBar(compact: false)
                bottomBar(compact: true)
                HStack {
                    comparePicker(iconsOnly: true)
                    Spacer(minLength: 0)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { develop.open(model.focusedID) }
        .onChange(of: develop.compareMode) { old, new in compareModeChanged(from: old, to: new) }
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

    private func onZoomReport(_ report: ZoomReport) {
        if model.zoomReport != report { model.zoomReport = report }
        if develop.wantsFullResolution != report.isZoomedPastFit {
            develop.wantsFullResolution = report.isZoomedPastFit
        }
    }

    private var pixelSize: CGSize? {
        guard let width = model.detail?.asset.width, let height = model.detail?.asset.height else { return nil }
        return develop.croppedPixelSize(assetSize: CGSize(width: width, height: height))
    }

    private func bottomBar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if !compact {
                Text("Before and After").foregroundStyle(.secondary).fixedSize()
            }
            comparePicker(iconsOnly: compact)
                .disabled(develop.isCropping || develop.isAIOpen || develop.isMasking || develop.isGuiding)
            if !compact, develop.compareMode == .slider {
                Text("Drag the divider to compare").foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 8)
            ZoomControls(zoom: model.zoomState, compact: compact)
                .disabled(develop.isCropping || develop.isAIOpen || develop.isGuiding)
        }
    }

    private func comparePicker(iconsOnly: Bool) -> some View {
        Picker("Before and After", selection: $develop.compareMode) {
            ForEach(CompareMode.allCases, id: \.self) { mode in
                if iconsOnly {
                    Image(systemName: mode.symbol).tag(mode).help(mode.label)
                } else {
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Compare with the original: side by side, or drag a slider across the photo (Y)")
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct ComparePane: View {
    let image: NSImage?
    let label: String
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                ZoomableImageView(image: image, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: menu)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Badge(text: label).padding(8).allowsHitTesting(false)
        }
    }
}

/// The edited photo with the original revealed to the left of a draggable divider. Both zoom
/// and pan together: drag the photo to move around, drag the divider to compare.
private struct SliderCompareView: View {
    let before: NSImage?
    let after: NSImage
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dividerX = size.width * position
            ZStack(alignment: .topLeading) {
                ZoomableImageView(image: after, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: menu)
                if let before {
                    ZoomableImageView(image: before, pixelSize: pixelSize, zoom: zoom, visibleWidth: CGFloat(position),
                                      onReport: onReport, menu: menu)
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
                    .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("slider")).onChanged { value in
                        guard size.width > 0 else { return }
                        position = min(1, max(0, value.location.x / size.width))
                    })
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
    @AppStorage("develop.expandedPanels") private var expandedList = "histogram,basic"
    @AppStorage("develop.soloMode") private var soloMode = false

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
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    PanelSection(title: "Histogram", isExpanded: isExpanded("histogram"), soloMode: $soloMode,
                                 expandAll: expandAll, collapseAll: collapseAll) {
                        HistogramView(histogram: develop.histogram)
                    }
                    ToolStrip(develop: develop)
                    if develop.isCropping {
                        PanelSection(title: "Crop & Straighten", isExpanded: .constant(true), soloMode: $soloMode,
                                     isModified: develop.settings.crop != nil, reset: { develop.setCrop(Crop()) },
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            CropPanel(develop: develop)
                        }
                    }
                    if develop.isMasking {
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
                    ForEach(DevelopSettings.Panel.allCases, id: \.self) { panel in
                        PanelSection(title: panel.title, isExpanded: isExpanded(panel.rawValue), soloMode: $soloMode,
                                     isModified: develop.isModified(panel), reset: { develop.reset(panel) },
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
                            default:
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(groups(in: panel), id: \.0) { group in
                                        GroupHeading(title: group.0)
                                        ForEach(group.1, id: \.self) { parameter in
                                            ParameterSlider(parameter: parameter, develop: develop)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // Lay everything out at exactly the panel's measured width so nothing spills past it.
                .frame(width: geometry.size.width)
            }
            }
            Divider()
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
        .disabled(develop.assetID == nil)
    }

    private func expandAll() {
        soloMode = false
        expandedList = (["histogram"] + DevelopSettings.Panel.allCases.map(\.rawValue)).joined(separator: ",")
    }

    private func collapseAll() {
        expandedList = ""
    }
}

struct GroupHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// Tone Curve: an editable point curve per channel, drawn over the histogram, with Lightroom's
/// region sliders below.
private struct ToneCurvePanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage("develop.curveChannel") private var channelName = "rgb"

    private let regions: [DevelopSettings.Parameter] = [.curveHighlights, .curveLights, .curveDarks, .curveShadows]

    private var channel: DevelopSettings.CurveChannel {
        DevelopSettings.CurveChannel(rawValue: channelName) ?? .rgb
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Channel", selection: $channelName) {
                    ForEach(DevelopSettings.CurveChannel.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                Button {
                    develop.setPoints([], for: channel)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset the \(channel.label) curve")
                .disabled(develop.settings.points(for: channel) == DevelopSettings.CurvePoint.identity)
            }
            CurveEditor(develop: develop, channel: channel)
                .aspectRatio(1, contentMode: .fit)
            Text("Click the curve to add a point and drag it. Double-click a point to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupHeading(title: "Region")
            ForEach(regions, id: \.self) { parameter in
                ParameterSlider(parameter: parameter, develop: develop)
            }
        }
    }
}

private struct CurveEditor: View {
    @ObservedObject var develop: DevelopController
    let channel: DevelopSettings.CurveChannel
    @State private var dragIndex: Int?
    @State private var lastTap: (index: Int, time: Date)?

    private typealias Point = DevelopSettings.CurvePoint

    private var points: [Point] { develop.settings.points(for: channel) }

    private var color: Color {
        switch channel {
        case .rgb: return .white
        case .red: return Color(red: 1, green: 0.35, blue: 0.35)
        case .green: return Color(red: 0.35, green: 0.9, blue: 0.4)
        case .blue: return Color(red: 0.4, green: 0.55, blue: 1)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                if let histogram = develop.histogram {
                    let bins = channel == .red ? histogram.red : channel == .green ? histogram.green
                        : channel == .blue ? histogram.blue : histogram.luminance
                    var area = Path()
                    area.move(to: CGPoint(x: 0, y: size.height))
                    for (i, value) in bins.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                        area.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value) * 0.9)))
                    }
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    context.fill(area, with: .color(color.opacity(0.14)))
                }
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height))
                diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The overall result, including Basic and the region sliders, faintly.
                if channel == .rgb, DevelopRenderer.hasToneCurve(develop.settings) {
                    context.stroke(curvePath(size: size) { DevelopRenderer.pointCurveValue(points, at: DevelopRenderer.toneCurveValue(develop.settings, at: $0)) },
                                   with: .color(.white.opacity(0.3)), lineWidth: 1)
                }
                context.stroke(curvePath(size: size) { DevelopRenderer.pointCurveValue(points, at: $0) },
                               with: .color(color), lineWidth: 1.5)
                for (index, point) in points.enumerated() {
                    let center = position(of: point, in: size)
                    let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
                    context.fill(Path(ellipseIn: rect), with: .color(index == dragIndex ? color : .black))
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
                }
            }
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in drag(value, size: size) }
                .onEnded { value in endDrag(value, size: size) })
        }
    }

    private func curvePath(size: CGSize, _ f: (Double) -> Double) -> Path {
        var path = Path()
        let samples = 128
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let point = CGPoint(x: size.width * x, y: size.height * (1 - f(x)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func position(of point: Point, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * point.x, y: size.height * (1 - point.y))
    }

    private func drag(_ value: DragGesture.Value, size: CGSize) {
        var points = self.points
        if dragIndex == nil {
            // Grab the nearest point, or add one on the curve where the drag began.
            let start = value.startLocation
            let nearest = points.indices.min { a, b in
                distance(position(of: points[a], in: size), start) < distance(position(of: points[b], in: size), start)
            }
            if let nearest, distance(position(of: points[nearest], in: size), start) < 12 {
                dragIndex = nearest
            } else {
                let x = value.value(at: start, in: size).x
                let new = Point(x: x, y: DevelopRenderer.pointCurveValue(points, at: x))
                guard !points.contains(where: { abs($0.x - x) < 0.02 }) else { return }
                points.append(new)
                points.sort { $0.x < $1.x }
                dragIndex = points.firstIndex(of: new)
            }
        }
        guard let index = dragIndex else { return }
        var moved = value.value(at: value.location, in: size)
        // Keep points in order.
        let low = index == 0 ? 0 : points[index - 1].x + 0.01
        let high = index == points.count - 1 ? 1 : points[index + 1].x - 0.01
        moved.x = min(max(moved.x, low), high)
        points[index] = Point(x: moved.x, y: moved.y)
        develop.setPoints(points, for: channel)
    }

    private func endDrag(_ value: DragGesture.Value, size: CGSize) {
        defer { dragIndex = nil }
        guard let index = dragIndex, distance(value.startLocation, value.location) < 3 else { return }
        // Double-click removes an inner point.
        if let lastTap, lastTap.index == index, Date().timeIntervalSince(lastTap.time) < 0.4 {
            self.lastTap = nil
            var points = self.points
            guard index > 0, index < points.count - 1 else { return }
            points.remove(at: index)
            develop.setPoints(points, for: channel)
        } else {
            lastTap = (index, Date())
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private extension DragGesture.Value {
    func value(at location: CGPoint, in size: CGSize) -> DevelopSettings.CurvePoint {
        DevelopSettings.CurvePoint(x: Double(location.x / max(1, size.width)), y: Double(1 - location.y / max(1, size.height)))
    }
}

/// HSL / Color: eight color bands, shown one channel at a time or all at once; in Black & White,
/// the B&W Mix instead.
private struct HSLPanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage("develop.hslChannel") private var channel = "Hue"

    private var channels: [DevelopSettings.HSLChannel] {
        channel == "All" ? DevelopSettings.HSLChannel.allCases
            : [DevelopSettings.HSLChannel(rawValue: channel) ?? .hue]
    }

    var body: some View {
        if develop.settings.monochrome {
            // Black & White: the B&W Mix takes HSL's place, as in Lightroom.
            VStack(alignment: .leading, spacing: 7) {
                GroupHeading(title: "B&W Mix")
                ForEach(DevelopSettings.ColorBand.allCases, id: \.self) { band in
                    ParameterSlider(parameter: .gray(band), develop: develop)
                }
                Text("Each slider makes that color lighter or darker in gray.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            colorBody
        }
    }

    private var colorBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Channel", selection: $channel) {
                ForEach(DevelopSettings.HSLChannel.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                Text("All").tag("All")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            ForEach(channels, id: \.self) { channel in
                if channels.count > 1 { GroupHeading(title: channel.rawValue) }
                ForEach(DevelopSettings.ColorBand.allCases, id: \.self) { band in
                    ParameterSlider(parameter: .hsl(channel, band), develop: develop)
                }
            }
        }
    }
}

/// Color Grading: a wheel per tonal region plus Global, then Blending and Balance.
private struct ColorGradingPanel: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(DevelopSettings.GradeRegion.allCases, id: \.self) { region in
                    VStack(spacing: 6) {
                        Text(region.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .onTapGesture(count: 2) {
                                develop.reset(region.hue)
                                develop.reset(region.saturation)
                                develop.reset(region.luminance)
                            }
                            .help("Double-click to reset")
                        ColorWheel(hue: Binding(get: { develop.value(region.hue) },
                                                set: { develop.set(region.hue, to: $0) }),
                                   saturation: Binding(get: { develop.value(region.saturation) },
                                                       set: { develop.set(region.saturation, to: $0) }),
                                   onOption: { develop.sliderPreview = $0 ? .fullSaturation(region) : nil })
                            .help(SliderPreview.fullSaturation(region).hint)
                        DevelopSlider(value: Binding(get: { develop.value(region.luminance) },
                                                     set: { develop.set(region.luminance, to: $0) }),
                                      range: region.luminance.range, step: 1, origin: 0,
                                      gradient: [Color.black, Color.white])
                            .help("Luminance")
                        Text("H \(Int(develop.value(region.hue))) · S \(Int(develop.value(region.saturation))) · L \(Int(develop.value(region.luminance)))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GroupHeading(title: "Blend")
            ParameterSlider(parameter: .gradeBlending, develop: develop)
            ParameterSlider(parameter: .gradeBalance, develop: develop)
        }
    }
}

/// Drag inside the wheel to choose a tint: angle is hue, distance from the center is saturation.
/// With Option held only the hue changes, and the photo shows it at full saturation.
private struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    var onOption: ((Bool) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let angle = hue * .pi / 180
            let distance = radius * saturation / 100
            ZStack {
                Circle()
                    // SwiftUI sweeps clockwise on screen and a reversed range (end < start) draws only
                    // the first color, so run 0°→360° with hue falling, which puts hue rising
                    // counterclockwise from red at 3 o'clock, where the puck places it.
                    .fill(AngularGradient(colors: (0...12).map { Color(hue: Double(12 - $0) / 12, saturation: 0.8, brightness: 0.9) },
                                          center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                         center: .center, startRadius: 0, endRadius: radius))
                Circle().stroke(Color.black.opacity(0.4), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .position(x: center.x + distance * cos(angle), y: center.y - distance * sin(angle))
            }
            .frame(width: size, height: size)
            .position(center)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let option = NSEvent.modifierFlags.contains(.option)
                    onOption?(option)
                    let dx = value.location.x - center.x, dy = center.y - value.location.y
                    var degrees = atan2(dy, dx) * 180 / .pi
                    if degrees < 0 { degrees += 360 }
                    hue = degrees.rounded()
                    if !option { saturation = min(100, (dx * dx + dy * dy).squareRoot() / radius * 100).rounded() }
                }
                .onEnded { _ in onOption?(false) })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A collapsible panel with a Lightroom-style header.
struct PanelSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @Binding var soloMode: Bool
    var isModified = false
    var reset: (() -> Void)?
    let expandAll: () -> Void
    let collapseAll: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(title)
                    .font(.headline)
                if isModified {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help("This panel has edits")
                }
                Spacer()
                if isModified, let reset {
                    Button(action: reset) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset \(title)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            .contextMenu {
                Toggle("Solo Mode", isOn: $soloMode)
                Divider()
                Button("Expand All Panels", action: expandAll)
                Button("Collapse All Panels", action: collapseAll)
            }
            if isExpanded {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            Divider()
        }
    }
}

/// RGB histogram of the current render, with clipping warnings.
private struct HistogramView: View {
    let histogram: Histogram?
    @AppStorage("develop.showClipping") private var showClipping = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                guard let histogram else { return }
                context.blendMode = .plusLighter
                let channels: [([Double], Color)] = [
                    (histogram.red, Color(red: 0.9, green: 0.2, blue: 0.2)),
                    (histogram.green, Color(red: 0.2, green: 0.8, blue: 0.3)),
                    (histogram.blue, Color(red: 0.25, green: 0.4, blue: 1.0)),
                ]
                for (bins, color) in channels {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (index, value) in bins.enumerated() {
                        let x = size.width * CGFloat(index) / CGFloat(bins.count - 1)
                        path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value))))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(0.7)))
                }
            }
            .frame(height: 90)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if histogram == nil { ProgressView().controlSize(.small) }
            }
            HStack {
                clipping("Shadows", histogram?.shadowClipping)
                Spacer()
                clipping("Highlights", histogram?.highlightClipping)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func clipping(_ name: String, _ share: Double?) -> some View {
        if showClipping, let share, share >= 0.005 {
            Label("\(name) clipped \(String(format: "%.1f", share * 100))%", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(" ")
        }
    }
}

struct ParameterSlider: View {
    let parameter: DevelopSettings.Parameter
    @ObservedObject var develop: DevelopController
    @State private var editing = false
    @State private var draft = 0.0
    @FocusState private var fieldFocused: Bool

    private var binding: Binding<Double> {
        Binding(get: { develop.sliderValue(parameter) }, set: { develop.setSlider(parameter, to: $0) })
    }

    private var formatted: String {
        let value = develop.sliderValue(parameter)
        switch parameter {
        case .temperature where !develop.isRAW: return value == 0 ? "0" : String(format: "%+.0f", value)
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
        HStack(spacing: 8) {
            Text(parameter.label)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if NSEvent.modifierFlags.contains(.shift), develop.canAuto(parameter) {
                        develop.autoTone(only: parameter)
                    } else {
                        develop.reset(parameter)
                    }
                }
                .help(develop.canAuto(parameter) ? "Double-click to reset; Shift-double-click for Auto" : "Double-click to reset")
            DevelopSlider(value: binding, range: develop.sliderRange(parameter), step: step,
                          origin: develop.sliderDefault(parameter), gradient: trackGradient,
                          logarithmic: parameter == .temperature && develop.isRAW,
                          onOption: SliderPreview(parameter: parameter).map { preview in
                              { (held: Bool) in develop.sliderPreview = held ? preview : nil }
                          })
                .help(SliderPreview(parameter: parameter)?.hint ?? "")
            Group {
                if editing {
                    TextField("Value", value: $draft, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onChange(of: fieldFocused) { if !fieldFocused { commit() } }
                        .onExitCommand { editing = false }
                } else {
                    Text(formatted)
                        .monospacedDigit()
                        .foregroundStyle(isDefault ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = develop.sliderValue(parameter)
                            editing = true
                            fieldFocused = true
                        }
                        .help("Click to type a value")
                }
            }
            .frame(width: parameter == .temperature ? 58 : 44)
        }
        .font(.callout)
        .frame(height: 20)
    }

    private var isDefault: Bool {
        develop.sliderValue(parameter) == develop.sliderDefault(parameter)
    }

    private func commit() {
        guard editing else { return }
        develop.setSlider(parameter, to: draft)
        editing = false
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
        switch parameter {
        case .temperature: return [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)]
        case .tint: return [Color(red: 0.3, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.85)]
        case .vibrance, .saturation: return [Color.gray, Color(red: 1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.6, blue: 1)]
        default: return nil
        }
    }

    private var step: Double {
        switch parameter {
        case .temperature: return develop.isRAW ? 50 : 1
        case .exposure: return 0.05
        case .sharpenRadius, .transformRotate: return 0.1
        default: return 1
        }
    }
}

/// A slim Lightroom-style slider: thin track (colored where Lightroom colors it), a mark at the
/// default, the change from the default filled in, and a small round knob.
struct DevelopSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Where the fill starts: the parameter's default.
    let origin: Double
    let gradient: [Color]?
    /// Temperature moves in equal steps of perceived warmth rather than Kelvin.
    var logarithmic = false
    /// Told while dragging whether Option is held, and false when the drag ends, for the
    /// slider's Option-drag view.
    var onOption: ((Bool) -> Void)?

    private func fraction(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        if logarithmic {
            return (log(clamped) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound))
        }
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(at fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        let raw = logarithmic
            ? exp(log(range.lowerBound) + f * (log(range.upperBound) - log(range.lowerBound)))
            : range.lowerBound + f * (range.upperBound - range.lowerBound)
        return (raw / step).rounded() * step
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let midY = geometry.size.height / 2
            let knob = fraction(value) * width
            let start = fraction(origin) * width
            ZStack(alignment: .topLeading) {
                Group {
                    if let gradient {
                        Capsule().fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Color.secondary.opacity(0.28))
                    }
                }
                .frame(width: width, height: 3)
                .offset(y: midY - 1.5)
                if gradient == nil {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: abs(knob - start), height: 3)
                        .offset(x: min(knob, start), y: midY - 1.5)
                }
                if start > 1, start < width - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 1, height: 7)
                        .offset(x: start - 0.5, y: midY - 3.5)
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 11, height: 11)
                    .offset(x: knob - 5.5, y: midY - 5.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    onOption?(NSEvent.modifierFlags.contains(.option))
                    guard width > 0 else { return }
                    let newValue = value(at: Double(drag.location.x / width))
                    if newValue != value { value = newValue }
                }
                .onEnded { _ in onOption?(false) })
        }
        .frame(height: 16)
    }
}

/// Lightroom's tool strip under the histogram.
private struct ToolStrip: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(spacing: 14) {
            tool("crop", title: "Crop & Straighten (R)", active: develop.isCropping,
                 modified: develop.settings.crop != nil) {
                develop.isCropping.toggle()
            }
            tool("circle.dashed", title: "Masking: Linear Gradient, Radial Gradient, Brush, Luminance Range, Select Subject (⇧W)",
                 active: develop.isMasking, modified: !develop.masks.isEmpty) {
                develop.isMasking.toggle()
            }
            tool("wand.and.stars", title: "AI: Remove Object, Replace Background, Upscale", active: develop.isAIOpen,
                 modified: false) {
                develop.isAIOpen.toggle()
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
