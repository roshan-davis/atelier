import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// Atelier > Settings… (⌘,): a sidebar of panes on the left, the chosen pane on the right, as in
/// macOS System Settings. Values live in user defaults under the same keys the dialogs use,
/// so a default set here is what the Import and Export dialogs start with.
struct SettingsView: View {
    static let size = CGSize(width: 900, height: 660)
    static let sidebarWidth: CGFloat = 220

    /// The pane last shown, so Settings reopens where it was left.
    @AppStorage(SettingsPane.defaultsKey) private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane)
                .frame(width: Self.sidebarWidth)
            Divider()
            SettingsPaneView(pane: pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .navigationTitle(pane.title)
    }
}

/// The panes of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, keyboard, imports = "import", develop, export, metadata, editIn, ai

    static let defaultsKey = "settings.pane"

    var id: String { rawValue }

    /// Sidebar groups: the app itself, the photo workflow, then other apps and AI.
    static let groups: [(title: String, panes: [SettingsPane])] = [
        ("Atelier", [.general, .appearance, .keyboard]),
        ("Photos", [.imports, .develop, .export, .metadata]),
        ("Editors & AI", [.editIn, .ai]),
    ]

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .keyboard: return "Keyboard"
        case .imports: return "Import"
        case .develop: return "Develop"
        case .export: return "Export"
        case .metadata: return "Metadata"
        case .editIn: return "Edit In"
        case .ai: return "AI"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .keyboard: return "keyboard"
        case .imports: return "square.and.arrow.down"
        case .develop: return "slider.horizontal.3"
        case .export: return "square.and.arrow.up"
        case .metadata: return "tag"
        case .editIn: return "paintbrush"
        case .ai: return "wand.and.stars"
        }
    }

    /// The pane's icon color, like System Settings' colored tiles but softer (`SettingsPalette`).
    var tint: Color {
        switch self {
        case .general: return SettingsPalette.slate
        case .appearance: return SettingsPalette.lavender
        case .keyboard: return SettingsPalette.periwinkle
        case .imports: return SettingsPalette.sky
        case .develop: return SettingsPalette.peach
        case .export: return SettingsPalette.sage
        case .metadata: return SettingsPalette.seafoam
        case .editIn: return SettingsPalette.rose
        case .ai: return SettingsPalette.mist
        }
    }

    /// One line under the pane's title saying what it holds.
    var summary: String {
        switch self {
        case .general: return "Catalog, backups, private photos, splash screen and previews."
        case .appearance: return "The theme for every window, Settings included."
        case .keyboard: return "The key for each command. Click a key, then press a new one."
        case .imports: return "What the Import dialog starts with, and RAW+JPEG pairs."
        case .develop: return "Zoom and panel behavior in Develop."
        case .export: return "Where exports go. Formats and presets are in File > Export…"
        case .metadata: return "Writing ratings, keywords and edits to XMP sidecars."
        case .editIn: return "The apps under Photo > Edit In, and what each is sent."
        case .ai: return "The ComfyUI server, AI models and masking models."
        }
    }
}

/// The Settings sidebar: grouped panes with their icons, like System Settings.
/// Drawn rows rather than a `List` with selection, whose clicks never changed the pane in the
/// Settings window (Rosh, Nov 12, 2026). Click a row, or ↑ ↓ (Home, End) once the sidebar has focus;
/// it takes focus when Settings opens, on a click, or with Tab.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    @FocusState private var focused: Bool

    private static let order = SettingsPane.groups.flatMap { $0.panes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.groups, id: \.title) { group in
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 3)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.panes) { pane in
                        SettingsSidebarRow(pane: pane, isSelected: pane == selection, sidebarFocused: focused) {
                            selection = pane
                            focused = true
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .background(Color.primary.opacity(0.03))
        // .edit: the sidebar takes the keys whether or not Full Keyboard Access is on.
        .focusable(interactions: .edit)
        .focused($focused)
        .defaultFocus($focused, true)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.home) { jump(to: Self.order.first) }
        .onKeyPress(.end) { jump(to: Self.order.last) }
        .onAppear { focused = true }
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard let index = Self.order.firstIndex(of: selection) else { return .ignored }
        let next = min(max(index + step, 0), Self.order.count - 1)
        selection = Self.order[next]
        return .handled
    }

    private func jump(to pane: SettingsPane?) -> KeyPress.Result {
        guard let pane else { return .ignored }
        selection = pane
        return .handled
    }
}

/// One sidebar row: accent fill when chosen and the sidebar has focus, gray when it doesn't
/// (as in Finder and System Settings), a faint tint on hover.
private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let sidebarFocused: Bool
    let select: () -> Void
    @State private var hovering = false

    private var onAccent: Bool { isSelected && sidebarFocused }

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(pane: pane, size: 24)
            // A step above the panes' 13 pt text, as in System Settings.
            Text(pane.title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(onAccent ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    private var fill: Color {
        if isSelected { return sidebarFocused ? Color.accentColor : Color.primary.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.06) : Color.clear
    }
}

/// The right side of Settings: the pane's title and summary, then its settings.
private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(pane: pane)
            content
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // A fresh view per pane, so each opens scrolled to the top.
        .id(pane)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .keyboard: KeyboardSettings()
        case .imports: ImportSettings()
        case .develop: DevelopSettingsTab()
        case .export: ExportSettingsTab()
        case .metadata: MetadataSettings()
        case .editIn: EditInSettings()
        case .ai: AISettingsTab()
        }
    }
}

