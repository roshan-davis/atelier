import AppKit
import AtelierCore
import SwiftUI

/// Color Grading, as in Lightroom: a 3-Way view (Midtones above Shadows and Highlights) or one
/// large wheel at a time, then Blending and Balance. Beyond Lightroom, each wheel shows where
/// the photo's colors sit and where the other wheels' tints are, the color picker sets a wheel
/// to cancel a cast, and a graph shows the tonal ranges Blending and Balance shape. The Preset
/// menu at the top sets every wheel, Blending and Balance (`SectionPresetRow`).
///
/// A mask's Color Grading (Lightroom Classic 16) is this same panel with `target` set to the
/// mask; there the panel's Preset menu, color picker and eye buttons, which act on the whole
/// photo's grade, are left out.
struct ColorGradingPanel: View {
    typealias Region = DevelopSettings.GradeRegion

    @ObservedObject var develop: DevelopController
    var target: GradeTarget = .photo
    /// "3-Way" or a region's name, remembered separately for the panel and for masks.
    @AppStorage("develop.gradeView") private var panelView = "3-Way"
    @AppStorage("masking.gradeView") private var maskView = "3-Way"
    @State private var width: CGFloat = 256

    private var isPhoto: Bool { target == .photo }
    private var view: String {
        get { isPhoto ? panelView : maskView }
        nonmutating set { if isPhoto { panelView = newValue } else { maskView = newValue } }
    }

