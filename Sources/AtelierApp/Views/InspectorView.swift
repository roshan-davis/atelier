import AtelierCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        if let detail = model.detail {
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

    private var appliesTo: String {
        let count = model.targetIDs.count
        return count > 1 ? "Applies to \(count) selected photos" : ""
    }

    var body: some View {
        Form {
            Section("Photo") {
                LabeledContent("File", value: detail.asset.filename)
                LabeledContent("Volume") {
                    Text(detail.volume.name + (detail.volume.isOnline ? "" : " (offline)"))
                }
                LabeledContent("Folder", value: detail.folder.displayName)
                if let date = detail.asset.captureTime {
                    LabeledContent("Captured", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let width = detail.asset.width, let height = detail.asset.height {
                    LabeledContent("Size", value: "\(width) × \(height)")
                }
                if let camera = [detail.asset.cameraMake, detail.asset.cameraModel]
                    .compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                    LabeledContent("Camera", value: camera)
                }
                if let lens = detail.asset.lens {
                    LabeledContent("Lens", value: lens)
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
        .onAppear(perform: syncFields)
        .onChange(of: detail) { syncFields() }
    }

    private func syncFields() {
        keywords = detail.keywords.joined(separator: ", ")
        title = detail.metadata.title ?? ""
        caption = detail.metadata.caption ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
