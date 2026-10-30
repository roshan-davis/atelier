import AppKit
import AtelierCore
import SwiftUI

/// The photo under the Masking tool: the same zoomable photo view as Develop, so zoom, panning
/// and the zoomed spot are shared with every other mode, with the masks drawn and edited on
/// top (`MaskOverlay`). Zoom with the zoom bar, Z, pinch or ⌘-scroll; scroll, Space-drag, or a
/// drag on empty photo moves around.
struct MaskEditorView: View {
    @ObservedObject var develop: DevelopController
    /// The live proxy; mask positions are measured against it.
    let image: NSImage
    /// The sharpest image for the current settings, drawn in the same place.
    let display: NSImage
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var onReport: (ZoomReport) -> Void

    var body: some View {
        ZoomableImageView(image: display, pixelSize: pixelSize, zoom: zoom, onReport: onReport, menu: { nil },
                          overlay: { [develop, image] frame in
                              AnyView(MaskOverlay(develop: develop, image: image, frame: frame))
                          })
    }
}

/// Draws the masks over the photo view and turns drags into drawing, painting and handle
/// moves. `frame` says where the photo is in the view as it zooms and scrolls.
private struct MaskOverlay: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage
    @ObservedObject var frame: PhotoFrame

    private typealias Point = DevelopSettings.MaskPoint
    private typealias Component = DevelopSettings.MaskComponent

    /// What the current drag is doing, decided when it starts.
    private enum DragAction {
        case drawLinear(start: CGPoint)
        case drawRadial(center: CGPoint)
        case drawBox(start: CGPoint)
        case paint(erasing: Bool)
        case movePin(original: Component, start: Point)
        case linearEnd(original: DevelopSettings.LinearGradient, isStart: Bool)
        case radialAxis(original: DevelopSettings.RadialGradient, isX: Bool)
        case radialRotate(original: DevelopSettings.RadialGradient)
        case selectPin(mask: UUID, component: UUID)
        case pan(last: CGPoint)
        case none
    }

    @State private var action: DragAction?
    @State private var draftLinear: DevelopSettings.LinearGradient?
    @State private var draftRadial: DevelopSettings.RadialGradient?
    @State private var draftBox: (CGPoint, CGPoint)?
    @State private var stroke: DevelopSettings.MaskStroke?
    @State private var hover: CGPoint?
    @StateObject private var keys = SpaceKeyMonitor()

    private let accent = Color(red: 0.95, green: 0.25, blue: 0.2)

    var body: some View {
        GeometryReader { geometry in
            let rect = frame.rect
            let space = MaskSpace(sourceSize: develop.sourceSize ?? image.size, crop: develop.crop, rect: rect,
                                  outputSize: image.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.clip(to: Path(rect))
                    drawStroke(in: &context, space: space)
                    drawPins(in: &context, space: space)
                    drawSelected(in: &context, space: space)
                    drawDrafts(in: &context, space: space)
                    drawBrushCursor(in: &context, space: space)
                }
                .allowsHitTesting(false)
                if let hint = develop.maskTool?.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: geometry.size.width / 2, y: 22)
                        .allowsHitTesting(false)
                }
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
            .cursor { point in cursor(for: beginAction(at: point, space: space)) }
        }
        .onAppear { keys.install() }
        .onDisappear { keys.remove() }
        .onChange(of: develop.assetID) { _, _ in
            action = nil
            stroke = nil
        }
    }

    /// A brush is ready: either the Brush tool, or a brush part is selected.
    private var isPainting: Bool {
        if let tool = develop.maskTool { return tool.kind == .brush }
        if case .brush = develop.selectedComponent?.shape { return true }
        return false
    }

    // MARK: Drawing

    private func drawStroke(in context: inout GraphicsContext, space: MaskSpace) {
        guard let stroke else { return }
        let width = space.viewLength(stroke.size)
        let points = stroke.points.map { space.viewPoint($0) }
        let color = stroke.erases ? Color.white.opacity(0.5) : accent.opacity(0.45)
        if points.count == 1, let p = points.first {
            context.fill(Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)),
                         with: .color(color))
        } else {
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// Pins of the parts that aren't selected; the selected one is drawn with its handles.
    private func drawPins(in context: inout GraphicsContext, space: MaskSpace) {
        for mask in develop.masks {
            for component in mask.components where component.id != develop.selectedComponentID {
                guard let pin = component.pin else { continue }
                let selectedMask = mask.id == develop.selectedMaskID
                pinShape(in: &context, at: space.viewPoint(pin), filled: false, dim: !selectedMask)
            }
        }
    }

    private func pinShape(in context: inout GraphicsContext, at point: CGPoint, filled: Bool, dim: Bool = false) {
        let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        context.fill(Path(ellipseIn: rect), with: .color(filled ? accent : Color.white.opacity(dim ? 0.55 : 0.9)))
        context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.7)), lineWidth: 1.5)
        if filled {
            context.fill(Path(ellipseIn: rect.insetBy(dx: 3.5, dy: 3.5)), with: .color(.black.opacity(0.75)))
        }
    }

    private func handle(in context: inout GraphicsContext, at point: CGPoint) {
        let rect = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: rect), with: .color(.white))
        context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.7)), lineWidth: 1)
    }

    private func drawSelected(in context: inout GraphicsContext, space: MaskSpace) {
        guard draftLinear == nil, draftRadial == nil, let component = develop.selectedComponent else { return }
        switch component.shape {
        case .linear(let gradient): drawLinear(gradient, in: &context, space: space, withHandles: true)
        case .radial(let gradient): drawRadial(gradient, in: &context, space: space, withHandles: true)
        case .brush:
            if let pin = component.pin { pinShape(in: &context, at: space.viewPoint(pin), filled: true) }
        case .subject(let selection):
            guard let box = selection.box, let pin = component.pin else { break }
            var outline = Path()
            outline.addLines(box.corners.map { space.viewPoint($0) })
            outline.closeSubpath()
            context.stroke(outline, with: .color(.black.opacity(0.5)), lineWidth: 3)
            context.stroke(outline, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            pinShape(in: &context, at: space.viewPoint(pin), filled: true)
        case .luminance: break
        }
    }

    private func drawDrafts(in context: inout GraphicsContext, space: MaskSpace) {
        if let draftLinear { drawLinear(draftLinear, in: &context, space: space, withHandles: false) }
        if let draftRadial { drawRadial(draftRadial, in: &context, space: space, withHandles: false) }
        if let draftBox {
            let (a, b) = draftBox
            let box = Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            context.stroke(box, with: .color(.black.opacity(0.5)), lineWidth: 3)
            context.stroke(box, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private func drawLinear(_ gradient: DevelopSettings.LinearGradient, in context: inout GraphicsContext,
                            space: MaskSpace, withHandles: Bool) {
        let a = space.viewPoint(gradient.start), b = space.viewPoint(gradient.end)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.001)
        // Lines across the photo, square to the gradient's direction.
        let across = CGPoint(x: -dy / length * 4000, y: dx / length * 4000)
        for (point, dashed) in [(a, false), (mid, true), (b, false)] {
            var path = Path()
            path.move(to: CGPoint(x: point.x - across.x, y: point.y - across.y))
            path.addLine(to: CGPoint(x: point.x + across.x, y: point.y + across.y))
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
        }
        if withHandles {
            handle(in: &context, at: a)
            handle(in: &context, at: b)
            pinShape(in: &context, at: mid, filled: true)
        }
    }

    private func drawRadial(_ gradient: DevelopSettings.RadialGradient, in context: inout GraphicsContext,
                            space: MaskSpace, withHandles: Bool) {
        let (center, u, v) = space.ellipse(gradient)
        let rx = hypot(u.x - center.x, u.y - center.y), ry = hypot(v.x - center.x, v.y - center.y)
        let rotation = atan2(u.y - center.y, u.x - center.x)
        let transform = CGAffineTransform(rotationAngle: rotation).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let outer = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)).applying(transform)
        context.stroke(outer, with: .color(.black.opacity(0.5)), lineWidth: 3)
        context.stroke(outer, with: .color(.white), lineWidth: 1)
        let inner = max(0.001, 1 - gradient.feather / 100)
        let feather = Path(ellipseIn: CGRect(x: -rx * inner, y: -ry * inner, width: rx * inner * 2, height: ry * inner * 2))
            .applying(transform)
        context.stroke(feather, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        guard withHandles else { return }
        for point in radialHandles(center: center, u: u, v: v) { handle(in: &context, at: point) }
        let top = rotateHandle(center: center, v: v)
        var stem = Path()
        stem.move(to: CGPoint(x: 2 * center.x - v.x, y: 2 * center.y - v.y))
        stem.addLine(to: top)
        context.stroke(stem, with: .color(.white.opacity(0.8)), lineWidth: 1)
        let knob = CGRect(x: top.x - 5, y: top.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: knob), with: .color(accent))
        context.stroke(Path(ellipseIn: knob), with: .color(.white), lineWidth: 1.5)
        pinShape(in: &context, at: center, filled: true)
    }

    private func radialHandles(center: CGPoint, u: CGPoint, v: CGPoint) -> [CGPoint] {
        [u, CGPoint(x: 2 * center.x - u.x, y: 2 * center.y - u.y), v, CGPoint(x: 2 * center.x - v.x, y: 2 * center.y - v.y)]
    }

    /// The rotate knob, 22 points past the far end of the second axis.
    private func rotateHandle(center: CGPoint, v: CGPoint) -> CGPoint {
        let dx = center.x - v.x, dy = center.y - v.y
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: center.x + dx + dx / length * 22, y: center.y + dy + dy / length * 22)
    }

    private func drawBrushCursor(in context: inout GraphicsContext, space: MaskSpace) {
        guard isPainting, let hover, space.rect.contains(hover) else { return }
        let diameter = space.viewLength(develop.brushSize)
        let outer = CGRect(x: hover.x - diameter / 2, y: hover.y - diameter / 2, width: diameter, height: diameter)
        context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.5)), lineWidth: 2.5)
        context.stroke(Path(ellipseIn: outer), with: .color(.white), lineWidth: 1)
        let hard = diameter * max(0, 1 - develop.brushFeather / 100)
        if hard > 2 {
            let inner = CGRect(x: hover.x - hard / 2, y: hover.y - hard / 2, width: hard, height: hard)
            context.stroke(Path(ellipseIn: inner), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if develop.brushErasing || NSEvent.modifierFlags.contains(.option) {
            var minus = Path()
            minus.move(to: CGPoint(x: hover.x - 4, y: hover.y))
            minus.addLine(to: CGPoint(x: hover.x + 4, y: hover.y))
            context.stroke(minus, with: .color(.white), lineWidth: 1.5)
        }
    }

    // MARK: Dragging

    private func dragChanged(_ drag: DragGesture.Value, space: MaskSpace) {
        hover = drag.location
        if action == nil {
            let begun = beginAction(at: drag.startLocation, space: space)
            if case .paint(let erasing) = begun { startStroke(at: drag.startLocation, erasing: erasing, space: space) }
            action = begun
        }
        guard let action else { return }
        switch action {
        case .drawLinear(let start):
            draftLinear = DevelopSettings.LinearGradient(start: space.maskPoint(start), end: space.maskPoint(drag.location))
        case .drawRadial(let center):
            draftRadial = space.radial(center: center, width: abs(drag.location.x - center.x),
                                       height: abs(drag.location.y - center.y), feather: 50)
        case .drawBox(let start):
            draftBox = (start, clamped(drag.location, to: space.rect))
        case .pan(let last):
            frame.pan?(CGSize(width: drag.location.x - last.x, height: drag.location.y - last.y))
            self.action = .pan(last: drag.location)
        case .paint:
            stroke?.points.append(space.maskPoint(clamped(drag.location, to: space.rect)))
        case .movePin(let original, let start):
            let now = space.maskPoint(drag.location)
            let dx = now.x - start.x, dy = now.y - start.y
            var moved = original
            switch original.shape {
            case .linear(var gradient):
                gradient.start = Point(x: gradient.start.x + dx, y: gradient.start.y + dy)
                gradient.end = Point(x: gradient.end.x + dx, y: gradient.end.y + dy)
                moved.shape = .linear(gradient)
            case .radial(var gradient):
                gradient.center = Point(x: gradient.center.x + dx, y: gradient.center.y + dy)
                moved.shape = .radial(gradient)
            case .subject(var selection):
                guard var box = selection.box else { return }
                box.x = min(max(box.x + dx, 0), 1 - box.width)
                box.y = min(max(box.y + dy, 0), 1 - box.height)
                selection.box = box
                moved.shape = .subject(selection)
            default: return
            }
            develop.updateComponent(moved)
        case .linearEnd(var gradient, let isStart):
            if isStart { gradient.start = space.maskPoint(drag.location) } else { gradient.end = space.maskPoint(drag.location) }
            replaceSelected(.linear(gradient))
        case .radialAxis(var gradient, let isX):
            // Measured on the photo itself, where the gradient's angle is defined.
            let c = space.sourcePixels(gradient.center), p = space.sourcePixels(fromView: drag.location)
            let radians = gradient.angle * .pi / 180
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            let along = isX ? abs(dx * cos(radians) + dy * sin(radians)) : abs(-dx * sin(radians) + dy * cos(radians))
            let radius = max(0.005, along / Double(space.longEdge))
            if isX { gradient.radiusX = radius } else { gradient.radiusY = radius }
            replaceSelected(.radial(gradient))
        case .radialRotate(var gradient):
            let c = space.sourcePixels(gradient.center), p = space.sourcePixels(fromView: drag.location)
            // The knob sits along the second axis, on the far side; find the angle that puts it under the pointer.
            let knob = space.sourcePixels(fromView: rotateHandle(center: space.ellipse(gradient).center, v: space.ellipse(gradient).v))
            let before = atan2(Double(knob.y - c.y), Double(knob.x - c.x))
            let now = atan2(Double(p.y - c.y), Double(p.x - c.x))
            gradient.angle += (now - before) * 180 / .pi
            gradient.angle = gradient.angle.truncatingRemainder(dividingBy: 360)
            replaceSelected(.radial(gradient))
            self.action = .radialRotate(original: gradient)
        case .selectPin, .none:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value, space: MaskSpace) {
        defer {
            action = nil
            draftLinear = nil
            draftRadial = nil
            draftBox = nil
        }
        guard let action else { return }
        let moved = hypot(drag.location.x - drag.startLocation.x, drag.location.y - drag.startLocation.y)
        switch action {
        case .drawLinear:
            if moved > 4, let draftLinear { develop.finishDrawing(.linear(draftLinear)) }
        case .drawRadial:
            if moved > 4, let draftRadial { develop.finishDrawing(.radial(draftRadial)) }
        case .drawBox(let start):
            let end = clamped(drag.location, to: space.rect)
            if abs(end.x - start.x) > 6, abs(end.y - start.y) > 6 {
                let box = DevelopSettings.MaskRect(space.maskPoint(start), space.maskPoint(end))
                develop.finishDrawing(.subject(DevelopSettings.Selection(box: box)))
            }
        case .paint:
            // The release point is part of the stroke too.
            stroke?.points.append(space.maskPoint(clamped(drag.location, to: space.rect)))
            guard let stroke else { return }
            self.stroke = nil
            if develop.maskTool?.kind == .brush {
                develop.finishDrawing(.brush([stroke]))
            } else {
                develop.addStroke(stroke)
            }
        case .selectPin(let mask, let component):
            develop.select(mask: mask, component: component)
        case .movePin(let original, _) where moved < 3:
            develop.select(mask: develop.selectedMaskID ?? UUID(), component: original.id)
        default:
            break
        }
    }

    /// What the pointer shows over `point`: what a drag starting there would do.
    private func cursor(for action: DragAction) -> CursorShape {
        switch action {
        case .drawLinear, .drawRadial, .drawBox, .paint: return .crosshair
        case .movePin, .linearEnd, .radialAxis, .pan: return .grab
        case .radialRotate: return .rotate
        case .selectPin: return .link
        case .none: return .arrow
        }
    }

    /// Decides what a drag starting at `point` does: drawing with the current tool, a handle
    /// of the selected part, a pin, or painting into the selected brush part. Changes nothing,
    /// so the cursor asks it too.
    private func beginAction(at point: CGPoint, space: MaskSpace) -> DragAction {
        if keys.spaceDown { return .pan(last: point) }
        if let tool = develop.maskTool {
            guard space.rect.contains(point) else { return .none }
            switch tool.kind {
            case .linear: return .drawLinear(start: point)
            case .radial: return .drawRadial(center: point)
            case .object: return .drawBox(start: point)
            case .brush: return painting
            case .luminance, .subject: return .none
            }
        }
        if let component = develop.selectedComponent {
            switch component.shape {
            case .linear(let gradient):
                let a = space.viewPoint(gradient.start), b = space.viewPoint(gradient.end)
                if distance(point, a) < 9 { return .linearEnd(original: gradient, isStart: true) }
                if distance(point, b) < 9 { return .linearEnd(original: gradient, isStart: false) }
                if distance(point, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) < 10 {
                    return .movePin(original: component, start: space.maskPoint(point))
                }
            case .radial(let gradient):
                let (center, u, v) = space.ellipse(gradient)
                if distance(point, rotateHandle(center: center, v: v)) < 9 { return .radialRotate(original: gradient) }
                let handles = radialHandles(center: center, u: u, v: v)
                if let index = handles.firstIndex(where: { distance(point, $0) < 9 }) {
                    return .radialAxis(original: gradient, isX: index < 2)
                }
                if distance(point, center) < 10 { return .movePin(original: component, start: space.maskPoint(point)) }
            case .subject:
                if let pin = component.pin, distance(point, space.viewPoint(pin)) < 10 {
                    return .movePin(original: component, start: space.maskPoint(point))
                }
            default:
                break
            }
        }
        // Another part's pin selects it.
        for mask in develop.masks.reversed() {
            for component in mask.components where component.id != develop.selectedComponentID {
                if let pin = component.pin, distance(point, space.viewPoint(pin)) < 9 {
                    return .selectPin(mask: mask.id, component: component.id)
                }
            }
        }
        if isPainting, space.rect.contains(point) { return painting }
        // Zoomed in, a drag on empty photo moves around it.
        return frame.canPan ? .pan(last: point) : .none
    }

    private var painting: DragAction {
        .paint(erasing: develop.brushErasing || NSEvent.modifierFlags.contains(.option))
    }

    private func startStroke(at point: CGPoint, erasing: Bool, space: MaskSpace) {
        stroke = DevelopSettings.MaskStroke(points: [space.maskPoint(point)], size: develop.brushSize,
                                            feather: develop.brushFeather, flow: develop.brushFlow, erases: erasing)
    }

    private func replaceSelected(_ shape: Component.Shape) {
        guard var component = develop.selectedComponent else { return }
        component.shape = shape
        develop.updateComponent(component)
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The Masking section of the Develop panel: the masks and their parts, then the selected
/// part's settings and the selected mask's sliders.
struct MasksPanel: View {
    @ObservedObject var develop: DevelopController
    @State private var renaming: UUID?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private typealias Kind = DevelopSettings.MaskComponent.Kind
    private typealias Mode = DevelopSettings.MaskComponent.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            maskList
            HStack(spacing: 6) {
                kindMenu(develop.masks.isEmpty ? "Create New Mask" : "New Mask") { develop.createMask($0) }
                    .help("Make a new mask: Brush (K), Linear Gradient (M), Radial Gradient (⇧M), Luminance Range or Select Subject")
                if develop.selectedMask != nil {
                    kindMenu("Add") { develop.addComponent($0, mode: .add) }
                        .help("Add a part to the selected mask")
                    kindMenu("Subtract") { develop.addComponent($0, mode: .subtract) }
                        .help("Cut a part out of the selected mask")
                }
            }
            .controlSize(.small)
            Toggle("Show Overlay", isOn: $develop.showMaskOverlay)
                .help("Tint the selected mask red on the photo (O)")
            if let tool = develop.maskTool {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: tool.kind.symbol).foregroundStyle(.secondary)
                    Text(tool.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Cancel") { develop.maskTool = nil }.controlSize(.small)
                }
            }
            if let message = develop.maskMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if develop.maskTool?.kind == .brush || isBrushSelected {
                brushSettings
            }
            if let component = develop.selectedComponent {
                componentSettings(component)
            }
            if let mask = develop.selectedMask {
                Divider()
                adjustments(mask)
            }
            if develop.selectedMask == nil, develop.masks.isEmpty, develop.maskTool == nil {
                Text("Masks limit an adjustment to part of the photo: a graduated sky, a lighter face, a darker corner. Create a mask, then move its sliders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { develop.isMasking = false }
                    .keyboardShortcut(.defaultAction)
                    .help("Close Masking; masks keep working (Return)")
            }
        }
    }

    private var isBrushSelected: Bool {
        if case .brush = develop.selectedComponent?.shape { return develop.maskTool == nil }
        return false
    }

    private func kindMenu(_ title: String, action: @escaping (Kind) -> Void) -> some View {
        Menu(title) {
            ForEach(Kind.allCases, id: \.self) { kind in
                Button { action(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
        }
        .fixedSize()
    }

    // MARK: List

    private var maskList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(develop.masks) { mask in
                maskRow(mask)
                if mask.id == develop.selectedMaskID {
                    ForEach(mask.components) { component in
                        componentRow(component, in: mask)
                    }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
    }

    private func maskRow(_ mask: DevelopSettings.Mask) -> some View {
        let selected = mask.id == develop.selectedMaskID && develop.selectedComponentID == nil
        return HStack(spacing: 6) {
            Button { develop.toggleHidden(mask.id) } label: {
                Image(systemName: mask.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(mask.isHidden ? .secondary : .primary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(mask.isHidden ? "Show this mask's effect" : "Hide this mask's effect")
            Image(systemName: mask.components.first?.kind.symbol ?? "circle.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if renaming == mask.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitRename(mask.id) }
                    .onChange(of: nameFocused) { if !nameFocused { commitRename(mask.id) } }
                    .onExitCommand { renaming = nil }
            } else {
                Text(mask.name)
                    .lineLimit(1)
                    .fontWeight(mask.id == develop.selectedMaskID ? .semibold : .regular)
                    .onTapGesture(count: 2) { startRename(mask) }
                if mask.inverted {
                    Text("Inverted").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { develop.select(mask: mask.id) }
        .contextMenu {
            Button("Rename…") { startRename(mask) }
            Button("Duplicate \(mask.name)") { develop.duplicateMask(mask.id) }
            Button(mask.inverted ? "Uninvert" : "Invert") { develop.invertMask(mask.id) }
            Menu("Intersect Mask With") {
                ForEach(Kind.allCases, id: \.self) { kind in
                    Button(kind.title) {
                        develop.select(mask: mask.id)
                        develop.addComponent(kind, mode: .intersect)
                    }
                }
            }
            Divider()
            Button("Delete \(mask.name)", role: .destructive) { develop.deleteMask(mask.id) }
        }
    }

    private func componentRow(_ component: DevelopSettings.MaskComponent, in mask: DevelopSettings.Mask) -> some View {
        let selected = component.id == develop.selectedComponentID
        let isFirst = component.id == mask.components.first?.id
        return HStack(spacing: 6) {
            Image(systemName: isFirst ? "circle.fill" : component.mode.symbol)
                .font(.caption2)
                .foregroundStyle(component.mode == .subtract ? Color.orange : .secondary)
                .frame(width: 16)
                .help(isFirst ? "The first part" : component.mode.title)
            Image(systemName: component.kind.symbol).frame(width: 16)
            Text(component.kind.title).lineLimit(1)
            if component.inverted {
                Text("Inverted").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, 22)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(selected ? Color.accentColor.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { develop.select(mask: mask.id, component: component.id) }
        .contextMenu {
            Button(component.inverted ? "Uninvert" : "Invert") { develop.invertComponent(component.id, in: mask.id) }
            if !isFirst {
                ForEach(Mode.allCases, id: \.self) { mode in
                    if mode != component.mode {
                        Button("Switch to \(mode.title)") { develop.setMode(mode, of: component.id, in: mask.id) }
                    }
                }
            }
            Divider()
            Button("Delete \(component.kind.title)", role: .destructive) { develop.deleteComponent(component.id, in: mask.id) }
        }
    }

    private func startRename(_ mask: DevelopSettings.Mask) {
        draftName = mask.name
        renaming = mask.id
        nameFocused = true
    }

    private func commitRename(_ id: UUID) {
        guard renaming == id else { return }
        develop.renameMask(id, to: draftName)
        renaming = nil
    }

    // MARK: Part settings

    private var brushSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupHeading(title: "Brush")
            SliderRow(label: "Size", value: Binding(get: { develop.brushSize * 100 }, set: { develop.brushSize = $0 / 100 }),
                      range: 0.5...40, step: 0.1, origin: 0.5, format: { String(format: "%.1f", $0) },
                      reset: { develop.brushSize = 0.06 })
            SliderRow(label: "Feather", value: $develop.brushFeather, range: 0...100, step: 1, origin: 0)
            SliderRow(label: "Flow", value: $develop.brushFlow, range: 1...100, step: 1, origin: 1)
            Picker("Brush", selection: $develop.brushErasing) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Erase takes paint away; hold ⌥ while painting to erase for one stroke")
        }
    }

    @ViewBuilder
    private func componentSettings(_ component: DevelopSettings.MaskComponent) -> some View {
        switch component.shape {
        case .radial(let gradient):
            VStack(alignment: .leading, spacing: 6) {
                GroupHeading(title: "Radial Gradient")
                SliderRow(label: "Feather", value: Binding(get: { gradient.feather }, set: { value in
                    var changed = gradient
                    changed.feather = value
                    update(component, .radial(changed))
                }), range: 0...100, step: 1, origin: 50)
                invertToggle(component)
            }
        case .luminance(let range):
            VStack(alignment: .leading, spacing: 6) {
                GroupHeading(title: "Luminance Range")
                LuminanceStrip(range: range)
                    .frame(height: 10)
                SliderRow(label: "From", value: Binding(get: { range.low }, set: { value in
                    var changed = range
                    changed.low = value
                    update(component, .luminance(changed))
                }), range: 0...100, step: 1, origin: 0)
                SliderRow(label: "To", value: Binding(get: { range.high }, set: { value in
                    var changed = range
                    changed.high = value
                    update(component, .luminance(changed))
                }), range: 0...100, step: 1, origin: 100)
                SliderRow(label: "Smoothness", value: Binding(get: { range.smoothness }, set: { value in
                    var changed = range
                    changed.smoothness = value
                    update(component, .luminance(changed))
                }), range: 0...100, step: 1, origin: 50)
                invertToggle(component)
            }
        case .linear:
            VStack(alignment: .leading, spacing: 6) {
                GroupHeading(title: "Linear Gradient")
                Text("Drag the pin to move it, the end handles to widen or turn it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                invertToggle(component)
            }
        case .subject(let selection):
            VStack(alignment: .leading, spacing: 6) {
                GroupHeading(title: selection.box == nil ? "Select Subject" : "Select Object")
                SliderRow(label: "Feather", value: Binding(get: { selection.feather }, set: { value in
                    var changed = selection
                    changed.feather = value
                    update(component, .subject(changed))
                }), range: 0...100, step: 1, origin: 20)
                Text(selection.box == nil
                     ? "Found on this Mac with Apple's Vision. Invert it to adjust the background."
                     : "Found by Vision inside the box. Drag the pin to move the box, or draw a new one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                invertToggle(component)
            }
        case .brush:
            invertToggle(component)
        }
    }

    private func invertToggle(_ component: DevelopSettings.MaskComponent) -> some View {
        Toggle("Invert", isOn: Binding(get: { component.inverted }, set: { _ in
            if let mask = develop.selectedMaskID { develop.invertComponent(component.id, in: mask) }
        }))
        .help("Select everything except this \(component.kind.title)")
    }

    private func update(_ component: DevelopSettings.MaskComponent, _ shape: DevelopSettings.MaskComponent.Shape) {
        var changed = component
        changed.shape = shape
        develop.updateComponent(changed)
    }

    // MARK: Sliders

    private func adjustments(_ mask: DevelopSettings.Mask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mask.name).font(.callout.weight(.semibold))
                Spacer()
                Button("Reset Sliders") { develop.resetMaskSliders() }
                    .controlSize(.small)
                    .disabled(!mask.hasAdjustments && mask.amount == 100)
            }
            SliderRow(label: "Amount", value: Binding(get: { mask.amount }, set: { develop.setMaskAmount($0) }),
                      range: 0...200, step: 1, origin: 100, format: { "\(Int($0.rounded()))%" })
            // One Invert at a time, for what is selected: the part's sits with its settings
            // above, the whole mask's here when the mask itself is selected.
            if develop.selectedComponentID == nil {
                Toggle("Invert", isOn: Binding(get: { mask.inverted }, set: { _ in develop.invertMask(mask.id) }))
                    .help("Apply the sliders everywhere except the mask")
            }
            ForEach(DevelopSettings.LocalParameter.allCases, id: \.self) { parameter in
                if parameter.group > 0, parameter == DevelopSettings.LocalParameter.allCases.first(where: { $0.group == parameter.group }) {
                    Spacer().frame(height: 2)
                }
                SliderRow(label: parameter.label,
                          value: Binding(get: { mask[parameter] }, set: { develop.setMaskValue(parameter, to: $0) }),
                          range: parameter.range, step: parameter == .exposure ? 0.05 : 1, origin: 0,
                          gradient: gradient(parameter),
                          format: { value in
                              if parameter == .exposure { return String(format: "%+.2f", value) }
                              return value == 0 ? "0" : String(format: parameter.range.lowerBound < 0 ? "%+.0f" : "%.0f", value)
                          })
            }
        }
    }

    private func gradient(_ parameter: DevelopSettings.LocalParameter) -> [Color]? {
        switch parameter {
        case .temperature: return [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)]
        case .tint: return [Color(red: 0.3, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.85)]
        case .saturation: return [Color.gray, Color(red: 1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.6, blue: 1)]
        default: return nil
        }
    }
}

/// Black to white with the chosen range marked, above the Luminance Range sliders.
private struct LuminanceStrip: View {
    let range: DevelopSettings.LuminanceRange

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let low = min(range.low, range.high) / 100, high = max(range.low, range.high) / 100
            ZStack(alignment: .leading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: max(2, width * (high - low)))
                    .offset(x: width * low)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

/// Space held while masking: drags pan instead of drawing, as in Lightroom.
@MainActor
final class SpaceKeyMonitor: ObservableObject {
    @Published private(set) var spaceDown = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        spaceDown = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49, !(event.window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        spaceDown = event.type == .keyDown
        return nil
    }
}
