import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// Atelier > Settings… (⌘,). Values live in user defaults under the same keys the dialogs use,
/// so a default set here is what the Import and Export dialogs start with.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ImportSettings()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
            DevelopSettingsTab()
                .tabItem { Label("Develop", systemImage: "slider.horizontal.3") }
            ExportSettingsTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            EditInSettings()
                .tabItem { Label("Edit In", systemImage: "paintbrush") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "wand.and.stars") }
            MetadataSettings()
                .tabItem { Label("Metadata", systemImage: "tag") }
            KeyboardSettings()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .frame(width: 640)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(Theme.defaultsKey) private var theme: Theme = .system

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Theme.allCases) { option in
                    ThemeCard(theme: option, isSelected: option == theme) { theme = option }
                }
            }
            Text(theme.summary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .onChange(of: theme) { _, newTheme in newTheme.apply() }
    }
}

/// A small picture of the window in a theme: sidebar, photo on its surround, and the panel.
private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                preview
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: isSelected ? 3 : 1))
                Text(theme.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.summary)
    }

    @ViewBuilder private var preview: some View {
        if theme == .system {
            // Half light, half dark.
            HStack(spacing: 0) {
                miniWindow(appearance: .aqua)
                miniWindow(appearance: .darkAqua)
            }
        } else {
            miniWindow(appearance: theme.appearanceName ?? .aqua)
        }
    }

    private func miniWindow(appearance: NSAppearance.Name) -> some View {
        let isDark = appearance == .darkAqua
        let custom = theme != .system && theme != .light && theme != .dark
        let sidebar = Color(white: isDark ? 0.2 : 0.9)
        let surround = custom ? Color(nsColor: theme.surround) : Color(white: isDark ? 0.13 : 0.78)
        let panel = custom ? Color(nsColor: theme.panel) : Color(white: isDark ? 0.18 : 0.96)
        let line = Color(white: isDark ? 0.45 : 0.6)
        return HStack(spacing: 0) {
            sidebar.frame(width: 18)
            ZStack {
                surround
                LinearGradient(colors: [Color(red: 0.35, green: 0.5, blue: 0.7), Color(red: 0.85, green: 0.7, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 44, height: 30)
            }
            ZStack(alignment: .topLeading) {
                panel
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule().fill(line).frame(height: 2)
                    }
                }
                .padding(6)
            }
            .frame(width: 34)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("backups.keep") private var backupsToKeep = 10
    @AppStorage(Splash.showKey) private var showSplash = true
    @State private var previewsSize: String?
    @State private var backupMessage: String?

    var body: some View {
        Form {
            Section("Catalog") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.catalog.packageURL?.path ?? "In memory")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            if let url = model.catalog.packageURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
                LabeledContent("Photos", value: "\(model.sidebar.totalCount)")
            }

            Section {
                Stepper("Keep the last \(backupsToKeep) backup\(backupsToKeep == 1 ? "" : "s")",
                        value: $backupsToKeep, in: 1...50)
                HStack {
                    Button("Back Up Now") { backUp() }
                    if let backupMessage {
                        Text(backupMessage).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("The catalog is backed up when Atelier quits. Backups are kept inside the catalog package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show splash screen at launch", isOn: $showSplash)
                HStack {
                    Button("Show Splash Folder") {
                        SplashController.installFolder()
                        NSWorkspace.shared.activateFileViewerSelecting([Splash.folder])
                    }
                    Button("Preview Splash Screen") { SplashController.shared.preview() }
                }
            } header: {
                Text("Splash Screen")
            } footer: {
                Text("Each launch shows the next image in the Splash folder, in name order. Add JPEG, PNG or HEIC images, ideally 1600 × 1000 px or larger. Each fills the splash, cropped around its subject.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Previews") {
                LabeledContent("Preview cache", value: previewsSize ?? "Measuring…")
                Text("Thumbnails (256 px) and previews (2560 px) are made in the background and include your edits. Originals are never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { previewsSize = await Self.measure(model.catalog.previewsURL) }
    }

    private func backUp() {
        do {
            if let url = try model.catalog.snapshot(keep: max(1, backupsToKeep)) {
                backupMessage = "Saved \(url.lastPathComponent)"
            } else {
                backupMessage = "Nothing to back up"
            }
        } catch {
            backupMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    private static func measure(_ folder: URL?) async -> String {
        guard let folder else { return "None" }
        return await Task.detached(priority: .utility) {
            var total: Int64 = 0
            var count = 0
            let keys: [URLResourceKey] = [.fileSizeKey]
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
                for case let url as URL in enumerator {
                    if let size = try? url.resourceValues(forKeys: Set(keys)).fileSize {
                        total += Int64(size)
                        count += 1
                    }
                }
            }
            return "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) in \(count) files"
        }.value
    }
}

// MARK: - Import

struct ImportSettings: View {
    @AppStorage("import.copy") private var copyFiles = false
    @AppStorage("import.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Library").path
    @AppStorage(FilePairs.groupKey) private var groupPairs = true

    var body: some View {
        Form {
            Section {
                Picker("Files", selection: $copyFiles) {
                    Text("Leave files where they are").tag(false)
                    Text("Copy into my library folder").tag(true)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Library folder") {
                    HStack {
                        Text(destinationPath).lineLimit(1).truncationMode(.middle)
                        Button("Change…") {
                            if let path = chooseFolder(message: "Choose where copied photos go", start: destinationPath) {
                                destinationPath = path
                            }
                        }
                    }
                }
            } header: {
                Text("Default for new imports")
            } footer: {
                Text("The Import dialog starts with these choices. Copies go to YYYY/YYYY-MM-DD Name/ and are checked against the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show RAW+JPEG pairs as one photo", isOn: $groupPairs)
            } header: {
                Text("RAW+JPEG")
            } footer: {
                Text("When a folder has DSC_0001.NEF and DSC_0001.JPG (or HEIC, TIFF), only the RAW is shown, marked RAW+JPG. Ratings, flags, labels, keywords, collections and import entries apply to both; editing and export use the RAW. Turn this off to see every file as its own photo. Culling always treats a pair as one shot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Develop

private struct DevelopSettingsTab: View {
    @AppStorage("zoom.clickPercent") private var clickPercent = 100.0
    @AppStorage(LibraryModel.ZoomOnPhotoChange.key) private var onPhotoChange = LibraryModel.ZoomOnPhotoChange.reset.rawValue
    @AppStorage(LibraryModel.ZoomOnPhotoChange.resetLevelKey) private var resetLevel = "fit"
    @AppStorage("develop.showClipping") private var showClipping = true
    @AppStorage("develop.soloMode") private var soloMode = false

    var body: some View {
        Form {
            Section("Zoom") {
                Picker("Double-click or Z zooms to", selection: $clickPercent) {
                    Text("50%").tag(50.0)
                    Text("100% (1:1)").tag(100.0)
                    Text("200%").tag(200.0)
                    Text("400%").tag(400.0)
                }
                Picker("When you move to another photo", selection: $onPhotoChange) {
                    Text("Open it at Fit or Fill").tag(LibraryModel.ZoomOnPhotoChange.reset.rawValue)
                    Text("Return to its last zoom").tag(LibraryModel.ZoomOnPhotoChange.remember.rawValue)
                    Text("Keep the same zoom, as in Lightroom").tag(LibraryModel.ZoomOnPhotoChange.keep.rawValue)
                }
                if onPhotoChange != LibraryModel.ZoomOnPhotoChange.keep.rawValue {
                    Picker(onPhotoChange == LibraryModel.ZoomOnPhotoChange.reset.rawValue ? "Open at" : "Photos not zoomed yet open at",
                           selection: $resetLevel) {
                        Text("Fit").tag("fit")
                        Text("Fill").tag("fill")
                    }
                }
            }
            Section("Panels") {
                Toggle("Solo mode: opening a panel closes the others", isOn: $soloMode)
                Toggle("Show shadow and highlight clipping under the histogram", isOn: $showClipping)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Export

private struct ExportSettingsTab: View {
    @AppStorage("export.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Exports").path
    @AppStorage("export.reveal") private var reveal = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Export folder") {
                    HStack {
                        Text(destinationPath).lineLimit(1).truncationMode(.middle)
                        Button("Change…") {
                            if let path = chooseFolder(message: "Choose where exported photos are saved", start: destinationPath) {
                                destinationPath = path
                            }
                        }
                    }
                }
                Toggle("Show exported files in Finder when done", isOn: $reveal)
            } header: {
                Text("Defaults")
            } footer: {
                Text("Format, size, color and metadata are chosen in File > Export… and remembered from the last export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Edit In

/// The apps offered under Photo > Edit In, and the file each one is sent.
struct EditInSettings: View {
    @State private var editors = ExternalEditorStore.load()

    var body: some View {
        Form {
            Section {
                if editors.isEmpty {
                    Text("No photo editors found. Click Add App… to pick one.")
                        .foregroundStyle(.secondary)
                }
                ForEach($editors) { $editor in
                    EditorRow(editor: $editor) {
                        editors.removeAll { $0.id == editor.id }
                    }
                }
                HStack {
                    Button("Add App…", systemImage: "plus") { addApp() }
                    Spacer()
                    Button("Find Installed Editors") {
                        for found in ExternalEditorStore.detected() where !editors.contains(where: { $0.id == found.id }) {
                            editors.append(found)
                        }
                    }
                }
            } header: {
                Text("Edit In")
            } footer: {
                Text("Photo > Edit In saves a copy next to the original (or in Pictures/Atelier/Edits when that folder is read-only), stacks it with the original, and opens it in the app. Saves in the app update Atelier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: editors) { _, newValue in ExternalEditorStore.save(newValue) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Edit In"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url,
              !editors.contains(where: { $0.appPath == url.path }) else { return }
        editors.append(ExternalEditor(appURL: url))
    }
}

private struct EditorRow: View {
    @Binding var editor: ExternalEditor
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: editor.icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                TextField("Name", text: $editor.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                if !editor.isInstalled {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove from Edit In")
            }
            HStack(spacing: 12) {
                Picker("File", selection: $editor.format) {
                    ForEach(ExternalEditor.FileFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Color", selection: $editor.colorSpace) {
                    ForEach(ExportColorSpace.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            Toggle("Include develop adjustments", isOn: $editor.applyDevelop)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AI

/// Where ComfyUI runs and which models the AI recipes use.
struct AISettingsTab: View {
    @AppStorage("ai.server") private var server = AISettings.defaultServer.absoluteString
    @AppStorage("ai.editModel") private var editModel = ""
    @AppStorage("ai.upscaleModel") private var upscaleModel = ""
    @AppStorage("ai.generationSize") private var generationSize = 1024
    @State private var status: String?
    @State private var connected = false
    @State private var editModels: [String] = []
    @State private var upscalers: [String] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    HStack {
                        TextField("Server", text: $server, prompt: Text(AISettings.defaultServer.absoluteString))
                            .labelsHidden()
                            .onSubmit { connect() }
                        Button("Connect") { connect() }
                    }
                }
                if let status {
                    Label(status, systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(connected ? .green : .orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("ComfyUI")
            } footer: {
                Text("Atelier sends photos to a ComfyUI server you run, on this Mac or another one, and never bundles models. The ComfyUI desktop app listens on http://127.0.0.1:8000; ComfyUI started from Terminal uses port 8188.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                modelPicker("Edit model", selection: $editModel, choices: editModels)
                Picker("Generation size", selection: $generationSize) {
                    Text("768 px (faster)").tag(768)
                    Text("1024 px").tag(1024)
                    Text("1536 px (slower)").tag(1536)
                }
                modelPicker("Upscale model (4×)", selection: $upscaleModel, choices: upscalers)
            } header: {
                Text("Models")
            } footer: {
                Text("Remove Object and Replace Background use Qwen-Image-Edit-2511 (Apache 2.0) with its 4-step Lightning LoRA; Upscale uses a 4× upscale model. For website and shop images, use only models licensed Apache 2.0 or MIT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Workflows") {
                    Button("Show Workflows Folder") {
                        try? AIRecipe.installWorkflowTemplates()
                        NSWorkspace.shared.activateFileViewerSelecting([AIRecipe.workflowsFolder])
                    }
                }
            } footer: {
                Text("To use your own ComfyUI workflow, save it in API format as remove-object.json, replace-background.json or upscale.json in this folder. Title its nodes Atelier Image, Atelier Mask, Atelier Prompt, Atelier Sampler and Atelier Output, as in the .example.json files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { connect() }
    }

    @ViewBuilder private func modelPicker(_ title: String, selection: Binding<String>, choices: [String]) -> some View {
        if choices.isEmpty {
            TextField(title, text: selection, prompt: Text("Workflow default"))
        } else {
            Picker(title, selection: selection) {
                Text("Workflow default").tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
                if !selection.wrappedValue.isEmpty, !choices.contains(selection.wrappedValue) {
                    Text(selection.wrappedValue + " (not on server)").tag(selection.wrappedValue)
                }
            }
        }
    }

    private func connect() {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            status = "Enter an address like http://127.0.0.1:8188"
            connected = false
            return
        }
        status = "Connecting…"
        Task {
            let client = ComfyClient(baseURL: url)
            do {
                let version = try await client.ping()
                editModels = (try? await client.options(node: "UnetLoaderGGUF", input: "unet_name")) ?? []
                upscalers = (try? await client.options(node: "UpscaleModelLoader", input: "model_name")) ?? []
                connected = true
                status = "Connected" + (version == "connected" ? "" : " to ComfyUI \(version)")
                    + " · \(editModels.count) edit models, \(upscalers.count) upscale models"
            } catch {
                connected = false
                status = error.localizedDescription
            }
        }
    }
}

// MARK: - Metadata

private struct MetadataSettings: View {
    @AppStorage("xmp.autoWrite") private var autoWrite = false

    var body: some View {
        Form {
            Section {
                Toggle("Automatically write changes into XMP sidecars", isOn: $autoWrite)
            } footer: {
                Text("When on, ratings, flags, labels, keywords, titles and captions are written to .xmp files next to the originals as you change them, so Lightroom, Bridge and Capture One see them. When off, use Library > Write XMP for Selection (⌘S).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

private struct KeyboardSettings: View {
    @State private var recording: KeyAction?
    @State private var monitor: Any?
    /// Bumped after every change so rows re-read their keys.
    @State private var revision = 0

    private var sections: [(String, [KeyAction])] {
        var result: [(String, [KeyAction])] = []
        for action in KeyAction.allCases {
            if result.last?.0 == action.section {
                result[result.count - 1].1.append(action)
            } else {
                result.append((action.section, [action]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { action in
                            LabeledContent(action.title) {
                                HStack(spacing: 6) {
                                    Button {
                                        startRecording(action)
                                    } label: {
                                        Text(recording == action ? "Press a key…" : KeyBindings.display(KeyBindings.key(for: action)))
                                            .monospaced()
                                            .frame(minWidth: 90)
                                    }
                                    .help("Click, then press the new key. Esc cancels, Delete removes it.")
                                    if KeyBindings.key(for: action) != action.defaultKey {
                                        Button {
                                            KeyBindings.set(action.defaultKey, for: action)
                                            revision += 1
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Back to \(KeyBindings.display(action.defaultKey))")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .id(revision)
            HStack {
                Text("Single-key commands, as in Lightroom. Menu shortcuts like ⌘E are listed in Help > Keyboard Shortcuts (⌘/).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") {
                    KeyBindings.resetAll()
                    revision += 1
                }
            }
            .padding(12)
        }
        .frame(height: 520)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording(_ action: KeyAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard let action = recording else { return event }
                switch event.keyCode {
                case 53:  // Escape cancels
                    break
                case 51, 117:  // Delete removes the key
                    KeyBindings.set("", for: action)
                default:
                    guard KeyBindings.isAssignable(event), let key = event.charactersIgnoringModifiers?.lowercased() else {
                        NSSound.beep()
                        return nil
                    }
                    KeyBindings.set(key, for: action)
                }
                stopRecording()
                revision += 1
                return nil
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - Shortcut cheat sheet

/// Help > Keyboard Shortcuts (⌘/): every shortcut on one page, like Lightroom's.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let menuShortcuts: [(String, [(String, String)])] = [
        ("Library", [("⇧⌘I", "Import photos"), ("⇧⌘E", "Export"), ("⌘S", "Write XMP for selection"),
                     ("⌥⌘S", "Write all unsaved XMP"), ("⌘R", "Refresh volumes"),
                     ("Delete", "Remove photo (or delete from disk)")]),
        ("Views", [("⌘G", "Grid"), ("⌘E", "Loupe"), ("⌘D", "Develop"), ("← →", "Previous or next photo"),
                   ("Return", "Open or close loupe"), ("Esc", "Back to grid")]),
        ("Zoom", [("⌘=", "Zoom in"), ("⌘-", "Zoom out"), ("⌘0", "Zoom to fit"), ("⌥⌘1", "Zoom to 100%"),
                  ("⌥ scroll / pinch", "Zoom freely"), ("Drag", "Move around when zoomed")]),
        ("Develop", [("⇧⌘C", "Copy settings"), ("⇧⌘V", "Paste settings"), ("⇧⌘R", "Reset all settings"),
                     ("⌘Z", "Undo"), ("⇧⌘Z", "Redo"), ("⌘[", "Rotate left"), ("⌘]", "Rotate right"),
                     ("Double-click name", "Reset a slider")]),
        ("Masking", [("⇧W", "Open or close Masking"), ("⇧M", "Radial Gradient"), ("[ ]", "Brush size"),
                     ("⇧[ ⇧]", "Brush feather"), ("⌥ drag", "Erase while brushing"), ("Delete", "Delete the selected part"),
                     ("Esc", "Cancel the tool, or close Masking")]),
        ("Transform", [("⇧T", "Guided Upright: draw guides"), ("Delete", "Delete the selected guide"),
                       ("Esc", "Close Guided Upright")]),
        ("App", [("⌘,", "Settings"), ("⌘/", "This list")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                SettingsLink { Text("Change Keys…") }
            }
            .padding(20)
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(singleKeySections, id: \.0) { section in
                            ShortcutGroup(title: section.0, rows: section.1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(menuShortcuts, id: \.0) { section in
                            ShortcutGroup(title: section.0, rows: section.1)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 700, height: 560)
    }

    private var singleKeySections: [(String, [(String, String)])] {
        var result: [(String, [(String, String)])] = []
        for action in KeyAction.allCases {
            let row = (KeyBindings.display(KeyBindings.key(for: action)), action.title)
            if result.last?.0 == action.section {
                result[result.count - 1].1.append(row)
            } else {
                result.append((action.section, [row]))
            }
        }
        return result
    }
}

private struct ShortcutGroup: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .monospaced()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 70, alignment: .leading)
                    Text(row.1).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func chooseFolder(message: String, start: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = message
    panel.directoryURL = URL(fileURLWithPath: start)
    return panel.runModal() == .OK ? panel.url?.path : nil
}
