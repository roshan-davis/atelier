import AppKit
import AtelierCore
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// The export dialog: presets on the left, as in Lightroom; format, size, color, metadata and
/// watermark choices for the selected photos on the right. The last choices are remembered.
struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.reveal") private var reveal = true
    @AppStorage("export.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Exports").path

    /// Everything but the folder, which lives in `destinationPath` so Settings can change it.
    @State private var draft: ExportSettings
    /// What Resize and Add Watermark go back to when they're turned on again.
    @State private var lastLongEdge: Int
    @State private var lastWatermark: ExportWatermark

    private let store = ExportPresetStore()
    @State private var userPresets: [ExportPreset] = []
    @State private var naming = false
    @State private var newPresetName = ""
    @State private var deleting: ExportPreset?
    @State private var presetError: String?

    /// The first photo, small, for the watermark preview.
    @State private var previewPhoto: CIImage?
    private static let previewContext = CIContext()

    static let size = CGSize(width: 820, height: 720)

    init() {
        let last = Self.loadLast()
        _draft = State(initialValue: last.settings)
        _lastLongEdge = State(initialValue: last.settings.longEdge ?? 2048)
        _lastWatermark = State(initialValue: last.watermark)
    }

    private var count: Int { model.exportIDs.count }
    private var presets: [ExportPreset] { ExportPreset.builtIn + userPresets }
    private var selectedPreset: ExportPreset? { presets.first { $0.matches(draft) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export \(count) Photo\(count == 1 ? "" : "s")")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            HStack(spacing: 0) {
                presetList
                    .frame(width: 210)
                Divider()
                settingsForm
            }
            Divider()

            HStack {
                Text(presetError ?? "Edits are applied. Originals are not changed.")
                    .font(.callout)
                    .foregroundStyle(presetError == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export \(count) Photo\(count == 1 ? "" : "s")") {
                    Self.saveLast(draft, watermark: lastWatermark)
                    model.runExport(settings: exportSettings, revealWhenDone: reveal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { userPresets = store.userPresets() }
        .task { await loadPreviewPhoto() }
        .alert("New Preset", isPresented: $naming) {
            TextField("Preset name", text: $newPresetName)
            Button("Create") { addPreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current settings, including the watermark. The folder isn't part of a preset.")
        }
        .confirmationDialog("Delete the preset “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { deletePreset(deleting) }
            }
        } message: {
            Text("Photos already exported are not affected.")
        }
    }

    // MARK: Presets

    private var presetList: some View {
        VStack(spacing: 0) {
            List(selection: presetSelection) {
                Section("Atelier") {
                    ForEach(ExportPreset.builtIn) { presetRow($0) }
                }
                Section("User Presets") {
                    if userPresets.isEmpty {
                        Text("Click + to save these settings as a preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(userPresets) { preset in
                        presetRow(preset)
                            .contextMenu {
                                Button("Update with Current Settings") { update(preset) }
                                Divider()
                                Button("Delete…") { deleting = preset }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button {
                    newPresetName = ""
                    naming = true
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .help("Save the current settings as a new preset")
                Button {
                    deleting = selectedPreset
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .help("Delete the selected preset")
                .disabled(selectedPreset.map { $0.isBuiltIn } ?? true)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        Text(preset.name)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("\(preset.name): \(preset.summary)")
            .tag(preset.id)
    }

    /// The preset whose settings the dialog shows; changing any setting clears it, as in Lightroom.
    private var presetSelection: Binding<UUID?> {
        Binding(get: { selectedPreset?.id },
                set: { id in
                    guard let preset = presets.first(where: { $0.id == id }) else { return }
                    preset.apply(to: &draft)
                    if let longEdge = draft.longEdge { lastLongEdge = longEdge }
                    if let watermark = draft.watermark { lastWatermark = watermark }
                })
    }

    private func addPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // The same name replaces that preset rather than making a second one.
        let id = userPresets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id ?? UUID()
        save(ExportPreset(name: name, settings: draft, id: id))
    }

    private func update(_ preset: ExportPreset) {
        save(ExportPreset(name: preset.name, settings: draft, id: preset.id))
    }

    private func save(_ preset: ExportPreset) {
        do {
            try store.save(preset)
            presetError = nil
        } catch {
            presetError = "The preset could not be saved: \(error.localizedDescription)"
        }
        userPresets = store.userPresets()
    }

    private func deletePreset(_ preset: ExportPreset) {
        do {
            try store.delete(preset.id)
            presetError = nil
            DeleteFeedback.play(.remove)
        } catch {
            presetError = "The preset could not be deleted: \(error.localizedDescription)"
        }
        userPresets = store.userPresets()
        deleting = nil
    }

    // MARK: Settings

    private var settingsForm: some View {
        Form {
            Section("File") {
                Picker("Format", selection: $draft.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if draft.format.hasQuality {
                    SliderRow(label: "Quality",
                              value: Binding(get: { (draft.quality * 100).rounded() }, set: { draft.quality = $0 / 100 }),
                              range: 50...100, step: 1, origin: 50, reset: { draft.quality = 0.9 })
                }
            }

            Section {
                Toggle("Resize to fit", isOn: resizeBinding)
                if draft.longEdge != nil {
                    LabeledContent("Long edge") {
                        HStack {
                            TextField("Long edge", value: longEdgeBinding, format: .number)
                                .labelsHidden()
                                .frame(width: 80)
                            Text("pixels")
                        }
                    }
                }
            } header: {
                Text("Size")
            } footer: {
                Text(draft.longEdge != nil ? "Photos smaller than this keep their size." : "Photos export at their full resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Color and sharpening") {
                Picker("Color space", selection: $draft.colorSpace) {
                    ForEach(ExportColorSpace.exportChoices, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Sharpening", selection: $draft.sharpening) {
                    ForEach(ExportSharpening.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section {
                Picker("Metadata", selection: $draft.metadata) {
                    ForEach(ExportMetadata.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(metadataNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            watermarkSection

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(destinationPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destinationPath)
                        Button("Change…", action: chooseDestination)
                    }
                }
                Toggle("Show in Finder when done", isOn: $reveal)
            } header: {
                Text("Save to")
            } footer: {
                Text("Files keep their original names. Existing files are never replaced; a number is added instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var resizeBinding: Binding<Bool> {
        Binding(get: { draft.longEdge != nil },
                set: { draft.longEdge = $0 ? lastLongEdge : nil })
    }

    private var longEdgeBinding: Binding<Int> {
        Binding(get: { draft.longEdge ?? lastLongEdge },
                set: {
                    lastLongEdge = $0
                    draft.longEdge = $0
                })
    }

    private var metadataNote: String {
        switch draft.metadata {
        case .all: return "Camera details, location, and your keywords, title, caption and rating."
        case .allExceptLocation: return "Camera details and your keywords, title, caption and rating. GPS location is removed."
        case .none: return "Only the color profile is kept."
        }
    }

    // MARK: Watermark

    private var watermarkSection: some View {
        Section {
            Toggle("Add watermark", isOn: watermarkBinding)
            if draft.watermark != nil {
                watermarkPreview
                Picker("Style", selection: mark.style) {
                    ForEach(ExportWatermark.Style.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if mark.wrappedValue.style == .text {
                    TextField("Text", text: mark.text)
                    Picker("Color", selection: mark.textColor) {
                        ForEach(ExportWatermark.TextColor.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Image") {
                        HStack {
                            let path = mark.wrappedValue.imagePath
                            Text(path.map { ($0 as NSString).lastPathComponent } ?? "None")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(path == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                                .help(path ?? "Choose a PNG with a transparent background")
                            Button("Choose…", action: chooseWatermarkImage)
                        }
                    }
                }
                SliderRow(label: "Size", value: percent(\.size), range: 3...90, step: 1, origin: 3,
                          format: { "\(Int($0.rounded()))%" },
                          reset: { mark.wrappedValue.size = ExportWatermark(text: "").size },
                          trackHelp: "The watermark's width as a share of the photo's width")
                SliderRow(label: "Opacity", value: percent(\.opacity), range: 5...100, step: 1, origin: 5,
                          format: { "\(Int($0.rounded()))%" },
                          reset: { mark.wrappedValue.opacity = ExportWatermark(text: "").opacity })
                LabeledContent("Position") {
                    AnchorGrid(selection: mark.anchor)
                }
                SliderRow(label: "Inset", value: percent(\.inset), range: 0...20, step: 0.5, origin: 0,
                          format: { String(format: "%.1f%%", $0) },
                          reset: { mark.wrappedValue.inset = ExportWatermark(text: "").inset },
                          trackHelp: "The gap to the photo's edges as a share of its short side")
                Toggle("Shadow", isOn: mark.shadow)
            }
        } header: {
            Text("Watermark")
        } footer: {
            Text(watermarkNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var watermarkNote: String {
        guard let watermark = draft.watermark else { return "Adds your name or logo to every exported photo." }
        if watermark.style == .image, watermark.imagePath == nil { return "Choose an image for the watermark, or turn it off." }
        if watermark.style == .text, !watermark.hasContent { return "Type the watermark's text, or turn it off." }
        return "Size and position follow each photo's shape, so the mark looks the same at every export size."
    }

    private var watermarkBinding: Binding<Bool> {
        Binding(get: { draft.watermark != nil },
                set: { draft.watermark = $0 ? lastWatermark : nil })
    }

    /// The watermark being edited; edits are kept for when it's turned off and on again.
    private var mark: Binding<ExportWatermark> {
        Binding(get: { draft.watermark ?? lastWatermark },
                set: {
                    draft.watermark = $0
                    lastWatermark = $0
                })
    }

    /// A 0...1 watermark value shown as a percentage.
    private func percent(_ keyPath: WritableKeyPath<ExportWatermark, Double>) -> Binding<Double> {
        Binding(get: { mark.wrappedValue[keyPath: keyPath] * 100 },
                set: { mark.wrappedValue[keyPath: keyPath] = $0 / 100 })
    }

    /// The first photo with the watermark drawn the way the export will draw it.
    @ViewBuilder private var watermarkPreview: some View {
        HStack {
            Spacer()
            if let previewPhoto,
               let rendered = Self.previewContext.createCGImage(Watermark.apply(draft.watermark, to: previewPhoto),
                                                                from: previewPhoto.extent,
                                                                format: .RGBA8,
                                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                Image(decorative: rendered, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 460, maxHeight: 200)
                    .help("The first photo, as it will be exported")
            } else {
                Text("No preview yet")
                    .foregroundStyle(.secondary)
                    .frame(height: 120)
            }
            Spacer()
        }
    }

    private func loadPreviewPhoto() async {
        guard let id = model.exportIDs.first else { return }
        var image: NSImage?
        if let url = model.thumbnailURL(for: id, size: .preview) {
            image = await PreviewImages.shared.load(id, at: url)
        }
        if image == nil, let url = model.thumbnailURL(for: id, size: .thumbnail) {
            image = await Task.detached(priority: .userInitiated) { ThumbnailLoader.decode(url) }.value
        }
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // Small enough to redraw on every slider step.
        var photo = CIImage(cgImage: cgImage)
        let scale = min(1, 920 / max(photo.extent.width, photo.extent.height))
        photo = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = photo.extent.integral
        guard let small = Self.previewContext.createCGImage(photo, from: extent, format: .RGBA8,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        previewPhoto = CIImage(cgImage: small)
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .tiff, .jpeg, .heic]
        panel.prompt = "Choose"
        panel.message = "Choose a logo for the watermark. A PNG with a transparent background works best."
        if let path = mark.wrappedValue.imagePath {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { mark.wrappedValue.imagePath = url.path }
    }

    // MARK: Export

    private var canExport: Bool {
        guard count > 0 else { return false }
        if let longEdge = draft.longEdge, longEdge < 64 { return false }
        if let watermark = draft.watermark, !watermark.hasContent { return false }
        return true
    }

    private var exportSettings: ExportSettings {
        var settings = draft
        settings.destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        settings.longEdge = draft.longEdge.map { max(64, $0) }
        return settings
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where exported photos are saved"
        panel.directoryURL = URL(fileURLWithPath: destinationPath)
        if panel.runModal() == .OK, let url = panel.url { destinationPath = url.path }
    }

    // MARK: Remembered choices

    private static let lastSettingsKey = "export.lastSettings"
    private static let lastWatermarkKey = "export.lastWatermark"

    /// The last export's choices. The first time, they're read from the keys the dialog used
    /// before presets, so nothing Rosh picked is lost.
    static func loadLast() -> (settings: ExportSettings, watermark: ExportWatermark) {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let watermark = defaults.data(forKey: lastWatermarkKey).flatMap { try? decoder.decode(ExportWatermark.self, from: $0) }
            ?? ExportWatermark.copyright(owner: NSFullUserName())
        if let data = defaults.data(forKey: lastSettingsKey), let settings = try? decoder.decode(ExportSettings.self, from: data) {
            return (settings, watermark)
        }
        var settings = ExportSettings(destination: URL(fileURLWithPath: NSTemporaryDirectory()))
        settings.sharpening = .screen
        if let raw = defaults.string(forKey: "export.format"), let format = ExportFormat(rawValue: raw) { settings.format = format }
        if defaults.object(forKey: "export.quality") != nil { settings.quality = defaults.double(forKey: "export.quality") / 100 }
        let longEdge = defaults.object(forKey: "export.longEdge") != nil ? defaults.integer(forKey: "export.longEdge") : 2048
        settings.longEdge = (defaults.object(forKey: "export.resize") as? Bool ?? true) ? longEdge : nil
        if let raw = defaults.string(forKey: "export.colorSpace"), let space = ExportColorSpace(rawValue: raw) { settings.colorSpace = space }
        if let raw = defaults.string(forKey: "export.metadata"), let metadata = ExportMetadata(rawValue: raw) { settings.metadata = metadata }
        if let raw = defaults.string(forKey: "export.sharpening"), let sharpening = ExportSharpening(rawValue: raw) {
            settings.sharpening = sharpening
        }
        return (settings, watermark)
    }

    static func saveLast(_ settings: ExportSettings, watermark: ExportWatermark) {
        let encoder = JSONEncoder()
        UserDefaults.standard.set(try? encoder.encode(settings), forKey: lastSettingsKey)
        UserDefaults.standard.set(try? encoder.encode(watermark), forKey: lastWatermarkKey)
    }
}

/// Nine dots for where the watermark sits, as in Lightroom's Watermark Editor.
private struct AnchorGrid: View {
    @Binding var selection: ExportWatermark.Anchor

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        dot(ExportWatermark.Anchor.allCases[row * 3 + column])
                    }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func dot(_ anchor: ExportWatermark.Anchor) -> some View {
        Button {
            selection = anchor
        } label: {
            Image(systemName: selection == anchor ? "circle.fill" : "circle")
                .font(.system(size: 9))
                .frame(width: 22, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == anchor ? Color.accentColor : Color.secondary)
        .help(anchor.label)
        .accessibilityLabel(anchor.label)
    }
}
