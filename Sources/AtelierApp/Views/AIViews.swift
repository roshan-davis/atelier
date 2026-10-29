import AppKit
import AtelierCore
import SwiftUI

/// The photo under the AI tool: paint the area to remove, or see what Replace Background keeps.
struct AIBrushView: View {
    @ObservedObject var ai: AIController
    let image: NSImage
    let assetID: Int64?

    @State private var current: BrushStroke?
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fit(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                overlay(in: rect)
                if ai.recipe.usesBrush, let hover, rect.contains(hover) {
                    let diameter = ai.brushSize * 2 * rect.width
                    Circle()
                        .stroke(Color.white, lineWidth: 1)
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1).padding(1))
                        .frame(width: diameter, height: diameter)
                        .position(hover)
                        .allowsHitTesting(false)
                }
                if ai.isRunning {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(ai.phase ?? "Working…").font(.callout).monospacedDigit()
                        if let fraction = ai.fraction {
                            AIPercentBar(fraction: fraction).frame(width: 180)
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in paint(at: drag.location, in: rect) }
                .onEnded { _ in
                    if let current { ai.strokes.append(current) }
                    current = nil
                })
            .onContinuousHover { phase in
                if case .active(let point) = phase { hover = point } else { hover = nil }
            }
            .cursor { [ai] point in ai.recipe.usesBrush && rect.contains(point) ? .crosshair : .arrow }
        }
        .onChange(of: assetID) { _, _ in ai.reset() }
        .onAppear { findSubjectIfNeeded() }
        .onChange(of: image) { _, _ in findSubjectIfNeeded() }
    }

    private func findSubjectIfNeeded() {
        if ai.recipe == .replaceBackground, ai.backgroundMask == nil, !ai.isFindingSubject { ai.findSubject() }
    }

    @ViewBuilder private func overlay(in rect: CGRect) -> some View {
        switch ai.recipe {
        case .removeObject:
            Canvas { context, _ in
                context.drawLayer { layer in
                    for stroke in ai.strokes + (current.map { [$0] } ?? []) {
                        layer.blendMode = stroke.erases ? .clear : .normal
                        draw(stroke, in: rect, on: &layer)
                    }
                }
            }
            .opacity(0.5)
            .allowsHitTesting(false)
        case .replaceBackground:
            if let mask = ai.backgroundMask {
                // Tint what will be regenerated; the subject stays clear.
                Color(red: 0.95, green: 0.25, blue: 0.2).opacity(0.45)
                    .frame(width: rect.width, height: rect.height)
                    .mask(Image(decorative: mask, scale: 1).resizable().frame(width: rect.width, height: rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        case .upscale:
            EmptyView()
        }
    }

    private func draw(_ stroke: BrushStroke, in rect: CGRect, on context: inout GraphicsContext) {
        let width = stroke.radius * 2 * rect.width
        let points = stroke.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        let color = Color(red: 0.95, green: 0.2, blue: 0.2)
        if points.count == 1, let p = points.first {
            context.fill(Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)),
                         with: .color(color))
        } else {
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    private func paint(at location: CGPoint, in rect: CGRect) {
        hover = location
        guard ai.recipe.usesBrush, !ai.isRunning, rect.width > 0 else { return }
        let point = CGPoint(x: min(max((location.x - rect.minX) / rect.width, 0), 1),
                            y: min(max((location.y - rect.minY) / rect.height, 0), 1))
        if current == nil {
            current = BrushStroke(points: [point], radius: ai.brushSize, erases: ai.erasing)
        } else {
            current?.points.append(point)
        }
    }

    /// The photo fitted in the view with a margin, like the other Develop views.
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let available = CGSize(width: max(bounds.width - inset * 2, 1), height: max(bounds.height - inset * 2, 1))
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: available) }
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// The AI section of the Develop panel.
struct AIPanel: View {
    @ObservedObject var ai: AIController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            serverLine
            Picker("Recipe", selection: $ai.recipe) {
                ForEach(AIRecipe.allCases, id: \.self) { recipe in
                    Image(systemName: recipe.symbol).tag(recipe).help(recipe.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(ai.isRunning)
            VStack(alignment: .leading, spacing: 3) {
                Text(ai.recipe.title).font(.headline)
                Text(ai.recipe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if ai.recipe.usesBrush {
                SliderRow(label: "Brush Size", value: Binding(get: { ai.brushSize * 100 }, set: { ai.brushSize = $0 / 100 }),
                          range: 0.5...15, step: 0.1, origin: 0.5, format: { String(format: "%.1f", $0) },
                          reset: { ai.brushSize = 0.03 })
                HStack {
                    Picker("Brush", selection: $ai.erasing) {
                        Text("Paint").tag(false)
                        Text("Erase").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button("Clear") { ai.clearMask() }
                        .disabled(ai.strokes.isEmpty)
                }
            }
            if ai.recipe == .replaceBackground, ai.isFindingSubject {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding the subject…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if ai.recipe.usesPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ai.recipe == .replaceBackground ? "New background" : "What it is (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(ai.recipe == .replaceBackground ? "e.g. a sunlit studio wall, soft shadows" : "e.g. a pine tree",
                              text: $ai.prompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if ai.recipe == .upscale {
                Picker("Enlarge", selection: upscaleFactor) {
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if ai.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ai.phase ?? "Working…").font(.callout).lineLimit(1).monospacedDigit()
                        Spacer()
                        Button("Cancel") { ai.cancel() }
                    }
                    if let fraction = ai.fraction {
                        AIPercentBar(fraction: fraction)
                    }
                }
            } else {
                Button {
                    ai.generate()
                } label: {
                    Label("Generate", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!ai.canGenerate)
            }
            if let message = ai.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("The result is saved as a new photo stacked on this one; the original never changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if ai.serverStatus == .unknown { ai.checkServer() }
        }
    }

    private var upscaleFactor: Binding<Int> {
        Binding(get: { AIController.settings.upscaleFactor },
                set: { UserDefaults.standard.set($0, forKey: "ai.upscaleFactor"); ai.objectWillChange.send() })
    }

    @ViewBuilder private var serverLine: some View {
        HStack(spacing: 6) {
            switch ai.serverStatus {
            case .unknown, .checking:
                ProgressView().controlSize(.mini)
                Text("Checking ComfyUI…")
            case .connected(let version):
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(version == "connected" ? "ComfyUI connected" : "ComfyUI \(version)")
            case .unreachable(let reason):
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("ComfyUI not reachable").help(reason)
            }
            Spacer()
            Button("Check") { ai.checkServer() }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// ComfyUI's progress as a bar and a percentage. Approximate: it weighs each step by how long it
/// took on earlier runs.
struct AIPercentBar: View {
    var fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.4), value: fraction)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .help("Approximate, from ComfyUI's progress")
    }
}
