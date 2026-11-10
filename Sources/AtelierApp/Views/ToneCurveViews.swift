import AppKit
import AtelierCore
import SwiftUI

/// Tone Curve, as in Lightroom: a Parametric view (Highlights, Lights, Darks and Shadows, with
/// three split points under the graph, and dragging on the graph moves the region under the
/// pointer) and a Point view (an editable curve per channel with Input and Output, Refine
/// Saturation and a menu of saved curves). Both views are drawn over the histogram, and the
/// Targeted Adjustment Tool follows the one that is shown.
struct ToneCurvePanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage(DevelopController.curveModeKey) private var mode = "parametric"
    @AppStorage(DevelopController.curveChannelKey) private var channelName = "rgb"
    @AppStorage("develop.curveSnapToGrid") private var snapToGrid = false
    @AppStorage("develop.curveShowAll") private var showAllCurves = false
    @State private var selected: Int?
    @State private var naming = false
    @State private var curveName = ""

    private let regions = DevelopRenderer.curveRegions
    private let splits: [DevelopSettings.Parameter] = [.curveShadowSplit, .curveMidtoneSplit, .curveHighlightSplit]

    private var channel: DevelopSettings.CurveChannel {
        DevelopSettings.CurveChannel(rawValue: channelName) ?? .rgb
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PickerButton(develop: develop, kind: .targetCurve, symbol: "scope",
                             help: "Targeted Adjustment: drag up or down on the photo to change the tones under the pointer")
                Picker("View", selection: $mode) {
                    Text("Parametric").tag("parametric")
                    Text("Point").tag("point")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .help("Parametric: region sliders. Point: draw the curve yourself, per channel.")
            }
            if mode == "point" {
                pointView
            } else {
                parametricView
            }
        }
        .alert("Save Curve", isPresented: $naming) {
            TextField("Name", text: $curveName)
            Button("Save") { develop.saveCurve(named: curveName, channel: channel) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(channel.label) curve so you can apply it to any photo from this menu.")
        }
    }

    // MARK: Parametric

    private var parametricView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ParametricCurveView(develop: develop)
                .aspectRatio(1, contentMode: .fit)
                .contextMenu {
                    Button("Reset Regions") { develop.reset(group: "Region", parameters: regions) }
                    Button("Reset Splits") { develop.reset(group: "Splits", parameters: splits) }
                    Button("Reset Regions and Splits") { develop.reset(group: "Region", parameters: regions + splits) }
                }
            SplitBar(develop: develop)
                .frame(height: 12)
            GroupHeading(title: "Region") { develop.reset(group: "Region", parameters: regions + splits) }
            ForEach(regions.reversed(), id: \.self) { parameter in
                ParameterSlider(parameter: parameter, develop: develop)
            }
        }
    }

    // MARK: Point

    private var pointView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("Channel", selection: $channelName) {
                    ForEach(DevelopSettings.CurveChannel.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                curveMenu
            }
            CurveEditor(develop: develop, channel: channel, selected: $selected, snapToGrid: snapToGrid,
                        showAllCurves: showAllCurves)
                .aspectRatio(1, contentMode: .fit)
                .contextMenu { curveMenuItems }
            PointReadout(develop: develop, channel: channel, selected: $selected)
            Text("Click the curve to add a point and drag it; drag a point off the graph or double-click it to remove it. "
                 + "With the pointer over the graph, arrow keys nudge the selected point.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if develop.settings.points(for: .rgb) != DevelopSettings.CurvePoint.identity {
                ParameterSlider(parameter: .curveRefineSaturation, develop: develop)
                    .help("How much the RGB curve changes saturation along with brightness: 100 as Lightroom does, "
                          + "0 brightness only")
            }
        }
        .onChange(of: channelName) { selected = nil }
    }

    private var curveMenu: some View {
        Menu {
            curveMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved curves, copy and paste, and display options")
    }

    @ViewBuilder
    private var curveMenuItems: some View {
        ForEach(SavedCurve.builtIn) { curve in
            Button(curve.name) { develop.setPoints(curve.points, for: channel) }
        }
        if !develop.savedCurves.isEmpty {
            Divider()
            ForEach(develop.savedCurves) { curve in
                Button(curve.name) { develop.setPoints(curve.points, for: channel) }
            }
            Menu("Delete Saved Curve") {
                ForEach(develop.savedCurves) { curve in
                    Button(curve.name) { develop.deleteSavedCurve(curve) }
                }
            }
        }
        Button("Save Curve…") {
            curveName = ""
            naming = true
        }
        .disabled(develop.settings.points(for: channel) == DevelopSettings.CurvePoint.identity)
        Divider()
        Button("Copy \(channel.label) Channel Settings") { develop.copyCurve(channel) }
        Button("Paste to \(channel.label) Channel") { develop.pasteCurve(onto: channel) }
            .disabled(develop.copiedCurve == nil)
        Divider()
        Button("Reset \(channel.label) Channel") { develop.setPoints([], for: channel) }
            .disabled(develop.settings.points(for: channel) == DevelopSettings.CurvePoint.identity)
        Button("Reset All Channels") { develop.resetAllCurves() }
            .disabled(!develop.settings.hasPointCurve)
        Divider()
        Toggle("Snap to Grid", isOn: $snapToGrid)
        Toggle("Show All Curves", isOn: $showAllCurves)
    }
}

