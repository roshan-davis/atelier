import AppKit
import AtelierCore
import SwiftUI

/// The photo under the Remove tool (AT-066): the same zoomable photo view as Develop, so zoom,
/// panning and the zoomed spot are shared with every other mode, with the spots drawn and
/// edited on top (`SpotOverlay`). Zoom with the zoom bar, Z, pinch or ⌘-scroll; scroll or
/// Space-drag moves around.
struct SpotEditorView: View {
    @ObservedObject var develop: DevelopController
    /// The live proxy; spot positions are measured against it.
    let image: NSImage
    /// The sharpest image for the current settings, drawn in the same place.
    let display: NSImage
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void

    var body: some View {
        ZoomableImageView(image: display, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: { nil },
                          overlay: { [develop, image] frame in
                              AnyView(SpotOverlay(develop: develop, image: image, frame: frame))
                          },
                          feed: develop.photoFeed)
    }
}

/// Draws the spots over the photo view and turns clicks and drags into new spots, source and
/// spot moves, and selection, as Lightroom's Remove tool does.
private struct SpotOverlay: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage
    @ObservedObject var frame: PhotoFrame

    private typealias Point = DevelopSettings.MaskPoint
    private typealias Spot = DevelopSettings.Spot

    /// What the current drag is doing, decided when it starts.
    private enum DragAction {
        case paint
        case moveSource(id: UUID, original: Point, start: Point)
        case moveSpot(id: UUID, original: [Point], start: Point)
        case pan(last: CGPoint)
        case none
    }

    @State private var action: DragAction?
    @State private var stroke: [Point]?
    @State private var hover: CGPoint?
    @StateObject private var keys = SpaceKeyMonitor()

    var body: some View {
        GeometryReader { geometry in
            let space = MaskSpace(sourceSize: develop.sourceSize ?? image.size, crop: develop.crop, rect: frame.rect,
                                  outputSize: image.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.clip(to: Path(space.rect))
                    drawSpots(in: &context, space: space)
                    drawStroke(in: &context, space: space)
                    drawBrushCursor(in: &context, space: space)
                }
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            // Scroll and pinch fall through to the photo view underneath, which zooms and pans.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in dragChanged(drag, space: space) }
                .onEnded { drag in dragEnded(drag, space: space) })
            .onContinuousHover { phase in
                if case .active(let point) = phase { hover = point } else { hover = nil }
            }
            .cursor { point in cursor(for: action ?? beginAction(at: point, space: space)) }
        }
        .onAppear { keys.install() }
        .onDisappear { keys.remove() }
        .onChange(of: develop.assetID) { _, _ in
            action = nil
            stroke = nil
        }
    }

    // MARK: Drawing

    /// Every spot's pin, and the selected spot's outline and source joined by a line, as in
    /// Lightroom. With Show Overlay off only the selected spot is drawn.
    private func drawSpots(in context: inout GraphicsContext, space: MaskSpace) {
        for spot in develop.spots where spot.id != develop.selectedSpotID && develop.showsSpotOverlay {
            outline(spot.points, size: spot.size, in: &context, space: space, color: .white.opacity(0.55), width: 1)
        }
        guard let spot = develop.selectedSpot else { return }
        let from = space.viewPoint(spot.sourceCenter), to = space.viewPoint(spot.center)
        var link = Path()
        link.move(to: from)
        link.addLine(to: to)
        context.stroke(link, with: .color(.black.opacity(0.5)), lineWidth: 2.5)
        context.stroke(link, with: .color(.white), lineWidth: 1)
        arrowHead(at: to, from: from, in: &context)
        outline(spot.sourcePoints, size: spot.size, in: &context, space: space, color: .white, width: 1, dashed: true)
        outline(spot.points, size: spot.size, in: &context, space: space, color: .white, width: 1.5)
    }

    /// The brush's edge along `points`: a circle for a click, a rounded band for a stroke.
    private func outline(_ points: [Point], size: Double, in context: inout GraphicsContext, space: MaskSpace,
                         color: Color, width: CGFloat, dashed: Bool = false) {
        let diameter = space.viewLength(size)
        let view = points.map { space.viewPoint($0) }
        let shape: Path
        if view.count == 1, let p = view.first {
            shape = Path(ellipseIn: CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2, width: diameter, height: diameter))
        } else {
            var path = Path()
            path.addLines(view)
            shape = path.strokedPath(StrokeStyle(lineWidth: max(1, diameter), lineCap: .round, lineJoin: .round))
        }
        context.stroke(shape, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: width + 1.5, dash: dashed ? [4, 3] : []))
        context.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [4, 3] : []))
    }

    private func arrowHead(at tip: CGPoint, from tail: CGPoint, in context: inout GraphicsContext) {
        let length = hypot(tip.x - tail.x, tip.y - tail.y)
        guard length > 12 else { return }
        let ux = (tip.x - tail.x) / length, uy = (tip.y - tail.y) / length
        // Stop at the middle, so the head isn't hidden under the spot's own outline.
        let at = CGPoint(x: tail.x + ux * length / 2, y: tail.y + uy * length / 2)
        var head = Path()
        head.move(to: CGPoint(x: at.x - ux * 7 - uy * 4, y: at.y - uy * 7 + ux * 4))
        head.addLine(to: at)
        head.addLine(to: CGPoint(x: at.x - ux * 7 + uy * 4, y: at.y - uy * 7 - ux * 4))
        context.stroke(head, with: .color(.white), lineWidth: 1.5)
    }

    private func drawStroke(in context: inout GraphicsContext, space: MaskSpace) {
        guard let stroke, !stroke.isEmpty else { return }
        let width = space.viewLength(develop.spotSize)
        let points = stroke.map { space.viewPoint($0) }
        let color = Color.white.opacity(0.35)
        if points.count == 1, let p = points.first {
            context.fill(Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)),
                         with: .color(color))
        } else {
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// The brush's size (and its feather, dashed) under the pointer while a new spot is ready.
    private func drawBrushCursor(in context: inout GraphicsContext, space: MaskSpace) {
        guard let hover, space.rect.contains(hover), isPaint(action ?? beginAction(at: hover, space: space)) else { return }
        let diameter = space.viewLength(develop.spotSize)
        let outer = CGRect(x: hover.x - diameter / 2, y: hover.y - diameter / 2, width: diameter, height: diameter)
        context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.5)), lineWidth: 2.5)
        context.stroke(Path(ellipseIn: outer), with: .color(.white), lineWidth: 1)
        let hard = diameter * max(0, 1 - develop.spotFeather / 100)
        if hard > 2, hard < diameter - 1 {
            let inner = CGRect(x: hover.x - hard / 2, y: hover.y - hard / 2, width: hard, height: hard)
            context.stroke(Path(ellipseIn: inner), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func isPaint(_ action: DragAction) -> Bool {
        if case .paint = action { return true }
        return false
    }

    // MARK: Dragging

    private var photoSize: CGSize { develop.sourceSize ?? image.size }

    private func dragChanged(_ drag: DragGesture.Value, space: MaskSpace) {
        hover = drag.location
        if action == nil {
            let begun = beginAction(at: drag.startLocation, space: space)
            if case .paint = begun { stroke = [space.maskPoint(clamped(drag.startLocation, to: space.rect))] }
            // Pressing another spot selects it (and a drag then moves it).
            if case .moveSpot(let id, _, _) = begun, id != develop.selectedSpotID { develop.selectSpot(id) }
            action = begun
        }
        guard let action else { return }
        let now = space.maskPoint(drag.location)
        switch action {
        case .paint:
            stroke?.append(space.maskPoint(clamped(drag.location, to: space.rect)))
        case .moveSource(let id, let original, let start):
            develop.moveSpotSource(id, to: Point(x: original.x + now.x - start.x, y: original.y + now.y - start.y))
        case .moveSpot(let id, let original, let start):
            develop.moveSpot(id, to: original.map { Point(x: $0.x + now.x - start.x, y: $0.y + now.y - start.y) })
        case .pan(let last):
            frame.pan?(CGSize(width: drag.location.x - last.x, height: drag.location.y - last.y))
            self.action = .pan(last: drag.location)
        case .none:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value, space: MaskSpace) {
        defer {
            action = nil
            stroke = nil
        }
        guard let action, case .paint = action, var points = stroke else { return }
        let moved = hypot(drag.location.x - drag.startLocation.x, drag.location.y - drag.startLocation.y)
        if moved < 3 {
            // A click: a round spot where it was pressed.
            points = [points[0]]
        } else {
            points.append(space.maskPoint(clamped(drag.location, to: space.rect)))
            points = thinned(points, space: space)
        }
        develop.addSpot(points: points)
    }

    /// Keeps a point every couple of view points, so a slow stroke doesn't store hundreds.
    private func thinned(_ points: [Point], space: MaskSpace) -> [Point] {
        var result: [Point] = []
        var last: CGPoint?
        for point in points {
            let view = space.viewPoint(point)
            if let last, hypot(view.x - last.x, view.y - last.y) < 2 { continue }
            result.append(point)
            last = view
        }
        if let final = points.last, result.last != final { result.append(final) }
        return result
    }

    /// What the pointer shows over `point`: what a drag starting there would do.
    private func cursor(for action: DragAction) -> CursorShape {
        switch action {
        case .paint: return .crosshair
        case .moveSource, .moveSpot: return self.action == nil ? .grab : .grabbing
        case .pan: return .grab
        case .none: return .arrow
        }
    }

    /// Decides what a drag starting at `point` does: moving the selected spot's source or the
    /// spot itself, picking up another spot (which selects it), or painting a new spot.
    /// Changes nothing but the selection, so the cursor asks it too.
    private func beginAction(at point: CGPoint, space: MaskSpace) -> DragAction {
        if keys.spaceDown { return .pan(last: point) }
        guard space.rect.contains(point) else { return .none }
        let at = space.maskPoint(point)
        if let spot = develop.selectedSpot {
            if spot.sourceContains(at, photo: photoSize) { return .moveSource(id: spot.id, original: spot.offset, start: at) }
            if spot.contains(at, photo: photoSize) { return .moveSpot(id: spot.id, original: spot.points, start: at) }
        }
        // The newest spot on top.
        if let spot = develop.spots.last(where: { $0.contains(at, photo: photoSize) }) {
            return .moveSpot(id: spot.id, original: spot.points, start: at)
        }
        return .paint
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}

/// The Remove tool's panel under the tool strip, as Lightroom's: Heal or Clone, the brush, the
/// view options, and Done.
struct RemovePanel: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Binding(get: { develop.spotMode }, set: { develop.setSpotMode($0) })) {
                ForEach(DevelopSettings.Spot.Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Heal matches the colors around the spot; Clone copies the source as it is")
            VStack(alignment: .leading, spacing: 6) {
                GroupHeading(title: "Brush", reset: resetBrush)
                SliderRow(label: "Size", value: Binding(get: { develop.spotSize * 100 }, set: { develop.setSpotSize($0 / 100) }),
                          range: 0.3...40, step: 0.1, origin: 0.3, format: { String(format: "%.1f", $0) },
                          reset: { develop.setSpotSize(DevelopSettings.Spot.defaultSize) },
                          trackHelp: "The spot's size, as a share of the photo's long edge ([ and ])")
                SliderRow(label: "Feather", value: Binding(get: { develop.spotFeather }, set: { develop.setSpotFeather($0) }),
                          range: 0...100, step: 1, origin: 0,
                          reset: { develop.setSpotFeather(DevelopSettings.Spot.defaultFeather) },
                          trackHelp: "How softly the fill fades into the photo (⇧[ and ⇧])")
                SliderRow(label: "Opacity", value: Binding(get: { develop.spotOpacity }, set: { develop.setSpotOpacity($0) }),
                          range: 0...100, step: 1, origin: 100, reset: { develop.setSpotOpacity(100) })
            }
            Toggle("Show Overlay", isOn: $develop.showsSpotOverlay)
                .help("Show every spot's outline on the photo; the selected one always shows")
            Toggle("Visualize Spots", isOn: $develop.visualizesSpots)
                .help("Show the photo's edges in black on white, so sensor dust and specks stand out (A)")
            if develop.visualizesSpots {
                SliderRow(label: "Threshold", value: $develop.spotVisualizeAmount, range: 0...100, step: 1, origin: 50,
                          trackHelp: "Right shows fainter specks")
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(develop.spots.isEmpty ? "No spots" : develop.spots.count == 1 ? "1 spot" : "\(develop.spots.count) spots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { develop.isRemoving = false }
                    .keyboardShortcut(.defaultAction)
                    .help("Close the Remove tool; spots keep working (Return)")
            }
        }
    }

    private var hint: String {
        if develop.selectedSpot != nil {
            return "Drag the dashed source to take the fill from elsewhere, or press / for another. Delete removes the spot."
        }
        return "Click a spot, or drag over a line or wire. Atelier picks a source next to it."
    }

    private func resetBrush() {
        develop.setSpotSize(DevelopSettings.Spot.defaultSize)
        develop.setSpotFeather(DevelopSettings.Spot.defaultFeather)
        develop.setSpotOpacity(100)
    }
}
