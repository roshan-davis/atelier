import AppKit
import AtelierCore
import SwiftUI

/// The photo being developed, rendered live from the original, with optional before/after views.
struct DevelopImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let image = develop.image {
                    if develop.showingBefore || develop.compareMode == .off {
                        ZoomableImageView(image: develop.displayImage ?? image,
                                          pixelSize: pixelSize,
                                          zoom: $model.zoom,
                                          onReport: { report in
                                              if model.zoomReport != report { model.zoomReport = report }
                                              if develop.wantsFullResolution != report.isZoomedPastFit {
                                                  develop.wantsFullResolution = report.isZoomedPastFit
                                              }
                                          },
                                          menu: { model.photoMenu(includeZoom: true) })
                    } else if develop.compareMode == .sideBySide {
                        HStack(spacing: 12) {
                            ComparePane(image: develop.beforeImage, label: "Before")
                            ComparePane(image: image, label: "After")
                        }
                        .padding(16)
                    } else {
                        SliderCompareView(before: develop.beforeImage, after: image, position: $develop.sliderPosition)
                            .padding(16)
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
            HStack(spacing: 10) {
                Text("Before and After")
                    .foregroundStyle(.secondary)
                Picker("Before and After", selection: $develop.compareMode) {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Compare with the original: side by side, or drag a slider across the photo (Y)")
                if develop.compareMode == .slider {
                    Text("Drag across the photo to move the divider")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZoomControls(zoom: $model.zoom, report: model.zoomReport)
                    .disabled(develop.compareMode != .off)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { develop.open(model.focusedID) }
    }

    private var pixelSize: CGSize? {
        guard let width = model.detail?.asset.width, let height = model.detail?.asset.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private struct PhotoImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                PhotoImage(image: image)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Badge(text: label).padding(8)
        }
    }
}

/// The edited photo with the original revealed to the left of a draggable divider.
private struct SliderCompareView: View {
    let before: NSImage?
    let after: NSImage
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let rect = fittedRect(for: after.size, in: geometry.size)
            let dividerX = rect.minX + rect.width * position
            ZStack(alignment: .topLeading) {
                Image(nsImage: after)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                if let before {
                    Image(nsImage: before)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: rect.width * position)
                        }
                        .position(x: rect.midX, y: rect.midY)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: rect.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: dividerX, y: rect.midY)
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(Color.black))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: dividerX, y: rect.midY)
                Badge(text: "Before")
                    .fixedSize()
                    .position(x: rect.minX + 44, y: rect.minY + 20)
                    .opacity(position > 0.12 ? 1 : 0)
                Badge(text: "After")
                    .fixedSize()
                    .position(x: rect.maxX - 38, y: rect.minY + 20)
                    .opacity(position < 0.88 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard rect.width > 0 else { return }
                position = min(1, max(0, (value.location.x - rect.minX) / rect.width))
            })
        }
    }

    private func fittedRect(for size: NSSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
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
            ScrollView {
                VStack(spacing: 0) {
                    PanelSection(title: "Histogram", isExpanded: isExpanded("histogram"), soloMode: $soloMode,
                                 expandAll: expandAll, collapseAll: collapseAll) {
                        HistogramView(histogram: develop.histogram)
                    }
                    ForEach(DevelopSettings.Panel.allCases, id: \.self) { panel in
                        PanelSection(title: panel.title, isExpanded: isExpanded(panel.rawValue), soloMode: $soloMode,
                                     isModified: develop.isModified(panel), reset: { develop.reset(panel) },
                                     expandAll: expandAll, collapseAll: collapseAll) {
                            switch panel {
                            case .toneCurve:
                                ToneCurvePanel(develop: develop)
                            case .hsl:
                                HSLPanel(develop: develop)
                            case .colorGrading:
                                ColorGradingPanel(develop: develop)
                            default:
                                VStack(alignment: .leading, spacing: 10) {
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

private struct GroupHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// Tone Curve: the combined curve drawn over the histogram, with Lightroom's region sliders.
private struct ToneCurvePanel: View {
    @ObservedObject var develop: DevelopController

    private let regions: [DevelopSettings.Parameter] = [.curveHighlights, .curveLights, .curveDarks, .curveShadows]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                // Quarter grid, like Lightroom.
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                if let histogram = develop.histogram {
                    var area = Path()
                    area.move(to: CGPoint(x: 0, y: size.height))
                    for (i, value) in histogram.luminance.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(histogram.luminance.count - 1)
                        area.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value) * 0.9)))
                    }
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    context.fill(area, with: .color(.white.opacity(0.12)))
                }
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height))
                diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var curve = Path()
                let samples = 96
                for i in 0...samples {
                    let x = Double(i) / Double(samples)
                    let y = DevelopRenderer.toneCurveValue(develop.settings, at: x)
                    let point = CGPoint(x: rect.width * x, y: rect.height * (1 - y))
                    if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(.white), lineWidth: 1.5)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            Text("Includes Contrast, Highlights, Whites and Blacks from Basic.")
                .font(.caption)
                .foregroundStyle(.secondary)
            GroupHeading(title: "Region")
            ForEach(regions, id: \.self) { parameter in
                ParameterSlider(parameter: parameter, develop: develop)
            }
        }
    }
}

