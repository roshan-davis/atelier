import AppKit
import AtelierCore
import SwiftUI

typealias Crop = DevelopSettings.Crop

/// Aspect ratios offered by the crop tool, as Lightroom lists them.
enum CropAspect: Hashable, Identifiable {
    case original, free
    case ratio(Double, String)

    static let presets: [CropAspect] = [
        .original, .free,
        .ratio(1, "1 × 1"), .ratio(5.0 / 4, "4 × 5  /  8 × 10"), .ratio(7.0 / 5, "5 × 7"),
        .ratio(3.0 / 2, "2 × 3  /  4 × 6"), .ratio(4.0 / 3, "3 × 4"), .ratio(16.0 / 10, "16 × 10"),
        .ratio(16.0 / 9, "16 × 9"),
    ]

    var id: String { label }

    var label: String {
        switch self {
        case .original: return "Original"
        case .free: return "Free"
        case .ratio(_, let label): return label
        }
    }

    /// Width / height in landscape, or nil for free.
    func value(imageAspect: Double) -> Double? {
        switch self {
        case .original: return imageAspect
        case .free: return nil
        case .ratio(let value, _): return value
        }
    }

    /// The preset matching a locked aspect, in either orientation.
    static func matching(_ aspect: Double?, imageAspect: Double) -> CropAspect {
        guard let aspect else { return .free }
        let landscape = aspect >= 1 ? aspect : 1 / aspect
        let original = imageAspect >= 1 ? imageAspect : 1 / imageAspect
        if abs(landscape - original) < 0.002 { return .original }
        for preset in presets {
            if case .ratio(let value, _) = preset, abs(value - landscape) < 0.002 { return preset }
        }
        return .free
    }
}

/// Geometry edits shared by the crop panel, the crop overlay and the key commands.
extension Crop {
    /// Applies an aspect ratio around the crop's center, keeping its orientation, at the
    /// largest size that fits. `aspect` is landscape width / height; nil unlocks.
    func withAspect(_ aspect: Double?, imageAspect: Double, onPhoto: ((CGPoint) -> Bool)? = nil) -> Crop {
        var copy = self
        guard var aspect else {
            copy.lockedAspect = nil
            return copy
        }
        let portrait = width * imageAspect < height
        if portrait, aspect > 1 { aspect = 1 / aspect }
        copy.lockedAspect = aspect
        let size = Crop.centered(aspect: aspect, imageAspect: imageAspect)
        let cx = x + width / 2, cy = y + height / 2
        copy.width = size.width
        copy.height = size.height
        copy.x = min(max(0, cx - size.width / 2), 1 - size.width)
        copy.y = min(max(0, cy - size.height / 2), 1 - size.height)
        return copy.fitted(imageAspect: imageAspect, onPhoto: onPhoto)
    }

    /// Swaps the crop between landscape and portrait at the largest size that fits.
    func switchedOrientation(imageAspect: Double, onPhoto: ((CGPoint) -> Bool)? = nil) -> Crop {
        let target = 1 / (lockedAspect ?? (width * imageAspect) / height)
        let size = Crop.centered(aspect: target, imageAspect: imageAspect)
        var copy = self
        let cx = x + width / 2, cy = y + height / 2
        copy.width = size.width
        copy.height = size.height
        copy.x = min(max(0, cx - size.width / 2), 1 - size.width)
        copy.y = min(max(0, cy - size.height / 2), 1 - size.height)
        if lockedAspect != nil { copy.lockedAspect = target }
        return copy.fitted(imageAspect: imageAspect, onPhoto: onPhoto)
    }

    /// A quarter turn; the crop frame turns with the photo.
    func turned(clockwise: Bool) -> Crop {
        var copy = self
        copy.quarterTurns = ((quarterTurns + (clockwise ? 1 : 3)) % 4)
        if clockwise {
            copy.x = 1 - y - height
            copy.y = x
        } else {
            copy.x = y
            copy.y = 1 - x - width
        }
        copy.width = height
        copy.height = width
        copy.lockedAspect = lockedAspect.map { 1 / $0 }
        return copy
    }

