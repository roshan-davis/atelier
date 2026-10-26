import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// The import dialog. It opens first; photos are chosen or dropped inside it.
struct ImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("import.copy") private var copyFiles = false
    @AppStorage("import.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Library").path

    @State private var sources: [URL] = []
    /// Photos found per source; nil while scanning.
    @State private var counts: [URL: Int] = [:]
    /// nil means a new import entry.
    @State private var existingGroup: Int64?
    @State private var name = ""
    @State private var keywords = ""
    @State private var dropTargeted = false

    private var photoCount: Int? {
        let values = sources.map { counts[$0] }
        if values.contains(where: { $0 == nil }) { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    private var suggestedName: String {
        sources.first?.lastPathComponent ?? "New Import"
    }

    /// The entry name, which also names the event folder in copy mode.
    private var effectiveName: String {
        if let existingGroup, let entry = model.sidebar.imports.first(where: { $0.id == existingGroup }) {
            return entry.name
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    private var canImport: Bool {
        !sources.isEmpty && (photoCount ?? 1) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Photos")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Form {
                Section("Photos") {
                    if sources.isEmpty {
                        dropZone
                    } else {
                        ForEach(sources, id: \.self) { url in
                            SourceRow(url: url, count: counts[url]) {
                                sources.removeAll { $0 == url }
                            }
                        }
                        HStack {
                            Button("Add More…", action: choose)
                            Spacer()
                            summary
                        }
                    }
                }

                Section("Import into") {
                    Picker("Entry", selection: $existingGroup) {
                        Text("New import").tag(Int64?.none)
                        if !model.sidebar.imports.isEmpty {
                            Divider()
                            ForEach(model.sidebar.imports) { entry in
                                Text("\(entry.name) (\(entry.photoCount))").tag(Int64?.some(entry.id))
                            }
                        }
                    }
                    if existingGroup == nil {
                        TextField("Name", text: $name, prompt: Text(suggestedName))
                    }
                }

                Section("Files") {
                    Picker("Files", selection: $copyFiles) {
                        Text("Leave files where they are").tag(false)
                        Text("Copy into my library folder").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if copyFiles {
                        LabeledContent("Library folder") {
                            HStack {
                                Text(destinationPath).lineLimit(1).truncationMode(.middle)
                                Button("Change…", action: chooseDestination)
                            }
                        }
                        Text("Copies go to YYYY/YYYY-MM-DD \(effectiveName)/ and each one is checked against the original.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Photos stay in their current folders, on this Mac or the NAS. Nothing is moved or changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Keywords") {
                    TextField("Keywords", text: $keywords, prompt: Text("Added to every photo, comma separated"))
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importButtonTitle) {
                    model.runImport(sources: sources, options: options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            existingGroup = model.pendingImportGroup
            add(model.pendingImportSources)
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: Pieces

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Drag folders or photos here")
                .font(.headline)
            Button("Choose Folders or Photos…", action: choose)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var summary: some View {
        if let photoCount {
            Text(photoCount == 0 ? "No photos found" : "\(photoCount) photo\(photoCount == 1 ? "" : "s")")
                .foregroundStyle(photoCount == 0 ? Color.orange : Color.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var importButtonTitle: String {
        guard let photoCount, photoCount > 0 else { return "Import" }
        return "Import \(photoCount) Photo\(photoCount == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        for url in urls where !sources.contains(url) {
            sources.append(url)
            Task.detached(priority: .userInitiated) {
                let count = Importer.collectFiles(from: [url]).count
                await MainActor.run { counts[url] = count }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Add"
        panel.message = "Choose folders or photos to import"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    private var options: ImportOptions {
        let mode: ImportMode = copyFiles
            ? .copy(destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true), eventName: effectiveName)
            : .reference
        let target: ImportTarget = existingGroup.map { .existingGroup($0) } ?? .newGroup(name: effectiveName)
        return ImportOptions(mode: mode, target: target, keywords: keywords.split(separator: ",").map(String.init))
    }
}

private struct SourceRow: View {
    let url: URL
    let count: Int?
    let remove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: url.hasDirectoryPath ? "folder" : "photo")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let count {
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from this import")
        }
    }
}