/// The curve graph's backdrop: the channel's histogram and a quarter grid.
private struct CurveBackdrop {
    static func draw(in context: GraphicsContext, size: CGSize, histogram: Histogram?,
                     channel: DevelopSettings.CurveChannel, color: Color) {
        var grid = Path()
        for i in 1..<4 {
            let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
        if let histogram {
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
    }

    static func path(size: CGSize, _ f: (Double) -> Double) -> Path {
        var path = Path()
        let samples = 128
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let point = CGPoint(x: size.width * x, y: size.height * (1 - f(x)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Lightroom's parametric curve: the region curve over the histogram, the region a drag would
/// change shaded under the pointer. Dragging up or down moves that region's slider.
private struct ParametricCurveView: View {
    @ObservedObject var develop: DevelopController
    @State private var hover: Double?
    @State private var drag: (parameter: DevelopSettings.Parameter, start: Double)?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            MeasuresReader(develop.measures) { measures in Canvas { context, size in
                CurveBackdrop.draw(in: context, size: size, histogram: measures.histogram, channel: .rgb, color: .white)
                if let region = activeRegion {
                    let (low, high) = bounds(of: region)
                    let rect = CGRect(x: size.width * low, y: 0, width: size.width * (high - low), height: size.height)
                    context.fill(Path(rect), with: .color(.white.opacity(0.08)))
                }
                let settings = develop.settings
                context.stroke(CurveBackdrop.path(size: size) { DevelopRenderer.regionCurveValue(settings, at: $0) },
                               with: .color(.white), lineWidth: 1.5)
            } }
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { hover = Double(point.x / max(1, size.width)) } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if drag == nil {
                        let x = Double(value.startLocation.x / max(1, size.width))
                        let parameter = region(at: x)
                        drag = (parameter, develop.value(parameter))
                    }
                    guard let drag else { return }
                    let moved = drag.start - Double(value.translation.height) * 0.5
                    develop.set(drag.parameter, to: moved.rounded())
                }
                .onEnded { _ in drag = nil })
            .cursor(whileDragging: .rowResize) { _ in .rowResize }
            .help("Drag up or down to lighten or darken the region under the pointer")
        }
    }

    private var activeRegion: DevelopSettings.Parameter? {
        drag?.parameter ?? hover.map { region(at: $0) }
    }

    /// The region slider with the most say at tone `x`.
    private func region(at x: Double) -> DevelopSettings.Parameter {
        let weights = TargetedAdjustment.regionWeights(tone: min(1, max(0, x)), settings: develop.settings)
        let index = weights.indices.max { weights[$0] < weights[$1] } ?? 0
        return DevelopRenderer.curveRegions[index]
    }

    /// Where a region lies between the split points.
    private func bounds(of region: DevelopSettings.Parameter) -> (Double, Double) {
        let (low, middle, high) = DevelopRenderer.curveSplits(develop.settings)
        switch region {
        case .curveShadows: return (0, low)
        case .curveDarks: return (low, middle)
        case .curveLights: return (middle, high)
        default: return (high, 1)
        }
    }
}

/// The three triangles under the parametric curve that move the split points between regions,
/// as in Lightroom. Right-click the graph to reset them.
private struct SplitBar: View {
    @ObservedObject var develop: DevelopController
    @State private var dragging: DevelopSettings.Parameter?

    private let parameters: [DevelopSettings.Parameter] = [.curveShadowSplit, .curveMidtoneSplit, .curveHighlightSplit]

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let splits = DevelopRenderer.curveSplits(develop.settings)
            let positions = [splits.0, splits.1, splits.2]
            Canvas { context, size in
                for (index, x) in positions.enumerated() {
                    let center = size.width * x
                    var triangle = Path()
                    triangle.move(to: CGPoint(x: center, y: 1))
                    triangle.addLine(to: CGPoint(x: center + 5, y: size.height - 1))
                    triangle.addLine(to: CGPoint(x: center - 5, y: size.height - 1))
                    triangle.closeSubpath()
                    let active = dragging == parameters[index]
                    context.fill(triangle, with: .color(active ? Color.accentColor : Color.secondary))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragging == nil {
                        let x = Double(value.startLocation.x / width)
                        let nearest = positions.indices.min { abs(positions[$0] - x) < abs(positions[$1] - x) } ?? 1
                        dragging = parameters[nearest]
                    }
                    guard let dragging else { return }
                    develop.set(dragging, to: (Double(value.location.x / width) * 100).rounded())
                }
                .onEnded { _ in dragging = nil })
            .cursor(.slide)
            .help("Drag a triangle to move where one region ends and the next begins")
        }
    }
}

