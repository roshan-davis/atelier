import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// The import dialog. It opens first; photos are chosen or dropped inside it. With Cull before
/// importing on it is a wizard (settings, cull, import); otherwise the progress replaces the
/// settings in place. Either way the dialog stays open until every file is copied.
struct ImportSheet: View {
    enum Step: Int, CaseIterable {
        case settings, cull, importing
    }

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
    /// The develop preset applied to new photos, remembered between imports.
    @AppStorage("import.developPreset") private var presetID = ""

    /// The presets by group, as in the Presets panel, keeping a hidden pack's preset if it is the
    /// one already chosen.
    private var presetGroups: [(String, [DevelopPreset])] {
        var result: [(String, [DevelopPreset])] = []
        for preset in model.develop.presets
        where model.develop.visiblePresets.contains(preset) || preset.id.uuidString == presetID {
            if let index = result.firstIndex(where: { $0.0 == preset.group }) {
                result[index].1.append(preset)
            } else {
                result.append((preset.group, [preset]))
            }
        }
        return result
    }
    @AppStorage("import.cull") private var cullFirst = false
    @State private var dropTargeted = false
    @State private var step = Step.settings
    /// The Cull step, made on Continue to Culling.
    @State private var cull: CullModel?

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
        VStack(spacing: 0) {
            if cullFirst {
                ImportSteps(current: step)
                Divider()
            }
            switch step {
            case .settings:
                settingsStep
            case .cull:
                if let cull {
                    CullView(cull: cull)
                }
            case .importing:
                ImportProgressStep(copying: copyFiles) { dismiss() }
            }
        }
        .onAppear {
            existingGroup = model.pendingImportGroup
            add(model.pendingImportSources)
        }
        .onDisappear {
            cull?.stop()
            cull = nil
        }
    }

    private var settingsStep: some View {
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

                Section("Apply During Import") {
                    Picker("Develop Settings", selection: $presetID) {
                        Text("None").tag("")
                        ForEach(presetGroups, id: \.0) { group in
                            Section(group.0) {
                                ForEach(group.1) { preset in
                                    Text(preset.name).tag(preset.id.uuidString)
                                }
                            }
                        }
                    }
                    TextField("Keywords", text: $keywords, prompt: Text("Added to every photo, comma separated"))
                }

                Section {
                    Toggle("Cull before importing", isOn: $cullFirst)
                } footer: {
                    Text("Groups similar shots and suggests the best of each, so you pick the keepers first. Only keepers go into the import entry; the rest are cataloged as Rejected and can be reviewed later with Photo > Show Cull Group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importButtonTitle, action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
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
        if cullFirst { return "Continue to Culling…" }
        guard let photoCount, photoCount > 0 else { return "Import" }
        return "Import \(photoCount) Photo\(photoCount == 1 ? "" : "s")"
    }

    // MARK: Actions

    /// Import, or with culling on, the Cull step; both stay in this dialog.
    private func start() {
        var options = self.options
        options.developPreset = model.develop.presets.first { $0.id.uuidString == presetID }
        guard cullFirst else {
            model.runImport(sources: sources, options: options)
            step = .importing
            return
        }
        let cull = model.importCull(sources: sources, options: options)
        cull.onBack = {
            self.cull = nil
            step = .settings
        }
        cull.onClose = { imported in
            self.cull = nil
            if imported {
                step = .importing
            } else {
                dismiss()
            }
        }
        self.cull = cull
        step = .cull
    }

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

/// The wizard's steps, shown when culling before importing: 1 Choose Photos › 2 Cull › 3 Import.
private struct ImportSteps: View {
    let current: ImportSheet.Step

    var body: some View {
        HStack(spacing: 10) {
            item(.settings, "Choose Photos")
            chevron
            item(.cull, "Cull")
            chevron
            item(.importing, "Import")
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func item(_ step: ImportSheet.Step, _ title: String) -> some View {
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(isDone ? 0.35 : 0.18))
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                } else {
                    Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .bold))
                }
            }
            .frame(width: 18, height: 18)
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            Text(title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        }
    }
}

/// The import's progress inside the dialog: count, amount copied, speed, time left and the file
/// being copied, with Cancel. Run in Background closes the dialog and leaves the progress in the
/// status bar. The dialog closes by itself when every file is in.
struct ImportProgressStep: View {
    @EnvironmentObject private var model: LibraryModel
    let copying: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copying ? "Copying Photos" : "Adding Photos")
                .font(.title2.bold())
            if let progress = model.importProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.phase)
                        .font(.headline)
                        .monospacedDigit()
                    Group {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    if let detail = progress.detail {
                        Text(detail)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(progress.file ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(copying
                 ? "Each copy is checked against the original. Thumbnails are made when every photo is copied. Photos copied before you cancel stay in the catalog."
                 : "Thumbnails are made when every photo is added. Photos added before you cancel stay in the catalog.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Run in Background", action: close)
                    .help("Close this dialog; the progress stays in the status bar")
                Button("Cancel Import", role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.importProgress?.phase == "Cancelling…")
            }
        }
        .padding(20)
        .frame(width: 560, height: 280, alignment: .topLeading)
        .onChange(of: model.importProgress == nil) { _, finished in
            if finished { close() }
        }
        .onAppear {
            if model.importProgress == nil { close() }
        }
    }
}
