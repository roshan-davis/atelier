import AppKit
import AtelierCore
import SwiftUI

/// Basic > Profile, as Lightroom's Profile menu.
struct ProfileRow: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(spacing: 8) {
            Text("Profile")
                .frame(width: 78, alignment: .leading)
            Picker("Profile", selection: Binding(get: { develop.settings.profile }, set: { develop.setProfile($0) })) {
                ForEach(DevelopSettings.Profile.allCases, id: \.self) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .font(.callout)
        .disabled(!develop.isRAW)
        .help(develop.isRAW
              ? "Camera Matching starts from the camera's look; Apple Neutral from Apple's flatter RAW render"
              : "Profiles apply to RAW files")
    }
}

/// Basic > Treatment: Color or Black & White, as at the top of Lightroom's Basic panel.
struct TreatmentRow: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(spacing: 8) {
            Text("Treatment")
                .frame(width: 78, alignment: .leading)
            Picker("Treatment", selection: Binding(get: { develop.settings.monochrome },
                                                   set: { develop.setMonochrome($0) })) {
                Text("Color").tag(false)
                Text("Black & White").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .font(.callout)
        .help("Black & White uses the B&W Mix in HSL / Color to set how bright each color becomes (V)")
    }
}

/// A panel's sliders under their group headings.
struct ParameterGroups: View {
    let panel: DevelopSettings.Panel
    @ObservedObject var develop: DevelopController

    private var groups: [(String, [DevelopSettings.Parameter])] {
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
        ForEach(groups, id: \.0) { group in
            if group.1.first?.isDefringe == true {
                DefringeGroup(develop: develop)
            } else {
                sliders(group)
            }
        }
    }

    @ViewBuilder
    private func sliders(_ group: (String, [DevelopSettings.Parameter])) -> some View {
        Group {
            if group.1.first == .exposure {
                HStack(alignment: .lastTextBaseline) {
                    GroupHeading(title: group.0) { develop.reset(group: group.0, parameters: group.1) }
                    Spacer()
                    if develop.isFindingAutoTone { ProgressView().controlSize(.mini) }
                    Button("Auto") { develop.autoTone() }
                        .controlSize(.small)
                        .disabled(develop.assetID == nil || develop.isFindingAutoTone)
                        .help("Sets Exposure, Highlights, Shadows, Whites and Blacks from the photo. Shift-double-click a slider's name to set just that one.")
                }
            } else {
                GroupHeading(title: group.0) { develop.reset(group: group.0, parameters: group.1) }
            }
            if group.1.first == .temperature {
                WhiteBalanceRow(develop: develop)
            }
            ForEach(group.1, id: \.self) { parameter in
                ParameterSlider(parameter: parameter, develop: develop)
            }
        }
    }
}

/// Lens Corrections: chromatic aberration and the RAW engine's profile corrections, then manual
/// distortion, Defringe and vignetting.
struct LensCorrectionsPanel: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Profile")
            Toggle("Remove Chromatic Aberration", isOn: Binding(
                get: { develop.settings.removeChromaticAberration },
                set: { develop.setRemoveChromaticAberration($0) }))
                .disabled(develop.assetID == nil)
                .help("Lines up the red and blue channels with green, measured from this photo, so red-cyan and blue-yellow edges toward the corners go away")
            Toggle("Enable Profile Corrections", isOn: Binding(
                get: { develop.lensCorrectionSupported && develop.settings.lensProfileCorrections },
                set: { develop.setLensProfileCorrections($0) }))
                .disabled(!develop.lensCorrectionSupported)
                .help("Distortion and vignetting corrections for this camera and lens, from Apple's RAW engine")
            Text(lensLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(lensLine)
            ParameterGroups(panel: .lensCorrections, develop: develop)
        }
        .font(.callout)
    }

    private var lensLine: String {
        guard develop.lensCorrectionSupported else {
            return develop.lensName.map { "\($0): no lens corrections for this photo" } ?? "No lens corrections for this photo"
        }
        return develop.lensName ?? "Lens corrections from the RAW file"
    }
}