    private var single: Region? { Region(rawValue: view) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isPhoto {
                SectionPresetRow(kind: .colorGrading, develop: develop)
            }
            viewPicker
            Group {
                if let single {
                    singleView(single)
                } else {
                    threeWay
                }
            }
            GroupHeading(title: "Blend") { develop.resetGrade([.gradeBlending, .gradeBalance], name: "Blend", in: target) }
            slider(.gradeBlending)
            slider(.gradeBalance)
            ToneRangeGraph(blending: develop.gradeValue(.gradeBlending, in: target) / 100,
                           balance: develop.gradeValue(.gradeBalance, in: target) / 100)
                .frame(height: 34)
                .help("Where Shadows (blue), Midtones (gray) and Highlights (yellow) apply, from black to white. "
                      + "Blending widens the overlap; Balance moves the split.")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Views

    private var viewPicker: some View {
        HStack(spacing: 4) {
            Text("Adjust")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .onDoubleClick { develop.resetAllGrade(in: target) }
                .help("Double-click to reset all Color Grading")
            Spacer(minLength: 4)
            viewButton("3-Way", help: "Shadows, Midtones and Highlights") { ThreeWayGlyph() }
            ForEach(Region.allCases, id: \.self) { region in
                viewButton(region.rawValue, help: region.rawValue) { RegionGlyph(region: region) }
            }
            if isPhoto {
                Divider().frame(height: 14).padding(.horizontal, 2)
                PickerButton(develop: develop, kind: .gradeColor,
                             help: single.map { "Color picker: click a spot to set the \($0.rawValue) wheel so its color cast turns neutral" }
                                 ?? "Color picker: click a spot to set the Shadows, Midtones or Highlights wheel (by the spot's tone) "
                                 + "so its color cast turns neutral") {
                    develop.gradePickRegion = single
                }
            }
        }
    }

    /// The panel's own sliders bind to the photo's settings (`ParameterSlider`); a mask's go
    /// through the same `SliderRow` with the mask's values.
    @ViewBuilder
    private func slider(_ parameter: DevelopSettings.Parameter) -> some View {
        if isPhoto {
            ParameterSlider(parameter: parameter, develop: develop)
        } else {
            SliderRow(label: parameter.label,
                      value: Binding(get: { develop.gradeValue(parameter, in: target) },
                                     set: { develop.setGrade(parameter, to: $0, in: target) }),
                      range: parameter.range, step: 1, origin: parameter.defaultValue,
                      reset: { develop.resetGrade([parameter], name: Self.name(parameter), in: target) })
        }
    }

    private static func name(_ parameter: DevelopSettings.Parameter) -> String {
        DevelopController.parameterName(parameter)
    }

    private func viewButton<Glyph: View>(_ id: String, help: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        Button {
            view = id
            if isPhoto, develop.isPickingGradeColor { develop.gradePickRegion = Region(rawValue: id) }
        } label: {
            glyph()
                .frame(width: 22, height: 20)
                .background(view == id ? Color.accentColor.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Lightroom's 3-Way layout: Midtones centered on top, Shadows and Highlights below.
    private var threeWay: some View {
        let side = max(80, min(170, (width - 12) / 2))
        return VStack(spacing: 10) {
            WheelBlock(region: .midtones, develop: develop, target: target, size: side, large: false)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 12) {
                WheelBlock(region: .shadows, develop: develop, target: target, size: side, large: false)
                WheelBlock(region: .highlights, develop: develop, target: target, size: side, large: false)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// One large wheel, with Hue and Saturation sliders that take typed values.
    private func singleView(_ region: Region) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            WheelBlock(region: region, develop: develop, target: target, size: max(120, min(260, width - 8)), large: true)
                .frame(maxWidth: .infinity)
            slider(region.hue)
            slider(region.saturation)
            slider(region.luminance)
        }
    }
}

/// One wheel with its title, the eye button and, in the 3-Way view, a Luminance slider.
private struct WheelBlock: View {
    typealias Region = DevelopSettings.GradeRegion

    let region: Region
    @ObservedObject var develop: DevelopController
    let target: GradeTarget
    let size: CGFloat
    let large: Bool

    private func value(_ parameter: DevelopSettings.Parameter) -> Double { develop.gradeValue(parameter, in: target) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(region.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .onDoubleClick { develop.resetGrade(region, luminance: true, in: target) }
                    .help("Double-click to reset the \(region.rawValue) wheel")
                if target == .photo { soloButton }
            }
            ColorWheel(region: region, develop: develop, target: target)
                .frame(width: size, height: size)
            if !large {
                let luminance = Binding(get: { value(region.luminance) },
                                        set: { develop.setGrade(region.luminance, to: $0, in: target) })
                DevelopSlider(value: luminance, range: region.luminance.range, step: 1, origin: 0,
                              gradient: [Color.black, Color.white])
                    .frame(width: size)
                    .modifier(KeyboardSlider(value: luminance, range: region.luminance.range, step: 1))
                    .help("Luminance (double-click the wheel's name to reset the wheel)")
                Text("H \(Int(value(region.hue))) · S \(Int(value(region.saturation))) · L \(Int(value(region.luminance)))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Reset Hue and Saturation") { develop.resetGrade(region, luminance: false, in: target) }
            Button("Reset Luminance") {
                develop.resetGrade([region.luminance], name: "\(region.rawValue) Luminance", in: target)
            }
            Button("Reset \(region.rawValue)") { develop.resetGrade(region, luminance: true, in: target) }
            Divider()
            Button("Copy \(region.rawValue) Settings") { develop.copyGradeWheel(region, in: target) }
            Button("Paste Settings to \(region.rawValue)") { develop.pasteGradeWheel(onto: region, in: target) }
                .disabled(develop.copiedGradeWheel == nil)
            Divider()
            Button("Reset All Color Grading") { develop.resetAllGrade(in: target) }
        }
    }

    /// Press and hold to see the photo graded by this wheel alone (the photo's panel only).
    private var soloButton: some View {
        Image(systemName: "eye")
            .font(.caption)
            .foregroundStyle(develop.sliderPreview == .gradeSolo(region) ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if develop.sliderPreview != .gradeSolo(region) { develop.sliderPreview = .gradeSolo(region) }
                }
                .onEnded { _ in develop.sliderPreview = nil })
            .help(SliderPreview.gradeSolo(region).hint)
    }
}

/// A Lightroom color wheel: angle is hue, distance from the center is saturation.
///
/// - The hollow dot inside sets hue and saturation; it is filled with the tint it gives.
///   Grabbing it moves it from where it is, so it never jumps; clicking elsewhere puts it there.
/// - The solid dot on the rim turns the hue only.
/// - The spoke from the center through the dot to the rim shows the hue's direction. While the
///   dot is dragged along it, it holds the hue (Lightroom's soft constraint) until the pointer
///   moves well off it.
/// - Shift-drag changes saturation only, Command-drag hue only, Option-drag moves slowly for fine
///   adjustment. Double-click resets hue and saturation; arrow keys nudge while hovering.
/// - Faint dots show where the photo's colors in this wheel's range sit, and small rings where
///   the other wheels' tints are.
struct ColorWheel: View {
    typealias Region = DevelopSettings.GradeRegion

    let region: Region
    @ObservedObject var develop: DevelopController
    var target: GradeTarget = .photo

    private enum Grab {
        /// The dot inside: `point` is where it would be, relative to the center, before clamping.
        case dot(point: CGPoint, constrained: Bool, startHue: Double, startSaturation: Double)
        case rim
    }

    @Environment(\.developFrameHUD) private var frameHUD
    @State private var grab: Grab?
    @State private var lastLocation: CGPoint = .zero
    @State private var lastTap: (time: Date, location: CGPoint)?

    /// Room around the disc for the rim dot.
    private static let inset: CGFloat = 6
    /// How far off the spoke (points) the pointer can stray before the hue follows it.
    private static let constraintWidth: CGFloat = 10

    private var diagnosticName: String { "Color Grading \(region.rawValue)" }

    private var hue: Double { develop.gradeValue(region.hue, in: target) }
    private var saturation: Double { develop.gradeValue(region.saturation, in: target) }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = max(1, side / 2 - Self.inset)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let dot = point(hue: hue, saturation: saturation, radius: radius, center: center)
            let rimDot = point(hue: hue, saturation: 100, radius: radius, center: center)
            ZStack {
                disc(radius: radius)
                    .position(center)
                scope(radius: radius, center: center)
                others(radius: radius, center: center)
                if saturation > 0 || grab != nil {
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: rimDot)
                    }
                    .stroke(Color.white.opacity(grab == nil ? 0.45 : 0.9), lineWidth: 1)
                    .shadow(color: .black.opacity(0.5), radius: 0.5)
                }
                Circle()
                    .fill(Color(hue: hue / 360, saturation: 0.85, brightness: 0.95))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.5).padding(-1))
                    .frame(width: 10, height: 10)
                    .position(rimDot)
                Circle()
                    .fill(swatch)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 0.5).padding(-1.5))
                    .frame(width: 12, height: 12)
                    .position(dot)
            }
            .contentShape(Circle().inset(by: Self.inset - 8))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let frameHUD, frameHUD.active {
                        frameHUD.measure(diagnosticName, startingValue: saturation) {
                            drag(value, center: center, radius: radius, dot: dot, rimDot: rimDot)
                        }
                    } else {
                        drag(value, center: center, radius: radius, dot: dot, rimDot: rimDot)
                    }
                }
                .onEnded { value in
                    endDrag(value)
                    frameHUD?.end(diagnosticName)
                })
            .cursor(.crosshair)
            .onHover { inside in
                if inside {
                    develop.hoveredGradeRegion = region
                    develop.hoveredGradeTarget = target
                } else if develop.hoveredGradeRegion == region, develop.hoveredGradeTarget == target {
                    develop.hoveredGradeRegion = nil
                }
            }
            .onDisappear {
                if develop.hoveredGradeRegion == region, develop.hoveredGradeTarget == target { develop.hoveredGradeRegion = nil }
                frameHUD?.end(diagnosticName)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help("Drag the inner dot for hue and saturation, the rim dot for hue. Shift: saturation only; "
              + "Command: hue only; Option: fine adjustment. Double-click to reset; arrow keys nudge.")
    }

    private var swatch: Color {
        let color = ColorGrade.swatch(hue: hue, saturation: saturation)
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    // MARK: Drawing

    private func disc(radius: CGFloat) -> some View {
        ZStack {
            Circle()
                // SwiftUI sweeps clockwise on screen and a reversed range (end < start) draws only
                // the first color, so run 0°→360° with hue falling, which puts hue rising
                // counterclockwise from red at 3 o'clock, where the dot places it.
                .fill(AngularGradient(colors: (0...12).map { Color(hue: Double(12 - $0) / 12, saturation: 0.8, brightness: 0.9) },
                                      center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                     center: .center, startRadius: 0, endRadius: radius))
            Circle().stroke(Color.black.opacity(0.4), lineWidth: 1)
        }
        .frame(width: radius * 2, height: radius * 2)
    }

    /// The photo's colors that fall in this wheel's range.
    private func scope(radius: CGFloat, center: CGPoint) -> some View {
        let blending: Double = develop.gradeValue(.gradeBlending, in: target) / 100
        let balance: Double = develop.gradeValue(.gradeBalance, in: target) / 100
        let index = ColorGrade.index(of: region)
        return MeasuresReader(develop.measures) { measures in Canvas { context, _ in
            let samples = measures.colorScope?.samples ?? []
            for sample in samples {
                let weight = ColorGrade.weights(luma: sample.luma, blending: blending, balance: balance)[index]
                guard weight > 0.2 else { continue }
                let p = point(hue: sample.hue, saturation: sample.radius * 100, radius: radius, center: center)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                             with: .color(Color.black.opacity(0.18 + 0.3 * weight)))
            }
        } }
        .allowsHitTesting(false)
    }

    /// Small rings where the other wheels' tints are.
    private func others(radius: CGFloat, center: CGPoint) -> some View {
        let tinted: [Region] = Region.allCases.filter { $0 != region && develop.gradeValue($0.saturation, in: target) > 0 }
        return ForEach(tinted, id: \.self) { other in
            let otherHue: Double = develop.gradeValue(other.hue, in: target)
            let otherSaturation: Double = develop.gradeValue(other.saturation, in: target)
            let color = ColorGrade.swatch(hue: otherHue, saturation: otherSaturation)
            Circle()
                .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                .frame(width: 7, height: 7)
                .position(point(hue: otherHue, saturation: otherSaturation, radius: radius, center: center))
                .allowsHitTesting(false)
        }
    }

    private func point(hue: Double, saturation: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = hue * .pi / 180
        let distance = radius * saturation / 100
        return CGPoint(x: center.x + distance * cos(angle), y: center.y - distance * sin(angle))
    }

    // MARK: Dragging

    private func drag(_ value: DragGesture.Value, center: CGPoint, radius: CGFloat, dot: CGPoint, rimDot: CGPoint) {
        let flags = NSEvent.modifierFlags
        guard let current = grab else {
            // The mouse just went down: on the rim dot, on the inner dot, or elsewhere.
            let start = value.startLocation
            lastLocation = start
            if distance(start, rimDot) < 9, distance(start, dot) > 6 {
                grab = .rim
            } else if distance(start, dot) < 9 {
                grab = .dot(point: CGPoint(x: dot.x - center.x, y: dot.y - center.y),
                            constrained: saturation > 3, startHue: hue, startSaturation: saturation)
            } else {
                // Lightroom: a click picks the spot. Free from there; no soft constraint.
                let point = CGPoint(x: start.x - center.x, y: start.y - center.y)
                grab = .dot(point: point, constrained: false, startHue: hue, startSaturation: saturation)
                apply(point: point, radius: radius, constrained: false, startHue: hue, flags: [])
            }
            return
        }
        let delta = CGPoint(x: value.location.x - lastLocation.x, y: value.location.y - lastLocation.y)
        lastLocation = value.location
        switch current {
        case .rim:
            let point = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
            set(hue: angle(of: point), saturation: saturation)
        case .dot(var point, var constrained, let startHue, let startSaturation):
            let speed: CGFloat = flags.contains(.option) ? 0.1 : 1
            point.x += delta.x * speed
            point.y += delta.y * speed
            // Never let the pointer's virtual position run far past the rim.
            let length = hypot(point.x, point.y)
            if length > radius {
                point.x *= radius / length
                point.y *= radius / length
            }
            if flags.contains(.option) { constrained = false }
            constrained = apply(point: point, radius: radius, constrained: constrained, startHue: startHue,
                                startSaturation: startSaturation, flags: flags)
            grab = .dot(point: point, constrained: constrained, startHue: startHue, startSaturation: startSaturation)
        }
    }

    /// Sets the wheel for the inner dot at `point` (relative to the center, y down). Returns
    /// whether the soft constraint still holds.
    @discardableResult
    private func apply(point: CGPoint, radius: CGFloat, constrained: Bool, startHue: Double,
                       startSaturation: Double = 0, flags: NSEvent.ModifierFlags) -> Bool {
        let length = min(radius, hypot(point.x, point.y))
        let loose = (hue: angle(of: point), saturation: Double(length / radius * 100))
        let spoke = CGVector(dx: cos(startHue * .pi / 180), dy: -sin(startHue * .pi / 180))
        let along = point.x * spoke.dx + point.y * spoke.dy
        let across = abs(point.x * spoke.dy - point.y * spoke.dx)
        let onSpoke = Double(min(radius, max(0, along)) / radius * 100)
        if flags.contains(.shift) {
            set(hue: startHue, saturation: onSpoke)
            return constrained
        }
        if flags.contains(.command) {
            set(hue: loose.hue, saturation: startSaturation)
            return constrained
        }
        if constrained, across < Self.constraintWidth, along > 0 {
            set(hue: startHue, saturation: onSpoke)
            return true
        }
        set(hue: loose.hue, saturation: loose.saturation)
        return false
    }

    private func set(hue: Double, saturation: Double) {
        var h = hue.rounded()
        if h >= 360 { h -= 360 }
        let s = min(100, max(0, saturation.rounded()))
        guard h != self.hue || s != self.saturation else { return }
        develop.setGradeColor(region, hue: h, saturation: s, in: target)
    }

    private func endDrag(_ value: DragGesture.Value) {
        grab = nil
        guard distance(value.startLocation, value.location) < 3 else {
            lastTap = nil
            return
        }
        // Double-click resets hue and saturation, as in Lightroom.
        if let lastTap, Date().timeIntervalSince(lastTap.time) < 0.4, distance(lastTap.location, value.location) < 6 {
            self.lastTap = nil
            develop.resetGrade(region, luminance: false, in: target)
        } else {
            lastTap = (Date(), value.location)
        }
    }

    /// Hue in degrees, counterclockwise from 3 o'clock, for a point relative to the center (y down).
    private func angle(of point: CGPoint) -> Double {
        var degrees = atan2(-Double(point.y), Double(point.x)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The three tonal ranges' weights from black (left) to white (right), as Blending and Balance
/// set them: Shadows blue, Midtones gray, Highlights yellow, the colors of Balance's Option view.
struct ToneRangeGraph: View {
    let blending: Double
    let balance: Double

    var body: some View {
        Canvas { context, size in
            let colors = [Color(red: 0.2, green: 0.4, blue: 0.95), Color(white: 0.55), Color(red: 1, green: 0.8, blue: 0.25)]
            let steps = 64
            for index in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for step in 0...steps {
                    let y = Double(step) / Double(steps)
                    let weight = ColorGrade.weights(luma: y, blending: blending, balance: balance)[index]
                    path.addLine(to: CGPoint(x: size.width * y, y: size.height * (1 - weight)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(colors[index].opacity(0.22)))
                context.stroke(path, with: .color(colors[index]), lineWidth: 1)
            }
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [Color.black.opacity(0.35), Color.white.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 3)
        }
        .accessibilityLabel("Tonal ranges")
    }
}

/// Toolbar glyph for the 3-Way view: three small wheels.
private struct ThreeWayGlyph: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 7, height: 7).offset(y: -3.5)
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 7, height: 7).offset(x: -4.5, y: 3.5)
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 7, height: 7).offset(x: 4.5, y: 3.5)
        }
    }
}

/// Toolbar glyph for one wheel: dark, mid or light gray, or a hue ring for Global.
private struct RegionGlyph: View {
    let region: DevelopSettings.GradeRegion

    var body: some View {
        Group {
            switch region {
            case .shadows: Circle().fill(Color(white: 0.15))
            case .midtones: Circle().fill(Color(white: 0.5))
            case .highlights: Circle().fill(Color(white: 0.92))
            case .global:
                Circle().fill(AngularGradient(colors: (0...6).map { Color(hue: Double(6 - $0) / 6, saturation: 0.8, brightness: 0.9) },
                                              center: .center))
            }
        }
        .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
        .frame(width: 12, height: 12)
    }
}