    func flipped(horizontally: Bool) -> Crop {
        var copy = self
        if horizontally {
            copy.flipHorizontal.toggle()
            copy.x = 1 - x - width
        } else {
            copy.flipVertical.toggle()
            copy.y = 1 - y - height
        }
        copy.angle = -angle
        return copy
    }

    /// The crop between `self` and `target` closest to `target` that stays on the photo.
    func constrained(toward target: Crop, imageAspect: Double, onPhoto: ((CGPoint) -> Bool)? = nil) -> Crop {
        if target.fits(imageAspect: imageAspect, onPhoto: onPhoto) { return target }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            if interpolated(to: target, t).fits(imageAspect: imageAspect, onPhoto: onPhoto) { low = t } else { high = t }
        }
        return interpolated(to: target, low)
    }

    private func interpolated(to target: Crop, _ t: Double) -> Crop {
        var copy = target
        copy.x = x + (target.x - x) * t
        copy.y = y + (target.y - y) * t
        copy.width = width + (target.width - width) * t
        copy.height = height + (target.height - height) * t
        return copy
    }
}

/// Where the straightened photo and the crop frame sit in the view.
private struct CropLayout {
    let imageAspect: Double
    let angle: Double
    /// Points per unit of photo height.
    let scale: CGFloat
    let center: CGPoint

    init(viewSize: CGSize, imageAspect: Double, angle: Double) {
        self.imageAspect = imageAspect
        self.angle = angle
        let radians = angle * .pi / 180
        let bounds = Self.boundingSize(imageAspect: imageAspect, radians: radians)
        let padding: CGFloat = 28
        scale = max(1, min((viewSize.width - padding * 2) / bounds.width, (viewSize.height - padding * 2) / bounds.height))
        center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    static func boundingSize(imageAspect: Double, radians: Double) -> CGSize {
        let c = abs(cos(radians)), s = abs(sin(radians))
        return CGSize(width: imageAspect * c + s, height: imageAspect * s + c)
    }

    /// The turned photo's frame before straightening; crop fractions are measured in it.
    var frame: CGRect {
        CGRect(x: center.x - imageAspect * scale / 2, y: center.y - scale / 2,
               width: imageAspect * scale, height: scale)
    }

    func rect(for crop: Crop) -> CGRect {
        let frame = self.frame
        return CGRect(x: frame.minX + crop.x * frame.width, y: frame.minY + crop.y * frame.height,
                      width: crop.width * frame.width, height: crop.height * frame.height)
    }
}

/// The crop tool over the photo: drag a corner or edge to resize, inside to move, and outside
/// to straighten, as in Lightroom.
struct CropEditorView: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage

    private enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move, rotate
    }

    @State private var dragStart: Crop?
    @State private var handle: Handle?
    @State private var startAngle = 0.0
    @AppStorage(CropGuidePreference.guideKey) private var guide: CropGuide = .thirds
    @AppStorage(CropGuidePreference.orientationKey) private var guideOrientation = 0
    @AppStorage(CropGuidePreference.visibilityKey) private var guideVisibility: CropGuideVisibility = .always
    @AppStorage(CropGuidePreference.widthKey) private var guideWidth = CropGuideLook.standard.width
    @AppStorage(CropGuidePreference.opacityKey) private var guideOpacity = CropGuideLook.standard.opacity
    @AppStorage(CropGuidePreference.colorKey) private var guideColor = CropGuidePreference.defaultColor

    var body: some View {
        GeometryReader { geometry in
            let crop = develop.crop
            let layout = CropLayout(viewSize: geometry.size, imageAspect: develop.orientedAspect, angle: crop.angle)
            let rect = layout.rect(for: crop)
            ZStack(alignment: .topLeading) {
                if develop.imageIsWhole {
                    // The photo renders upright and the view turns it, so straightening follows the
                    // pointer at once instead of stretching the last render until the next one lands.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.frame.width, height: layout.frame.height)
                        .rotationEffect(.degrees(crop.angle))
                        .position(x: layout.frame.midX, y: layout.frame.midY)
                } else {
                    // Just opened: the cropped render is still showing. It is exactly what lies inside
                    // the crop frame, so place it there until the whole photo arrives around it.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                CropGuideLines(path: guidePath(in: rect),
                               look: CropGuidePreference.look(width: guideWidth, opacity: guideOpacity, color: guideColor),
                               dragging: handle != nil)
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                handles(in: rect)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { drag in changed(drag, layout: layout) }
                .onEnded { _ in
                    dragStart = nil
                    handle = nil
                })
            .cursor { point in cursor(for: hit(point, rect: rect)) }
        }
    }

    /// The chosen guide overlay inside the frame (Grid, Thirds, … Golden Spiral; O and ⇧O), or
    /// the fine grid while straightening, as in Lightroom. Its lines come from `CropGuide`.
    private func guidePath(in rect: CGRect) -> Path {
        let aspect = rect.height > 0 ? Double(rect.width / rect.height) : 1
        let lines: [[CGPoint]]
        switch guideVisibility {
        case .never: lines = []
        case .whileDragging where handle == nil: lines = []
        default:
            lines = handle == .rotate ? CropGuide.straightenGrid(aspect: aspect)
                : guide.polylines(aspect: aspect, orientation: guideOrientation)
        }
        return Path { path in
            for line in lines {
                path.addLines(line.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            }
        }
    }

    private func handles(in rect: CGRect) -> some View {
        let length: CGFloat = 18, thickness: CGFloat = 3
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        return Path { path in
            for (point, dx, dy) in corners {
                path.addRect(CGRect(x: dx > 0 ? point.x - thickness / 2 : point.x - length + thickness / 2,
                                    y: point.y - thickness / 2, width: length, height: thickness))
                path.addRect(CGRect(x: point.x - thickness / 2,
                                    y: dy > 0 ? point.y - thickness / 2 : point.y - length + thickness / 2,
                                    width: thickness, height: length))
            }
            for point in [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)] {
                path.addRect(CGRect(x: point.x - length / 2, y: point.y - thickness / 2, width: length, height: thickness))
            }
            for point in [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] {
                path.addRect(CGRect(x: point.x - thickness / 2, y: point.y - length / 2, width: thickness, height: length))
            }
        }
        .fill(Color.white)
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    private func hit(_ point: CGPoint, rect: CGRect) -> Handle {
        let tolerance: CGFloat = 10
        let nearLeft = abs(point.x - rect.minX) < tolerance, nearRight = abs(point.x - rect.maxX) < tolerance
        let nearTop = abs(point.y - rect.minY) < tolerance, nearBottom = abs(point.y - rect.maxY) < tolerance
        let withinX = point.x > rect.minX - tolerance && point.x < rect.maxX + tolerance
        let withinY = point.y > rect.minY - tolerance && point.y < rect.maxY + tolerance
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if nearTop, withinX { return .top }
        if nearBottom, withinX { return .bottom }
        if nearLeft, withinY { return .left }
        if nearRight, withinY { return .right }
        return rect.contains(point) ? .move : .rotate
    }

    /// As in Lightroom: a hand inside the frame, resize arrows on its edges and corners, and a
    /// curved arrow outside it for straightening.
    private func cursor(for handle: Handle) -> CursorShape {
        switch handle {
        case .move: return .grab
        case .rotate: return .rotate
        case .left: return .resize(.left)
        case .right: return .resize(.right)
        case .top: return .resize(.top)
        case .bottom: return .resize(.bottom)
        case .topLeft: return .resize(.topLeft)
        case .topRight: return .resize(.topRight)
        case .bottomLeft: return .resize(.bottomLeft)
        case .bottomRight: return .resize(.bottomRight)
        }
    }

    private func changed(_ drag: DragGesture.Value, layout: CropLayout) {
        let imageAspect = develop.orientedAspect
        if dragStart == nil {
            dragStart = develop.crop
            handle = hit(drag.startLocation, rect: layout.rect(for: develop.crop))
            startAngle = develop.crop.angle
        }
        guard let start = dragStart, let handle else { return }
        let frame = layout.frame
        let dx = Double(drag.translation.width / frame.width)
        let dy = Double(drag.translation.height / frame.height)

        var target = start
        switch handle {
        case .rotate:
            let center = CGPoint(x: layout.rect(for: start).midX, y: layout.rect(for: start).midY)
            let a0 = atan2(drag.startLocation.y - center.y, drag.startLocation.x - center.x)
            let a1 = atan2(drag.location.y - center.y, drag.location.x - center.x)
            var angle = startAngle + Double(a1 - a0) * 180 / .pi
            angle = min(45, max(-45, (angle * 10).rounded() / 10))
            target.angle = angle
            develop.setCrop(target.fitted(imageAspect: imageAspect, onPhoto: develop.cropBounds))
            return
        case .move:
            target.x = min(max(0, start.x + dx), 1 - start.width)
            target.y = min(max(0, start.y + dy), 1 - start.height)
        default:
            target = resized(start, handle: handle, dx: dx, dy: dy, imageAspect: imageAspect)
        }
        develop.setCrop(start.constrained(toward: target, imageAspect: imageAspect, onPhoto: develop.cropBounds))
    }

    private func resized(_ start: Crop, handle: Handle, dx: Double, dy: Double, imageAspect: Double) -> Crop {
        let minSize = 0.04
        var left = start.x, right = start.x + start.width
        var top = start.y, bottom = start.y + start.height
        switch handle {
        case .topLeft: left += dx; top += dy
        case .top: top += dy
        case .topRight: right += dx; top += dy
        case .right: right += dx
        case .bottomRight: right += dx; bottom += dy
        case .bottom: bottom += dy
        case .bottomLeft: left += dx; bottom += dy
        case .left: left += dx
        default: break
        }
        left = min(max(0, left), right - minSize)
        right = max(min(1, right), left + minSize)
        top = min(max(0, top), bottom - minSize)
        bottom = max(min(1, bottom), top + minSize)
        var crop = start
        crop.x = left
        crop.y = top
        crop.width = right - left
        crop.height = bottom - top

        guard let aspect = start.lockedAspect else { return crop }
        // Height in photo-height units for a given width in photo-width units.
        let heightFor = { (width: Double) in width * imageAspect / aspect }
        let widthFor = { (height: Double) in height * aspect / imageAspect }
        switch handle {
        case .left, .right:
            crop.height = heightFor(crop.width)
            crop.y = start.y + (start.height - crop.height) / 2
        case .top, .bottom:
            crop.width = widthFor(crop.height)
            crop.x = start.x + (start.width - crop.width) / 2
        default:
            // Corners follow whichever side moved further, anchored at the opposite corner.
            if abs(dx) * imageAspect >= abs(dy) {
                crop.height = heightFor(crop.width)
            } else {
                crop.width = widthFor(crop.height)
            }
            if handle == .topLeft || handle == .bottomLeft { crop.x = start.x + start.width - crop.width }
            if handle == .topLeft || handle == .topRight { crop.y = start.y + start.height - crop.height }
        }
        return crop
    }
}