/// The point curve for one channel. Click to add a point and drag it; drag a point off the
/// graph or double-click it to remove it; with the pointer over the graph, the arrow keys nudge
/// the selected point (Shift for more; see `DevelopController.nudgeCurvePoint`).
struct CurveEditor: View {
    @ObservedObject var develop: DevelopController
    let channel: DevelopSettings.CurveChannel
    @Binding var selected: Int?
    var snapToGrid = false
    var showAllCurves = false
    @Environment(\.developFrameHUD) private var frameHUD
    @State private var dragIndex: Int?
    @State private var removing = false
    @State private var lastTap: (index: Int, time: Date)?
    @State private var hovering = false

    private typealias Point = DevelopSettings.CurvePoint

    /// Lightroom's limit.
    static let maxPoints = 16

    private var diagnosticName: String { "Tone Curve \(channel.rawValue)" }

    private var points: [Point] { develop.settings.points(for: channel) }

    static func color(_ channel: DevelopSettings.CurveChannel) -> Color {
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
            let color = Self.color(channel)
            MeasuresReader(develop.measures) { measures in Canvas { context, size in
                CurveBackdrop.draw(in: context, size: size, histogram: measures.histogram, channel: channel, color: color)
                // The overall result, including Basic and the region curve, faintly.
                if channel == .rgb, DevelopRenderer.hasToneCurve(develop.settings) {
                    let settings = develop.settings
                    let master = points
                    context.stroke(CurveBackdrop.path(size: size) {
                        DevelopRenderer.pointCurveValue(master, at: DevelopRenderer.toneCurveValue(settings, at: $0))
                    }, with: .color(.white.opacity(0.3)), lineWidth: 1)
                }
                if showAllCurves {
                    for other in DevelopSettings.CurveChannel.allCases where other != channel {
                        let otherPoints = develop.settings.points(for: other)
                        guard otherPoints != Point.identity else { continue }
                        context.stroke(CurveBackdrop.path(size: size) { DevelopRenderer.pointCurveValue(otherPoints, at: $0) },
                                       with: .color(Self.color(other).opacity(0.45)), lineWidth: 1)
                    }
                }
                let current = points
                context.stroke(CurveBackdrop.path(size: size) { DevelopRenderer.pointCurveValue(current, at: $0) },
                               with: .color(color), lineWidth: 1.5)
                for (index, point) in current.enumerated() {
                    let center = position(of: point, in: size)
                    let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
                    let fading = removing && index == dragIndex
                    context.fill(Path(ellipseIn: rect), with: .color(index == dragIndex || index == selected ? color : .black))
                    context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(fading ? 0.3 : 1)), lineWidth: 1.5)
                }
            } }
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateNudgeTarget()
            }
            .onChange(of: selected) { updateNudgeTarget() }
            .onDisappear {
                develop.hoveredCurvePoint = nil
                frameHUD?.end(diagnosticName)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let frameHUD, frameHUD.active {
                        frameHUD.measure(diagnosticName) { drag(value, size: size) }
                    } else {
                        drag(value, size: size)
                    }
                }
                .onEnded { value in
                    endDrag(value, size: size)
                    frameHUD?.end(diagnosticName)
                })
            // A hand on a point; elsewhere a click adds one, as with Lightroom's point curve.
            .cursor(whileDragging: .grabbing) { location in nearestPoint(to: location, in: size) == nil ? .crosshair : .grab }
        }
    }

    /// The point a drag starting at `location` picks up, if any.
    private func nearestPoint(to location: CGPoint, in size: CGSize) -> Int? {
        let points = self.points
        let nearest = points.indices.min { a, b in
            distance(position(of: points[a], in: size), location) < distance(position(of: points[b], in: size), location)
        }
        guard let nearest, distance(position(of: points[nearest], in: size), location) < 12 else { return nil }
        return nearest
    }

    private func position(of point: Point, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * point.x, y: size.height * (1 - point.y))
    }

    private func value(at location: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        var x = Double(location.x / max(1, size.width)), y = Double(1 - location.y / max(1, size.height))
        if snapToGrid {
            // Onto a grid line (quarters and eighths) when close to one.
            for step in [0.25, 0.125] {
                let snappedX = (x / step).rounded() * step, snappedY = (y / step).rounded() * step
                if abs(snappedX - x) < 0.02 { x = snappedX }
                if abs(snappedY - y) < 0.02 { y = snappedY }
            }
        }
        return (x, y)
    }

    /// While the pointer is over the graph, the arrow keys nudge the selected point.
    private func updateNudgeTarget() {
        if hovering, let selected {
            develop.hoveredCurvePoint = (channel: channel, index: selected)
        } else {
            develop.hoveredCurvePoint = nil
        }
    }

    private func drag(_ value: DragGesture.Value, size: CGSize) {
        var points = self.points
        if dragIndex == nil {
            // Grab the nearest point, or add one on the curve where the drag began.
            let start = value.startLocation
            if let nearest = nearestPoint(to: start, in: size) {
                dragIndex = nearest
            } else {
                guard points.count < Self.maxPoints else { return }
                let x = min(1, max(0, self.value(at: start, in: size).x))
                guard !points.contains(where: { abs($0.x - x) < 0.02 }) else { return }
                let new = Point(x: x, y: DevelopRenderer.pointCurveValue(points, at: x))
                points.append(new)
                points.sort { $0.x < $1.x }
                dragIndex = points.firstIndex(of: new)
            }
            selected = dragIndex
        }
        guard let index = dragIndex, points.indices.contains(index) else { return }
        // Dragged well off the graph: the point goes when the mouse comes up, as in Lightroom.
        let outside = value.location.x < -14 || value.location.y < -14
            || value.location.x > size.width + 14 || value.location.y > size.height + 14
        removing = outside && index > 0 && index < points.count - 1
        guard !removing else { return }
        let moved = self.value(at: value.location, in: size)
        // Keep points in order.
        let low = index == 0 ? 0 : points[index - 1].x + 0.01
        let high = index == points.count - 1 ? 1 : points[index + 1].x - 0.01
        points[index] = Point(x: min(max(moved.x, low), high), y: moved.y)
        develop.setPoints(points, for: channel)
    }

    private func endDrag(_ value: DragGesture.Value, size: CGSize) {
        defer {
            dragIndex = nil
            removing = false
        }
        guard let index = dragIndex else { return }
        if removing {
            remove(index)
            return
        }
        guard distance(value.startLocation, value.location) < 3 else { return }
        // Double-click removes an inner point.
        if let lastTap, lastTap.index == index, Date().timeIntervalSince(lastTap.time) < 0.4 {
            self.lastTap = nil
            remove(index)
        } else {
            lastTap = (index, Date())
        }
    }

    private func remove(_ index: Int) {
        var points = self.points
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
        selected = nil
        develop.setPoints(points, for: channel)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The selected point's Input and Output, 0 to 255 as in Lightroom; type a value to move it.
private struct PointReadout: View {
    @ObservedObject var develop: DevelopController
    let channel: DevelopSettings.CurveChannel
    @Binding var selected: Int?

    private var point: DevelopSettings.CurvePoint? {
        let points = develop.settings.points(for: channel)
        return selected.flatMap { points.indices.contains($0) ? points[$0] : nil }
    }

    var body: some View {
        HStack(spacing: 6) {
            field("Input", value: point.map { $0.x }) { x in
                var points = develop.settings.points(for: channel)
                guard let index = selected, points.indices.contains(index) else { return }
                let low = index == 0 ? 0 : points[index - 1].x + 0.01
                let high = index == points.count - 1 ? 1 : points[index + 1].x - 0.01
                points[index].x = min(max(x, low), high)
                develop.setPoints(points, for: channel)
            }
            field("Output", value: point.map { $0.y }) { y in
                var points = develop.settings.points(for: channel)
                guard let index = selected, points.indices.contains(index) else { return }
                points[index].y = min(1, max(0, y))
                develop.setPoints(points, for: channel)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .disabled(point == nil)
        .help("The selected point's input and output levels (0 to 255)")
    }

    private func field(_ title: String, value: Double?, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value.map { Int(($0 * 255).rounded()) } ?? 0 },
                                            set: { set(Double(min(255, max(0, $0))) / 255) }),
                      format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
        }
    }
}
