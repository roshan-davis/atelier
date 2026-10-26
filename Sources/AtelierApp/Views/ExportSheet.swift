import AppKit
import AtelierCore
import SwiftUI

/// The export dialog: format, size, color and metadata choices for the selected photos.
/// Settings are remembered between exports.
struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 90.0
    @AppStorage("export.resize") private var resize = true
    @AppStorage("export.longEdge") private var longEdge = 2048
    @AppStorage("export.colorSpace") private var colorSpace: ExportColorSpace = .sRGB
    @AppStorage("export.metadata") private var metadata: ExportMetadata = .allExceptLocation
    @AppStorage("export.sharpening") private var sharpening: ExportSharpening = .screen
    @AppStorage("export.reveal") private var reveal = true
    @AppStorage("export.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Exports").path

    private var count: Int { model.exportIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export \(count) Photo\(count == 1 ? "" : "s")")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Form {
                Section("Quick settings") {
                    HStack {
                        Button("Website") { applyWebsite() }
                            .help("JPEG, 2048 px long edge, sRGB, sharpened for screen, no location")
                        Button("Full-Size JPEG") { applyFullSizeJPEG() }
                        Button("Full-Size TIFF") { applyFullSizeTIFF() }
                            .help("16-bit TIFF in Adobe RGB, for print or further editing")
                    }
                }

                Section("File") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if format.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $quality, in: 50...100, step: 1)
                                Text("\(Int(quality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Resize to fit", isOn: $resize)
                    if resize {
                        LabeledContent("Long edge") {
                            HStack {
                                TextField("Long edge", value: $longEdge, format: .number)
                                    .labelsHidden()
                                    .frame(width: 80)
                                Text("pixels")
                            }
                        }
                    }
                } header: {
                    Text("Size")
                } footer: {
                    Text(resize ? "Photos smaller than this keep their size." : "Photos export at their full resolution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Color and sharpening") {
                    Picker("Color space", selection: $colorSpace) {
                        ForEach(ExportColorSpace.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Sharpening", selection: $sharpening) {
                        ForEach(ExportSharpening.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Picker("Metadata", selection: $metadata) {
                        ForEach(ExportMetadata.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(metadataNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(destinationPath).lineLimit(1).truncationMode(.middle)
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

            HStack {
                Text("Edits are applied. Originals are not changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export \(count) Photo\(count == 1 ? "" : "s")") {
                    model.runExport(settings: settings, revealWhenDone: reveal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || (resize && longEdge < 64))
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
    }

    private var metadataNote: String {
        switch metadata {
        case .all: return "Camera details, location, and your keywords, title, caption and rating."
        case .allExceptLocation: return "Camera details and your keywords, title, caption and rating. GPS location is removed."
        case .none: return "Only the color profile is kept."
        }
    }

    private var settings: ExportSettings {
        var settings = ExportSettings(destination: URL(fileURLWithPath: destinationPath, isDirectory: true))
        settings.format = format
        settings.quality = quality / 100
        settings.longEdge = resize ? max(64, longEdge) : nil
        settings.colorSpace = colorSpace
        settings.metadata = metadata
        settings.sharpening = sharpening
        return settings
    }

    private func applyWebsite() {
        format = .jpeg
        quality = 85
        resize = true
        longEdge = 2048
        colorSpace = .sRGB
        sharpening = .screen
        metadata = .allExceptLocation
    }

    private func applyFullSizeJPEG() {
        format = .jpeg
        quality = 95
        resize = false
        colorSpace = .sRGB
        sharpening = .none
        metadata = .all
    }

    private func applyFullSizeTIFF() {
        format = .tiff
        resize = false
        colorSpace = .adobeRGB
        sharpening = .none
        metadata = .all
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
}