private struct SettingsPaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(pane: pane, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                Text(pane.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(Theme.defaultsKey) private var theme: Theme = .system

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        Form {
            SettingsSection("Theme") {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Theme.allCases) { option in
                        ThemeCard(theme: option, isSelected: option == theme) { theme = option }
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text(theme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
    @AppStorage(DeleteFeedback.enabledKey) private var deleteEffects = true
    @AppStorage(PrivatePhotos.hideAfterKey) private var hidePrivateAfter = PrivatePhotos.defaultHideAfter
    @State private var previewsSize: String?
    @State private var backupMessage: String?

    var body: some View {
        Form {
            SettingsSection("Catalog") {
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

            SettingsSection("Backups") {
                Stepper("Keep the last \(backupsToKeep) backup\(backupsToKeep == 1 ? "" : "s")",
                        value: $backupsToKeep, in: 1...50)
                HStack {
                    Button("Back Up Now") { backUp() }
                    if let backupMessage {
                        Text(backupMessage).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("The catalog is backed up when Atelier quits. Backups are kept inside the catalog package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Private Photos") {
                Picker("Hide again after", selection: $hidePrivateAfter) {
                    ForEach(PrivatePhotos.hideAfterChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes without using Atelier").tag(minutes)
                    }
                }
            } footer: {
                Text("Private photos also hide when the Mac sleeps or locks, and every time Atelier opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Feedback") {
                Toggle("Play a sound and animation when deleting", isOn: $deleteEffects)
            } footer: {
                Text("Moving photos to the Trash plays Finder’s Trash sound; removing a mask, preset, guide or catalog entry plays the Dock’s poof. Both show a puff of smoke at the pointer. The sound follows System Settings > Sound > Play user interface sound effects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Splash Screen") {
                Toggle("Show splash screen at launch", isOn: $showSplash)
                HStack {
                    Button("Show Splash Folder") {
                        SplashController.installFolder()
                        NSWorkspace.shared.activateFileViewerSelecting([Splash.folder])
                    }
                    Button("Preview Splash Screen") { SplashController.shared.preview() }
                }
            } footer: {
                Text("Each launch shows the next image in the Splash folder, in name order. Add JPEG, PNG or HEIC images, ideally 1600 × 1000 px or larger. Each fills the splash, cropped around its subject.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Previews") {
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
            SettingsSection("Default for new imports") {
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
            } footer: {
                Text("The Import dialog starts with these choices. Copies go to YYYY/YYYY-MM-DD Name/ and are checked against the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("RAW+JPEG") {
                Toggle("Show RAW+JPEG pairs as one photo", isOn: $groupPairs)
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
            SettingsSection("Zoom") {
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
            SettingsSection("Panels") {
                Toggle("Solo mode: opening a panel closes the others", isOn: $soloMode)
                Toggle("Show how much is clipped next to the histogram's triangles", isOn: $showClipping)
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
            SettingsSection("Defaults") {
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
            } footer: {
                Text("Format, size, color, metadata and watermark are chosen in File > Export…, where you can also save them as presets. The last choices are remembered.")
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
            // One section per app, its settings in the same label-and-control rows as every pane.
            ForEach($editors) { $editor in
                SettingsSection(editor.name.isEmpty ? "Untitled" : editor.name, id: "editIn." + editor.id) {
                    EditorRows(editor: $editor)
                } trailing: {
                    Button {
                        editors.removeAll { $0.id == editor.id }
                        DeleteFeedback.play(.remove)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(SidebarIconButtonStyle())
                    .help("Remove \(editor.name) from Edit In")
                }
            }
            SettingsSection("Add Editors") {
                if editors.isEmpty {
                    Text("No photo editors found. Click Add App… to pick one.")
                        .foregroundStyle(.secondary)
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

/// An Edit In app's settings as standard Form rows, so labels and controls line up with
/// every other pane instead of sharing one cramped row (Rosh, Nov 12, 2026: the old row was cut off).
private struct EditorRows: View {
    @Binding var editor: ExternalEditor

    var body: some View {
        LabeledContent("App") {
            HStack(spacing: 8) {
                Image(nsImage: editor.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(editor.appURL.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(editor.appPath)
                if !editor.isInstalled {
                    Text("Not installed").foregroundStyle(.orange)
                }
            }
        }
        TextField("Name in the menu", text: $editor.name)
        Picker("File", selection: $editor.format) {
            ForEach(ExternalEditor.FileFormat.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Color space", selection: $editor.colorSpace) {
            ForEach(ExportColorSpace.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Include develop adjustments", isOn: $editor.applyDevelop)
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
            SettingsSection("ComfyUI") {
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
            } footer: {
                Text("Atelier sends photos to a ComfyUI server you run, on this Mac or another one, and never bundles models. The ComfyUI desktop app listens on http://127.0.0.1:8000; ComfyUI started from Terminal uses port 8188.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Models") {
                modelPicker("Edit model", selection: $editModel, choices: editModels)
                Picker("Generation size", selection: $generationSize) {
                    Text("768 px (faster)").tag(768)
                    Text("1024 px").tag(1024)
                    Text("1536 px (slower)").tag(1536)
                }
                modelPicker("Upscale model (4×)", selection: $upscaleModel, choices: upscalers)
            } footer: {
                Text("Remove Object and Replace Background use Qwen-Image-Edit-2511 (Apache 2.0) with its 4-step Lightning LoRA; Upscale uses a 4× upscale model. For website and shop images, use only models licensed Apache 2.0 or MIT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MaskingModelsSection()

            SettingsSection("Workflows") {
                LabeledContent("Folder") {
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

/// Settings > AI > Masking Models: the built-in people model and the two optional Fine Edges models.
private struct MaskingModelsSection: View {
    @ObservedObject private var download = FineEdgesDownload.shared

    var body: some View {
        SettingsSection("Masking Models") {
            LabeledContent("People parts") {
                Text("Built in (MediaPipe, 8 MB)").foregroundStyle(.secondary)
            }
            ForEach(FineEdges.Model.allCases) { model in
                LabeledContent {
                    if download.installed.contains(model) {
                        HStack {
                            Text("Downloaded").foregroundStyle(.secondary)
                            Button("Remove") { download.remove(model) }
                        }
                    } else if download.downloading == model, let progress = download.progress {
                        HStack {
                            ProgressView(value: progress).frame(width: 120)
                            Button("Cancel") { download.cancel() }
                        }
                    } else {
                        Button("Download (\(model.downloadSize))") { download.download(model) }
                            .disabled(download.downloading != nil)
                    }
                } label: {
                    Text("Fine Edges: \(model.name)")
                    Text(model.detail)
                }
            }
            if download.anyInstalled {
                LabeledContent("Fine Edges uses") {
                    HStack {
                        if download.installed.count > 1 {
                            Picker("Fine Edges uses", selection: Binding(get: { download.active ?? download.chosen },
                                                                         set: { download.choose($0) })) {
                                ForEach(FineEdges.Model.allCases) { Text($0.name).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } else if let active = download.active {
                            Text(active.name).foregroundStyle(.secondary)
                        }
                        Button("Show Last Result") {
                            NSWorkspace.shared.activateFileViewerSelecting([FineEdges.diagnosticsFolder])
                        }
                        .help("Opens the folder with what the model saw and found on its last run")
                    }
                }
            }
            if let error = download.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Select People's parts come from Google's MediaPipe model, built into Atelier. Fine Edges (BiRefNet, MIT license) redraws the edges of Select Subject, Select Object and Select People down to strands of hair; turn it on in each selection's settings. Download either model or both: Fast takes a few seconds, Hair Detail about half a minute for finer hair. When both are downloaded, choose which one runs here or in the mask panel. All of them run on this Mac; photos are never sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Metadata

struct MetadataSettings: View {
    @AppStorage("xmp.autoWrite") private var autoWrite = false

    var body: some View {
        Form {
            SettingsSection("XMP Sidecars") {
                Toggle("Automatically write changes into XMP sidecars", isOn: $autoWrite)
            } footer: {
                Text("When on, metadata and current Develop edits, including masks, are written to .xmp files next to the originals as you change them. Other apps can read the metadata; Develop edits are for Atelier recovery. When off, use Library > Write XMP for Selection (⌘S).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut cheat sheet

/// Help > Keyboard Shortcuts (⌘/): every shortcut on one page, like Lightroom's.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

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
        ("Keyboard focus", [("Tab  ⇧Tab", "Next or previous control"),
                            ("← → ↑ ↓", "Move the focused slider (⇧ for bigger steps)"),
                            ("↑ ↓", "Presets: move and preview; ← → close or open a group"),
                            ("Return", "Presets: apply the highlighted one"),
                            ("Esc", "Give the arrows back to the photo")]),
        ("Masking", [("[ ]", "Brush size"),
                     ("⇧[ ⇧]", "Brush feather"), ("⌥ drag", "Erase while brushing"), ("Delete", "Delete the selected part"),
                     ("Esc", "Cancel the tool, or close Masking")]),
        ("Transform", [("Delete", "Delete the selected guide"),
                       ("Esc", "Close Guided Upright")]),
        ("App", [("⌘,", "Settings"), ("⌘/", "This list")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                Button("Change Keys…") {
                    // Open Settings on its Keyboard pane.
                    UserDefaults.standard.set(SettingsPane.keyboard.rawValue, forKey: SettingsPane.defaultsKey)
                    openSettings()
                }
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