/// Transform: Upright, Constrain Crop and the manual perspective sliders.
struct TransformPanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage(GuidedUprightView.loupeKey) private var showLoupe = true

    private typealias Mode = DevelopSettings.Upright.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Upright")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    uprightButton(nil, help: "No Upright correction")
                    uprightButton(.auto, help: "Balanced level, vertical and horizontal correction")
                    uprightButton(.guided, help: "Draw two to four guides along edges that should be straight (⇧T)")
                }
                GridRow {
                    uprightButton(.level, help: "Make horizontal lines level")
                    uprightButton(.vertical, help: "Level, and make vertical lines parallel")
                    uprightButton(.full, help: "Level, vertical and horizontal perspective")
                }
            }
            if develop.isFindingLines {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding straight lines…").foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if let message = develop.uprightMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if develop.isGuiding {
                Text("Drag along edges that should be vertical or horizontal. The photo straightens once there are two guides; draw up to four. Drag a guide's end to move it; click a guide and press Delete to remove it. If the correction pushes part of the photo out of the frame, turn on Show Whole Photo to see it, or lower Scale or ⌘⌥-drag the photo to bring it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show Loupe", isOn: $showLoupe)
                    .help("Magnify the photo around the pointer while you place a guide (O)")
                Toggle("Show Whole Photo", isOn: $develop.guidedShowsWholePhoto)
                    .help("Zoom out to the whole corrected photo, uncropped, so guides the correction pushed out of the frame show. Changes only the view.")
                HStack {
                    Button("Clear Guides") { develop.setGuides([]) }
                        .disabled(develop.settings.upright?.guides.isEmpty ?? true)
                    Spacer()
                    Button("Done") { develop.isGuiding = false }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            Toggle("Constrain Crop", isOn: Binding(get: { develop.settings.constrainCrop },
                                                   set: { develop.setConstrainCrop($0) }))
                .help("Crop to the largest area with no gray edges, as in Lightroom; the crop then stays inside the photo when you adjust it")
            ParameterGroups(panel: .transform, develop: develop)
        }
        .font(.callout)
    }

    private func uprightButton(_ mode: Mode?, help: String) -> some View {
        let active = mode == nil ? develop.settings.upright == nil && !develop.isGuiding
            : develop.settings.upright?.mode == mode || (mode == .guided && develop.isGuiding)
        return Button {
            develop.setUpright(mode, keepSettings: NSEvent.modifierFlags.contains(.option))
        } label: {
            Text(mode?.title ?? "Off")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(develop.isFindingLines)
        .help(mode == nil ? help : help + ". Resets the crop and the Transform sliders; ⌥-click to keep them.")
    }
}

