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
    /// Redraws on new previews (`PreviewRevision`).
    @ObservedObject private var previewRevision = PreviewRevision.shared
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

    @AppStorage("library.expandedPanels") private var expandedList = "histogram,file,camera,rating,keywords,caption"
    @AppStorage("library.soloMode") private var soloMode = false
    private static let panels = ["histogram", "file", "camera", "rating", "keywords", "caption"]

    private var expanded: Set<String> { Set(expandedList.split(separator: ",").map(String.init)) }

    /// The same collapsible headers as Develop's panels, with Solo Mode and Expand/Collapse All.
    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { open in
            var set = expanded
            if open {
                if soloMode, id != "histogram" { set = set.filter { $0 == "histogram" } }
                set.insert(id)
            } else {
                set.remove(id)
            }
            expandedList = set.sorted().joined(separator: ",")
        })
    }

    private func expandAll() { expandedList = Self.panels.joined(separator: ",") }
    private func collapseAll() { expandedList = "" }

    private func section<Content: View>(_ title: String, _ id: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        PanelSection(title: title, isExpanded: isExpanded(id), soloMode: $soloMode,
                     expandAll: expandAll, collapseAll: collapseAll, content: content)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                section("Histogram", "histogram") {
                    LibraryHistogram(histogram: histogram, info: info, isLoading: loading)
                }
                section("File", "file") {
                    VStack(alignment: .leading, spacing: 5) {
                        InfoRow("File Name", detail.asset.filename)
                        if let formats = model.rows.first(where: { $0.id == detail.asset.id })?.pairedFormats {
                            InfoRow("Paired With", formats.split(separator: ",").map {
                                (detail.asset.filename as NSString).deletingPathExtension + "." + $0
                            }.joined(separator: ", "),
                                    help: "Files shot together with this RAW, such as the camera's JPEG. They are shown as one "
                                        + "photo; Settings > Import changes this.")
                        }
                        if let copy = model.virtualCopyName(detail.asset.id) {
                            InfoRow("Copy Name", copy)
                        }
                        InfoRow("Folder", detail.folder.displayName)
                        InfoRow("Volume", detail.volume.name + (detail.volume.isOnline ? "" : " (offline)"))
                        if let width = detail.asset.width, let height = detail.asset.height {
                            InfoRow("Dimensions", "\(width) × \(height)" + Self.megapixels(width, height))
                        }
                        InfoRow("File Size", ByteCountFormatter.string(fromByteCount: detail.asset.fileSize, countStyle: .file))
                    }
                }
                section("Camera", "camera") {
                    VStack(alignment: .leading, spacing: 5) {
                        if let date = detail.asset.captureTime {
                            InfoRow("Capture Time", date.formatted(date: .abbreviated, time: .standard))
                        }
                        if let camera = info?.camera ?? ShootingInfo.cameraName(make: detail.asset.cameraMake, model: detail.asset.cameraModel) {
                            InfoRow("Camera", camera)
                        }
                        if let lens = info?.lens ?? detail.asset.lens {
                            InfoRow("Lens", lens)
                        }
                        if let exposure = info?.exposure {
                            InfoRow("Exposure", exposure)
                        }
                        if let iso = info?.iso {
                            InfoRow("ISO Speed", ShootingInfo.formatISO(iso))
                        }
                        if let focal = info?.focalLengthDescription {
                            InfoRow("Focal Length", focal)
                        }
                        if let bias = info?.exposureCompensation {
                            InfoRow("Exposure Bias", ShootingInfo.formatExposureCompensation(bias))
                        }
                        if let flash = info?.flash {
                            InfoRow("Flash", flash)
                        }
                        if let program = info?.exposureProgram {
                            InfoRow("Program", program)
                        }
                        if let metering = info?.meteringMode {
                            InfoRow("Metering", metering)
                        }
                        if info?.isEmpty == true, detail.asset.cameraModel == nil {
                            Text("No camera settings in this file").foregroundStyle(.secondary)
                        }
                    }
                }
                section("Rating and Labels", "rating") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            InfoLabel("Rating")
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
                        HStack(spacing: 8) {
                            InfoLabel("Flag")
                            Picker("Flag", selection: Binding(
                                get: { detail.metadata.flag },
                                set: { model.setFlag($0) })) {
                                Text("None").tag(Flag.none)
                                Text("Picked").tag(Flag.picked)
                                Text("Rejected").tag(Flag.rejected)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        HStack(spacing: 8) {
                            InfoLabel("Label")
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
                            .labelsHidden()
                            .fixedSize()
                        }
                        if !appliesTo.isEmpty {
                            Text(appliesTo).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                section("Keywords", "keywords") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Comma separated", text: $keywords, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.setKeywords(keywords) }
                        Button("Apply Keywords") { model.setKeywords(keywords) }
                    }
                }
                section("Title and Caption", "caption") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                        TextField("Caption", text: $caption, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                        Button("Save") { model.setTitle(title, caption: caption) }
                    }
                }
                if detail.metadata.xmpDirty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Write XMP Sidecar") { model.writeXMP(selectionOnly: true) }
                        Text("Changes are saved in the catalog. Write XMP so other apps see them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear(perform: syncFields)
        .onChange(of: detail) { syncFields() }
        .task(id: InfoKey(id: detail.asset.id, revision: previewRevision.value, url: detail.fileURL)) {
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

/// A label in the Library's right panel: one column wide, so the values line up.
private struct InfoLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 86, alignment: .leading)
    }
}

/// A name and value on one line. A value too long for the panel ends in an ellipsis (in the
/// middle for names and paths, so both ends stay readable) and shows in full on hover.
private struct InfoRow: View {
    let label: String
    let value: String
    var help: String?

    init(_ label: String, _ value: String, help: String? = nil) {
        self.label = label
        self.value = value
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            InfoLabel(label)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help.map { "\(value)\n\n\($0)" } ?? value)
        }
        .font(.callout)
    }
}