/// The Crop & Straighten panel shown while the crop tool is open.
struct CropPanel: View {
    @ObservedObject var develop: DevelopController

    @AppStorage(CropGuidePreference.guideKey) private var guide: CropGuide = .thirds
    @AppStorage(CropGuidePreference.visibilityKey) private var guideVisibility: CropGuideVisibility = .always
    @AppStorage(CropGuidePreference.widthKey) private var guideWidth = CropGuideLook.standard.width
    @AppStorage(CropGuidePreference.opacityKey) private var guideOpacity = CropGuideLook.standard.opacity
    @AppStorage(CropGuidePreference.colorKey) private var guideColor = CropGuidePreference.defaultColor
    @Environment(\.openSettings) private var openSettings

    private var lineStyle: CropGuideLineStyle? {
        CropGuideLineStyle.matching(CropGuidePreference.look(width: guideWidth, opacity: guideOpacity, color: guideColor))
    }

    private var crop: Crop { develop.crop }
    private var imageAspect: Double { develop.orientedAspect }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Aspect").frame(width: 78, alignment: .leading)
                Picker("Aspect", selection: Binding(
                    get: { CropAspect.matching(crop.lockedAspect, imageAspect: imageAspect) },
                    set: { aspect in
                        develop.setCrop(crop.withAspect(aspect.value(imageAspect: imageAspect), imageAspect: imageAspect,
                                                        onPhoto: develop.cropBounds))
                    })) {
                    ForEach(CropAspect.presets) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button {
                    develop.setCrop(crop.switchedOrientation(imageAspect: imageAspect, onPhoto: develop.cropBounds))
                } label: {
                    Image(systemName: "rectangle.portrait.rotate")
                }
                .buttonStyle(.borderless)
                .help("Switch between landscape and portrait (X)")
                Button {
                    // Locking keeps the current frame exactly.
                    var toggled = crop
                    toggled.lockedAspect = crop.lockedAspect == nil ? crop.width * imageAspect / crop.height : nil
                    develop.setCrop(toggled)
                } label: {
                    Image(systemName: crop.lockedAspect == nil ? "lock.open" : "lock.fill")
                }
                .buttonStyle(.borderless)
                .help(crop.lockedAspect == nil ? "Lock the aspect ratio" : "Unlock the aspect ratio")
            }
            HStack(spacing: 8) {
                Text("Overlay").frame(width: 78, alignment: .leading)
                Picker("Overlay", selection: $guide) {
                    ForEach(CropGuide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .help("The guide drawn inside the crop (O picks the next one)")
                Button { CropGuidePreference.turn() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(guide.orientationCount == 1)
                .help(guide.orientationCount == 1 ? "This overlay looks the same every way round"
                      : "Cycle the overlay's orientation (⇧O)")
                Menu {
                    Picker("Show", selection: $guideVisibility) {
                        ForEach(CropGuideVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Section("Lines") {
                        ForEach(CropGuideLineStyle.allCases, id: \.self) { style in
                            Toggle(style.title, isOn: Binding(get: { lineStyle == style }, set: { _ in
                                guideWidth = style.width
                                guideOpacity = style.opacity
                            }))
                        }
                        Button("Line Settings…") {
                            UserDefaults.standard.set(SettingsPane.develop.rawValue, forKey: SettingsPane.defaultsKey)
                            openSettings()
                        }
                    }
                } label: {
                    Image(systemName: guideVisibility == .never ? "eye.slash" : "eye")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("When the overlay shows, and its lines")
            }
            SliderRow(label: "Angle", value: Binding(get: { crop.angle }, set: { setAngle($0) }),
                      range: -45...45, step: 0.1, format: { String(format: "%.1f°", $0) })
            HStack(spacing: 6) {
                Button { develop.setCrop(crop.turned(clockwise: false)) } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate left (⌘[)")
                Button { develop.setCrop(crop.turned(clockwise: true)) } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate right (⌘])")
                Button { develop.setCrop(crop.flipped(horizontally: true)) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontal")
                Button { develop.setCrop(crop.flipped(horizontally: false)) } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip vertical")
                Spacer()
                Button("Reset") { develop.setCrop(Crop()) }
                    .disabled(crop.isIdentity)
                    .help("Remove the crop, straightening, rotation and flips")
                Button("Done") { develop.isCropping = false }
                    .keyboardShortcut(.defaultAction)
                    .help("Close the crop tool (R or Return)")
            }
            Text("Drag a corner or edge to crop, inside to move, outside to straighten. O picks the overlay, ⇧O turns it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setAngle(_ angle: Double) {
        var target = crop
        target.angle = min(45, max(-45, angle))
        develop.setCrop(target.fitted(imageAspect: imageAspect))
    }
}
