import AtelierCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        if model.mode == .develop {
            DevelopPanel(develop: model.develop)
        } else if let detail = model.detail {
            DetailForm(detail: detail)
                .id(detail.asset.id)
        } else {
            Text("No photo selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DetailForm: View {
    @EnvironmentObject private var model: LibraryModel
    let detail: AssetDetail

    @State private var keywords = ""
    @State private var title = ""
    @State private var caption = ""
    @State private var info: ShootingInfo?
    @State private var histogram: Histogram?
    @State private var loading = true

    private var appliesTo: String {
        let count = model.targetIDs.count
        return count > 1 ? "Applies to \(count) selected photos" : ""
    }

    var body: some View {
        Form {
            Section {
                LibraryHistogram(histogram: histogram, info: info, isLoading: loading)
            }

            Section("File") {
                LabeledContent("File Name", value: detail.asset.filename)
                if let formats = model.rows.first(where: { $0.id == detail.asset.id })?.pairedFormats {
                    LabeledContent("Paired With", value: formats.split(separator: ",").map {
                        (detail.asset.filename as NSString).deletingPathExtension + "." + $0
                    }.joined(separator: ", "))
                    .help("Files shot together with this RAW, such as the camera's JPEG. They are shown as one photo; "
                          + "Settings > Import changes this.")
                }
                if let copy = model.virtualCopyName(detail.asset.id) {
                    LabeledContent("Copy Name", value: copy)
                }
                LabeledContent("Folder", value: detail.folder.displayName)
                LabeledContent("Volume") {
                    Text(detail.volume.name + (detail.volume.isOnline ? "" : " (offline)"))
                }
                if let width = detail.asset.width, let height = detail.asset.height {
                    LabeledContent("Dimensions", value: "\(width) × \(height)" + Self.megapixels(width, height))
                }
                LabeledContent("File Size", value: ByteCountFormatter.string(fromByteCount: detail.asset.fileSize, countStyle: .file))
            }

            Section("Camera") {
                if let date = detail.asset.captureTime {
                    LabeledContent("Capture Time", value: date.formatted(date: .abbreviated, time: .standard))
                }
                if let camera = info?.camera ?? ShootingInfo.cameraName(make: detail.asset.cameraMake, model: detail.asset.cameraModel) {
                    LabeledContent("Camera", value: camera)
                }
                if let lens = info?.lens ?? detail.asset.lens {
                    LabeledContent("Lens", value: lens)
                }
                if let exposure = info?.exposure {
                    LabeledContent("Exposure", value: exposure)
                }
                if let iso = info?.iso {
                    LabeledContent("ISO Speed", value: ShootingInfo.formatISO(iso))
                }
                if let focal = info?.focalLengthDescription {
                    LabeledContent("Focal Length", value: focal)
                }
                if let bias = info?.exposureCompensation {
                    LabeledContent("Exposure Bias", value: ShootingInfo.formatExposureCompensation(bias))
                }
                if let flash = info?.flash {
                    LabeledContent("Flash", value: flash)
                }
                if let program = info?.exposureProgram {
                    LabeledContent("Exposure Program", value: program)
                }
                if let metering = info?.meteringMode {
                    LabeledContent("Metering Mode", value: metering)
                }
                if info?.isEmpty == true, detail.asset.cameraModel == nil {
                    Text("No camera settings in this file").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Rating") {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                model.setRating(detail.metadata.rating == star ? 0 : star)
                            } label: {
                                Image(systemName: star <= detail.metadata.rating ? "star.fill" : "star")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Picker("Flag", selection: Binding(
                    get: { detail.metadata.flag },
                    set: { model.setFlag($0) })) {
                    Text("None").tag(Flag.none)
                    Text("Picked").tag(Flag.picked)
                    Text("Rejected").tag(Flag.rejected)
                }
                Picker("Label", selection: Binding(
                    get: { detail.metadata.colorLabel },
                    set: { newValue in
                        if let newValue {
                            model.toggleLabel(newValue)
                        } else if let current = detail.metadata.colorLabel {
                            model.toggleLabel(current)
                        }
                    })) {
                    Text("None").tag(ColorLabel?.none)
                    ForEach(ColorLabel.allCases, id: \.self) { label in
                        Text(label.rawValue).tag(ColorLabel?.some(label))
                    }
                }
            } header: {
                Text("Rating and labels")
            } footer: {
                Text(appliesTo).font(.caption)
            }

            Section("Keywords") {
                TextField("Comma separated", text: $keywords, axis: .vertical)
                    .onSubmit { model.setKeywords(keywords) }
                Button("Apply Keywords") { model.setKeywords(keywords) }
            }

            Section("Title and caption") {
                TextField("Title", text: $title)
                TextField("Caption", text: $caption, axis: .vertical)
                    .lineLimit(2...5)
                Button("Save") { model.setTitle(title, caption: caption) }
            }

            if detail.metadata.xmpDirty {
                Section {
                    Button("Write XMP Sidecar") { model.writeXMP(selectionOnly: true) }
                    Text("Changes are saved in the catalog. Write XMP so other apps see them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Let the theme's panel color show through.
        .scrollContentBackground(.hidden)
        .onAppear(perform: syncFields)
        .onChange(of: detail) { syncFields() }
        .task(id: InfoKey(id: detail.asset.id, revision: model.previewRevision, url: detail.fileURL)) {
            await loadInfo()
        }
    }

    private struct InfoKey: Equatable {
        var id: Int64?
        var revision: Int
        var url: URL?
    }

    /// The camera settings from the file and the histogram from the preview, which shows the edits.
    private func loadInfo() async {
        loading = true
        defer { loading = false }
        if let url = detail.fileURL {
            info = await ShootingInfoCache.info(for: url)
        }
        guard let id = detail.asset.id,
              let preview = model.thumbnailURL(for: id, size: .preview) ?? model.thumbnailURL(for: id, size: .thumbnail) else { return }
        let loaded = await Task.detached(priority: .userInitiated) { LibraryHistogram.load(from: preview) }.value
        if !Task.isCancelled { histogram = loaded }
    }

    private static func megapixels(_ width: Int, _ height: Int) -> String {
        let mp = Double(width * height) / 1_000_000
        return mp >= 1 ? String(format: " (%.1f MP)", mp) : ""
    }

    private func syncFields() {
        keywords = detail.keywords.joined(separator: ", ")
        title = detail.metadata.title ?? ""
        caption = detail.metadata.caption ?? ""
    }
}