/// HSL / Color: eight color bands, shown one channel at a time or all at once.
private struct HSLPanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage("develop.hslChannel") private var channel = "Hue"

    private var channels: [DevelopSettings.HSLChannel] {
        channel == "All" ? DevelopSettings.HSLChannel.allCases
            : [DevelopSettings.HSLChannel(rawValue: channel) ?? .hue]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Channel", selection: $channel) {
                ForEach(DevelopSettings.HSLChannel.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                Text("All").tag("All")
            }
            .pickerStyle(.segmented)
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
                                                       set: { develop.set(region.saturation, to: $0) }))
                        Slider(value: Binding(get: { develop.value(region.luminance) },
                                              set: { develop.set(region.luminance, to: $0) }),
                               in: region.luminance.range, step: 1)
                            .controlSize(.mini)
                            .labelsHidden()
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
private struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let angle = hue * .pi / 180
            let distance = radius * saturation / 100
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 0.8, brightness: 0.9) },
                                          center: .center, startAngle: .degrees(0), endAngle: .degrees(-360)))
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
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - center.x, dy = center.y - value.location.y
                var degrees = atan2(dy, dx) * 180 / .pi
                if degrees < 0 { degrees += 360 }
                hue = degrees.rounded()
                saturation = min(100, (dx * dx + dy * dy).squareRoot() / radius * 100).rounded()
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A collapsible panel with a Lightroom-style header.
private struct PanelSection<Content: View>: View {
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
        if let share, share >= 0.005 {
            Label("\(name) clipped \(String(format: "%.1f", share * 100))%", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(" ")
        }
    }
}

private struct ParameterSlider: View {
    let parameter: DevelopSettings.Parameter
    @ObservedObject var develop: DevelopController
    @State private var editing = false
    @State private var draft = 0.0
    @FocusState private var fieldFocused: Bool

    private var binding: Binding<Double> {
        Binding(get: { develop.value(parameter) }, set: { develop.set(parameter, to: $0) })
    }

    private var formatted: String {
        let value = develop.value(parameter)
        switch parameter {
        case .temperature: return "\(Int(value.rounded())) K"
        case .exposure: return String(format: "%+.2f", value)
        case .sharpenRadius: return String(format: "%.1f", value)
        default:
            if parameter.range.lowerBound >= 0 { return "\(Int(value.rounded()))" }
            return value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.label)
                    .onTapGesture(count: 2) { develop.reset(parameter) }
                    .help("Double-click to reset")
                Spacer()
                if editing {
                    TextField("Value", value: $draft, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onChange(of: fieldFocused) { if !fieldFocused { commit() } }
                        .onExitCommand { editing = false }
                } else {
                    Text(formatted)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            draft = develop.value(parameter)
                            editing = true
                            fieldFocused = true
                        }
                        .help("Click to type a value")
                }
            }
            ZStack {
                if let gradient = trackGradient {
                    Capsule()
                        .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                        .padding(.horizontal, 2)
                        .offset(y: 8)
                }
                Slider(value: binding, in: parameter.range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private func commit() {
        guard editing else { return }
        develop.set(parameter, to: draft)
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
        switch parameter {
        case .temperature: return [Color(red: 0.3, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)]
        case .tint: return [Color(red: 0.3, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.85)]
        case .vibrance, .saturation: return [Color.gray, Color(red: 1, green: 0.4, blue: 0.2), Color(red: 0.3, green: 0.6, blue: 1)]
        default: return nil
        }
    }

    private var step: Double {
        switch parameter {
        case .temperature: return 50
        case .exposure: return 0.05
        case .sharpenRadius: return 0.1
        default: return 1
        }
    }
}
