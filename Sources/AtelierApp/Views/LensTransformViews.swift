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
            GroupHeading(title: group.0)
            if group.1.first == .temperature {
                WhiteBalanceRow(develop: develop)
            }
            ForEach(group.1, id: \.self) { parameter in
                ParameterSlider(parameter: parameter, develop: develop)
            }
        }
    }
}

/// Lens Corrections: the RAW engine's profile corrections, then manual distortion and vignetting.
struct LensCorrectionsPanel: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Profile")
            Toggle("Enable Profile Corrections", isOn: Binding(
                get: { develop.lensCorrectionSupported && develop.settings.lensProfileCorrections },
                set: { develop.setLensProfileCorrections($0) }))
                .disabled(!develop.lensCorrectionSupported)
                .help("Distortion and vignetting corrections for this camera and lens, from Apple's RAW engine")
            Text(lensLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private typealias Mode = DevelopSettings.Upright.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Upright")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    uprightButton(nil, help: "No Upright correction")
                    uprightButton(.auto, help: "Balanced level, vertical and horizontal correction")
                    uprightButton(.guided, help: "Draw guides along edges that should be straight (⇧T)")
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
                Text("Drag along edges that should be vertical or horizontal, up to four guides. Drag a guide's end to move it; click a guide and press Delete to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .help("Enlarge the corrected photo so no empty edges show")
            ParameterGroups(panel: .transform, develop: develop)
        }
        .font(.callout)
    }

    private func uprightButton(_ mode: Mode?, help: String) -> some View {
        let active = mode == nil ? develop.settings.upright == nil && !develop.isGuiding
            : develop.settings.upright?.mode == mode || (mode == .guided && develop.isGuiding)
        return Button { develop.setUpright(mode) } label: {
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
        .help(help)
    }
}

/// Guided Upright: the whole corrected photo with the guides drawn on it. Guides are stored on
/// the photo before the Transform, so they follow it as the correction updates.
struct GuidedUprightView: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage

    private enum DragAction {
        case draw(start: CGPoint)
        case moveEnd(index: Int, isStart: Bool)
        case select(index: Int?)
    }

    @State private var action: DragAction?
    /// The guide being drawn or moved, in view points.
    @State private var draft: (CGPoint, CGPoint)?

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
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in dragChanged(drag, rect: rect) }
                .onEnded { drag in dragEnded(drag, rect: rect) })
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
        }
        .onChange(of: develop.assetID) { _, _ in
            action = nil
            draft = nil
        }
    }

    private var guides: [DevelopSettings.Guide] { develop.settings.upright?.guides ?? [] }

    private var hint: String {
        let count = guides.count
        if count >= DevelopSettings.Upright.maxGuides { return "Four guides drawn. Drag an end to adjust one." }
        return count == 0 ? "Drag along an edge that should be vertical or horizontal"
            : "Guide \(count) of 4. Draw another, or press Done"
    }

    // MARK: Mapping

    private func viewGuides(_ rect: CGRect) -> [(CGPoint, CGPoint)] {
        guard let geometry = develop.lensGeometry else { return [] }
        func view(_ point: DevelopSettings.MaskPoint) -> CGPoint {
            let output = geometry.outputPoint(fromSource: CGPoint(x: point.x, y: point.y))
            return CGPoint(x: rect.minX + output.x * rect.width, y: rect.minY + output.y * rect.height)
        }
        return guides.map { (view($0.start), view($0.end)) }
    }

    private func photoPoint(_ point: CGPoint, rect: CGRect) -> DevelopSettings.MaskPoint? {
        guard let geometry = develop.lensGeometry, rect.width > 0, rect.height > 0 else { return nil }
        let clampedX = min(max(point.x, rect.minX), rect.maxX), clampedY = min(max(point.y, rect.minY), rect.maxY)
        let source = geometry.sourcePoint(fromOutput: CGPoint(x: (clampedX - rect.minX) / rect.width,
                                                              y: (clampedY - rect.minY) / rect.height))
        return DevelopSettings.MaskPoint(x: Double(source.x), y: Double(source.y))
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

    private func beginAction(at point: CGPoint, rect: CGRect) -> DragAction {
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
        case .moveEnd(let index, let isStart):
            let lines = viewGuides(rect)
            guard lines.indices.contains(index) else { return }
            draft = isStart ? (drag.location, lines[index].1) : (lines[index].0, drag.location)
        case .select:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value, rect: CGRect) {
        defer {
            action = nil
            draft = nil
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