/// Guided Upright, as in Lightroom: the photo as edited (crop included) with the guides drawn on
/// it. Guides are stored on the photo before the Transform, so they follow it as the correction
/// updates; a guide end the correction pushes out of the frame comes back with Scale or a
/// ⌘⌥-drag, which moves the photo through X and Y Offset.
struct GuidedUprightView: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage

    private enum DragAction {
        case draw(start: CGPoint)
        case moveEnd(index: Int, isStart: Bool)
        case select(index: Int?)
        case pan(startX: Double, startY: Double)
    }

    @State private var action: DragAction?
    /// The guide being drawn or moved, in view points.
    @State private var draft: (CGPoint, CGPoint)?
    /// The end being placed, for the loupe.
    @State private var loupePoint: CGPoint?
    @AppStorage(GuidedUprightView.loupeKey) private var showLoupe = true

    static let loupeKey = "guidedUprightShowsLoupe"

    private let color = Color(red: 0.2, green: 0.85, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            let rect = AIBrushView.fit(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Canvas { context, _ in
                    context.clip(to: Path(rect))
                    for (index, guide) in viewGuides(rect).enumerated() {
                        if case .moveEnd(let moving, _) = action, moving == index, draft != nil { continue }
                        drawGuide(guide, selected: develop.selectedGuide == index, in: &context)
                    }
                    if let draft { drawGuide(draft, selected: true, in: &context) }
                }
                .allowsHitTesting(false)
                Text(hint)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geometry.size.width / 2, y: 22)
                    .allowsHitTesting(false)
                if showLoupe, let loupePoint {
                    loupe(at: loupePoint, rect: rect, in: geometry.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in dragChanged(drag, rect: rect) }
                .onEnded { drag in dragEnded(drag, rect: rect) })
            .cursor { point in cursor(for: beginAction(at: point, rect: rect)) }
        }
        .onChange(of: develop.assetID) { _, _ in
            action = nil
            draft = nil
            loupePoint = nil
        }
    }

    private var guides: [DevelopSettings.Guide] { develop.settings.upright?.guides ?? [] }

    private var hint: String {
        let count = guides.count
        if count >= DevelopSettings.Upright.maxGuides { return "Four guides drawn. Drag an end to adjust one." }
        switch count {
        case 0: return "Drag along an edge that should be vertical or horizontal"
        case 1: return "Draw a second guide to straighten the photo"
        default: return "Guide \(count) of 4. Draw another, or press Done"
        }
    }

    // MARK: Mapping

    private func viewGuides(_ rect: CGRect) -> [(CGPoint, CGPoint)] {
        func view(_ point: DevelopSettings.MaskPoint) -> CGPoint? {
            guard let output = develop.guidedViewPoint(fromPhoto: CGPoint(x: point.x, y: point.y)) else { return nil }
            return CGPoint(x: rect.minX + output.x * rect.width, y: rect.minY + output.y * rect.height)
        }
        return guides.compactMap { guide in
            guard let a = view(guide.start), let b = view(guide.end) else { return nil }
            return (a, b)
        }
    }

    private func photoPoint(_ point: CGPoint, rect: CGRect) -> DevelopSettings.MaskPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let clampedX = min(max(point.x, rect.minX), rect.maxX), clampedY = min(max(point.y, rect.minY), rect.maxY)
        guard let source = develop.guidedPhotoPoint(fromView: CGPoint(x: (clampedX - rect.minX) / rect.width,
                                                                      y: (clampedY - rect.minY) / rect.height))
        else { return nil }
        return DevelopSettings.MaskPoint(x: Double(source.x), y: Double(source.y))
    }

    // MARK: Loupe

    /// Lightroom's loupe: the photo around the end being placed, magnified, beside the pointer.
    private func loupe(at point: CGPoint, rect: CGRect, in size: CGSize) -> some View {
        let diameter: CGFloat = 150, zoom: CGFloat = 3
        let offset = diameter / 2 + 24
        // Up and to the left of the pointer, or the other side near an edge.
        let x = point.x - offset - diameter / 2 < 0 ? point.x + offset : point.x - offset
        let y = point.y - offset - diameter / 2 < 0 ? point.y + offset : point.y - offset
        var lines = viewGuides(rect)
        if case .moveEnd(let index, _) = action, lines.indices.contains(index) { lines.remove(at: index) }
        if let draft { lines.append(draft) }
        return Canvas { context, canvas in
            let bounds = CGRect(origin: .zero, size: canvas)
            context.clip(to: Path(ellipseIn: bounds))
            context.fill(Path(bounds), with: .color(.black))
            var zoomed = context
            zoomed.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            zoomed.scaleBy(x: zoom, y: zoom)
            zoomed.translateBy(x: -point.x, y: -point.y)
            zoomed.clip(to: Path(rect))
            zoomed.draw(Image(nsImage: image).interpolation(.high), in: rect)
            for line in lines {
                var path = Path()
                path.move(to: line.0)
                path.addLine(to: line.1)
                zoomed.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 2.5 / zoom)
                zoomed.stroke(path, with: .color(color), lineWidth: 1 / zoom)
            }
            // Crosshair on the end being placed.
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            var cross = Path()
            cross.move(to: CGPoint(x: mid.x - 8, y: mid.y))
            cross.addLine(to: CGPoint(x: mid.x + 8, y: mid.y))
            cross.move(to: CGPoint(x: mid.x, y: mid.y - 8))
            cross.addLine(to: CGPoint(x: mid.x, y: mid.y + 8))
            context.stroke(cross, with: .color(.white), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 6)
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    // MARK: Drawing

    private func drawGuide(_ guide: (CGPoint, CGPoint), selected: Bool, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: guide.0)
        path.addLine(to: guide.1)
        context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: selected ? 4 : 3)
        context.stroke(path, with: .color(selected ? .white : color), lineWidth: selected ? 2 : 1.5)
        for point in [guide.0, guide.1] {
            let knob = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: knob), with: .color(.white))
            context.stroke(Path(ellipseIn: knob), with: .color(color), lineWidth: 1.5)
        }
    }

    // MARK: Dragging

    /// What the pointer shows over `point`: what a drag starting there would do.
    private func cursor(for action: DragAction) -> CursorShape {
        switch action {
        case .draw: return .crosshair
        case .moveEnd, .pan: return .grab
        case .select(let index): return index == nil ? .arrow : .link
        }
    }

    private func beginAction(at point: CGPoint, rect: CGRect) -> DragAction {
        if NSEvent.modifierFlags.contains([.command, .option]) {
            return .pan(startX: develop.settings[.transformOffsetX], startY: develop.settings[.transformOffsetY])
        }
        let lines = viewGuides(rect)
        for (index, line) in lines.enumerated() {
            if distance(point, line.0) < 9 { return .moveEnd(index: index, isStart: true) }
            if distance(point, line.1) < 9 { return .moveEnd(index: index, isStart: false) }
        }
        if let index = lines.firstIndex(where: { distanceToSegment(point, $0) < 6 }) { return .select(index: index) }
        if guides.count >= DevelopSettings.Upright.maxGuides { return .select(index: nil) }
        return .draw(start: point)
    }

    private func dragChanged(_ drag: DragGesture.Value, rect: CGRect) {
        if action == nil { action = beginAction(at: drag.startLocation, rect: rect) }
        guard let action else { return }
        switch action {
        case .draw(let start):
            draft = (start, drag.location)
            loupePoint = drag.location
        case .moveEnd(let index, let isStart):
            let lines = viewGuides(rect)
            guard lines.indices.contains(index) else { return }
            draft = isStart ? (drag.location, lines[index].1) : (lines[index].0, drag.location)
            loupePoint = drag.location
        case .pan(let startX, let startY):
            guard rect.width > 0, rect.height > 0 else { return }
            var dx = Double(drag.translation.width / rect.width), dy = Double(drag.translation.height / rect.height)
            // Shift keeps the move to one direction, as in Lightroom.
            if NSEvent.modifierFlags.contains(.shift) {
                if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
            }
            develop.dragTransformOffsets(from: (startX, startY), dx: dx, dy: dy)
        case .select:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value, rect: CGRect) {
        defer {
            action = nil
            draft = nil
            loupePoint = nil
        }
        guard let action else { return }
        switch action {
        case .draw(let start):
            guard distance(start, drag.location) > 12,
                  let a = photoPoint(start, rect: rect), let b = photoPoint(drag.location, rect: rect) else { return }
            develop.setGuides(guides + [DevelopSettings.Guide(start: a, end: b)])
            develop.selectedGuide = nil
        case .moveEnd(let index, let isStart):
            guard guides.indices.contains(index), let point = photoPoint(drag.location, rect: rect) else { return }
            var updated = guides
            if isStart { updated[index].start = point } else { updated[index].end = point }
            develop.setGuides(updated)
            develop.selectedGuide = index
        case .select(let index):
            develop.selectedGuide = index
        case .pan:
            break
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func distanceToSegment(_ p: CGPoint, _ line: (CGPoint, CGPoint)) -> CGFloat {
        let dx = line.1.x - line.0.x, dy = line.1.y - line.0.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return distance(p, line.0) }
        let t = min(1, max(0, ((p.x - line.0.x) * dx + (p.y - line.0.y) * dy) / length2))
        return distance(p, CGPoint(x: line.0.x + t * dx, y: line.0.y + t * dy))
    }
}

/// Lens Corrections > Defringe, as in Lightroom: the Fringe Color Selector, then an Amount and
/// a Hue range for purple and for green fringes.
struct DefringeGroup: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            GroupHeading(title: "Defringe") {
                develop.reset(group: "Defringe", parameters: DevelopSettings.Panel.lensCorrections.parameters.filter(\.isDefringe))
            }
            Spacer()
            PickerButton(develop: develop, kind: .fringe,
                         help: "Fringe Color Selector: zoom in, then click a purple or green fringe to set its Hue range and Amount")
        }
        ParameterSlider(parameter: .lensDefringePurpleAmount, develop: develop)
        HueRangeRow(color: .purple, develop: develop)
        ParameterSlider(parameter: .lensDefringeGreenAmount, develop: develop)
        HueRangeRow(color: .green, develop: develop)
    }
}

/// A Defringe Hue range: two ends on a strip of the colors it can cover.
struct HueRangeRow: View {
    let color: DevelopSettings.FringeColor
    @ObservedObject var develop: DevelopController

    var body: some View {
        let low = develop.settings[color.hueLow], high = develop.settings[color.hueHigh]
        HStack(spacing: 8) {
            Text(color.hueLow.label)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { develop.resetHueRange(color) }
                .help("Double-click to reset")
            HueRangeSlider(color: color, low: low, high: high,
                           onChange: { newLow, newHigh, moving in
                               develop.setHueRange(color, low: newLow, high: newHigh, moving: moving)
                           },
                           onOption: { held in develop.sliderPreview = held ? .defringeHue(color) : nil })
                .help("Drag an end to widen or narrow the range, or between the ends to move it. "
                      + SliderPreview.defringeHue(color).hint)
            Text("\(Int(low.rounded()))/\(Int(high.rounded()))")
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(low == color.hueLow.defaultValue && high == color.hueHigh.defaultValue
                                 ? Color.secondary : Color.primary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
        .frame(height: 20)
    }
}

/// Lightroom's two-ended hue slider: the track shows the slider's colors, dimmed outside the
/// range. Dragging an end moves it, dragging between the ends moves both, and the ends stay at
/// least `DevelopSettings.minimumHueSpan` apart.
struct HueRangeSlider: View {
    let color: DevelopSettings.FringeColor
    let low: Double
    let high: Double
    /// New low and high, and the end being dragged (nil when both move).
    let onChange: (Double, Double, DevelopSettings.Parameter?) -> Void
    var onOption: ((Bool) -> Void)?

    private enum Grab {
        case low, high
        case both(startLow: Double, startHigh: Double, startX: CGFloat)
    }

    @State private var grab: Grab?

    private var colors: [Color] {
        stride(from: 0.0, through: 100, by: 20).map {
            Color(hue: color.degrees($0).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.75, brightness: 0.95)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let midY = geometry.size.height / 2
            let lowX = low / 100 * width, highX = high / 100 * width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 5)
                    .offset(y: midY - 2.5)
                // Dim the colors outside the range.
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, lowX), height: 5)
                    .offset(y: midY - 2.5)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, width - highX), height: 5)
                    .offset(x: highX, y: midY - 2.5)
                ForEach([lowX, highX], id: \.self) { x in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .frame(width: 11, height: 11)
                        .offset(x: x - 5.5, y: midY - 5.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    onOption?(NSEvent.modifierFlags.contains(.option))
                    guard width > 0 else { return }
                    let value = min(100, max(0, Double(drag.location.x / width) * 100))
                    let current = grab ?? startGrab(at: drag.startLocation.x, width: width)
                    grab = current
                    switch current {
                    // An end stops at the minimum span rather than pushing the other.
                    case .low: onChange(min(value, high - DevelopSettings.minimumHueSpan), high, color.hueLow)
                    case .high: onChange(low, max(value, low + DevelopSettings.minimumHueSpan), color.hueHigh)
                    case .both(let startLow, let startHigh, let startX):
                        let span = startHigh - startLow
                        let shift = Double((drag.location.x - startX) / width) * 100
                        let newLow = min(100 - span, max(0, startLow + shift))
                        onChange(newLow, newLow + span, nil)
                    }
                }
                .onEnded { _ in
                    grab = nil
                    onOption?(false)
                })
        }
        .frame(height: 16)
        .onReceive(ModifierKeys.shared.$option) { held in
            if grab != nil { onOption?(held) }
        }
        .onDisappear {
            if grab != nil { onOption?(false) }
        }
    }

    /// An end when the drag starts on or outside it (the nearer one), both between them.
    private func startGrab(at x: CGFloat, width: CGFloat) -> Grab {
        let lowX = low / 100 * width, highX = high / 100 * width
        let toLow = abs(x - lowX), toHigh = abs(x - highX)
        if min(toLow, toHigh) <= 7 { return toLow <= toHigh ? .low : .high }
        if x > lowX, x < highX { return .both(startLow: low, startHigh: high, startX: x) }
        return toLow <= toHigh ? .low : .high
    }
}
