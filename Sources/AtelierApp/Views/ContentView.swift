import AppKit
import AtelierCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showInspector = true
    @AppStorage("panel.width") private var panelWidth = 320.0
    @AppStorage(Theme.defaultsKey) private var theme: Theme = .system
    @AppStorage(Filmstrip.visibleKey) private var filmstripVisible = true
    /// Docked beside a chat app (AT-050h): the width the panels are laid out for, from `AgentDock`.
    @State private var dockWidth: Double?
    @State private var columns: NavigationSplitViewVisibility = .automatic
    /// The person's own sidebar choice, put back when docking no longer hides it.
    @State private var columnsBeforeDock: NavigationSplitViewVisibility = .automatic
    @State private var sidebarHiddenByDock = false
    @State private var sidebarWidth = 240.0

    /// Both panels, unless the window is docked (or still narrow after) and they don't fit:
    /// the left panel collapses first, then the right one, never the photo.
    private var dockLayout: DockLayout {
        guard let dockWidth else { return .full }
        // A sidebar the person hid themselves takes no room.
        let sidebar = columns == .detailOnly && !sidebarHiddenByDock ? 0 : sidebarWidth
        return .fitting(width: dockWidth, sidebar: sidebar, inspector: showInspector ? panelWidth + 1 : 0)
    }

    var body: some View {
        // Like Lightroom Classic, the Filmstrip runs the full width of the window, under
        // both side panels.
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columns) {
                Group {
                    if model.mode == .develop {
                        DevelopSidebar(develop: model.develop)
                            .areaFocusFlash(.leftPanel)
                    } else if model.mode == .hdr {
                        HDRSidebar(hdr: model.hdr)
                            .areaFocusFlash(.leftPanel)
                    } else {
                        SidebarView()
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        if width > 100 { sidebarWidth = width }
                    }
                })
            } detail: {
                // The right panel sits beside the content, below the toolbar, like Lightroom's,
                // rather than as a full-height inspector the toolbar floats over.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        FilterBar()
                        Divider()
                        ZStack {
                            switch model.mode {
                            case .grid:
                                GridView(model: model, background: theme.gridBackground)
                            case .loupe:
                                LoupeView(zoom: model.zoomState)
                            case .develop:
                                DevelopImageView(develop: model.develop)
                            case .hdr:
                                HDRImageView(hdr: model.hdr)
                            }
                            if model.rows.isEmpty {
                                EmptyLibraryView()
                            }
                        }
                        // The focused photo's sticky notes (View > Show Notes, AT-058). An overlay,
                        // so it never changes the photo's zoom and pan or the grid's scroll.
                        .overlay {
                            NotesOverlay(catalog: model.catalog,
                                         assetID: model.mode == .hdr || model.rows.isEmpty ? nil : model.focusedID,
                                         subtitle: model.notesSubtitle, addTargets: model.noteTargets,
                                         request: $model.noteRequest)
                        }
                        // A chat app's change, with Undo (Settings > Agents, AT-050c).
                        .overlay(alignment: .bottom) { AgentNoticeView(agents: model.agents) }
                        Divider()
                        StatusBar()
                    }
                    // Let the photo column shrink to whatever is left and never draw past it.
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(Color(nsColor: theme.chrome))
                    .clipped()
                    if showInspector && dockLayout.showsInspector {
                        PanelResizeHandle(width: $panelWidth, range: 280...560, panel: .trailing)
                        InspectorView()
                            .frame(width: panelWidth)
                            .clipped()
                            .areaFocusFlash(.rightPanel)
                            .layoutPriority(1)
                            .background(Color(nsColor: theme.panel))
                    }
                }
            }
            FilmstripView()
                .areaFocusFlash(.photo, enabled: model.usesPanelKeys && filmstripVisible)
        }
        // Dropping folders or photos anywhere on the window starts an import with them.
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !model.showingImportSheet else { return false }
            model.beginImport(sources: urls)
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.beginImport() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import photos (⇧⌘I)")

                Button { model.beginExport() } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the selected photos with their edits (⇧⌘E)")

                Picker("View", selection: $model.mode) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(ViewMode.grid)
                    Label("Loupe", systemImage: "photo").tag(ViewMode.loupe)
                    Label("Develop", systemImage: "slider.horizontal.3").tag(ViewMode.develop)
                }
                .pickerStyle(.segmented)
                // HDR isn't a button here: it's an occasional tool, opened from Photo > HDR… (⌃H)
                // or a photo's right-click menu (Rosh, Nov 12, 2026). While HDR is open no
                // button is selected, and clicking one leaves HDR.
                .help("Grid (G), loupe (E) or develop (D)")

                CollectionMenu()

                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $model.showingImportSheet) {
            ImportSheet(model: model)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $model.showingExportSheet) {
            ExportSheet()
        }
        .sheet(item: $model.matchLook) { match in
            MatchLookSheet(match: match)
                .environmentObject(model)
        }
        .sheet(item: $model.removal) { removal in
            RemovePhotosSheet(removal: removal)
                .environmentObject(model)
        }
        .sheet(item: $model.deletingImport) { deletion in
            DeleteImportSheet(deletion: deletion)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingShortcuts) {
            ShortcutsSheet()
        }
        .sheet(item: $model.cullSession) { session in
            CullView(cull: session)
                .environment(\.theme, theme)
        }
        .background(WindowAccessor { model.mainWindow = $0 })
        .background(DockWidthReader(dock: model.agents.dock, width: $dockWidth))
        .onChange(of: dockLayout.showsSidebar) { _, shows in
            if shows {
                if sidebarHiddenByDock { columns = columnsBeforeDock }
                sidebarHiddenByDock = false
            } else if columns != .detailOnly {
                columnsBeforeDock = columns
                columns = .detailOnly
                sidebarHiddenByDock = true
            }
        }
        .onChange(of: dockWidth) { _, _ in
            if dockLayout == .full { model.agents.dock.panelsFit() }
        }
        .environment(\.theme, theme)
        .environment(\.developFrameHUD, model.mode == .develop ? model.develop.frameHUD : nil)
        .onAppear { theme.apply() }
        .onChange(of: theme) { _, newTheme in newTheme.apply() }
    }
}

/// Copies the docked width (`AgentDock.width`) into ContentView's layout.
private struct DockWidthReader: View {
    @ObservedObject var dock: AgentDock
    @Binding var width: Double?

    var body: some View {
        Color.clear.onChange(of: dock.width, initial: true) { _, newWidth in width = newWidth }
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(model.sidebar.totalCount == 0 ? "No photos yet" : "No photos match")
                .font(.title3)
            if model.sidebar.totalCount == 0 {
                Text("Drag folders or photos onto this window, or")
                    .foregroundStyle(.secondary)
                Button("Import Photos…") { model.beginImport() }
                    .controlSize(.large)
            }
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showingFailures = false

    var body: some View {
        HStack {
            Text("\(model.rows.count) photos")
            if model.selection.count > 1 {
                Text("· \(model.selection.count) selected")
            }
            Spacer()
            if let progress = model.importProgress {
                ProgressItem(progress: progress) { model.cancelImport() }
            }
            if let progress = model.exportProgress {
                ProgressItem(progress: progress) { model.cancelExport() }
            }
            if let progress = model.matchProgress {
                ProgressItem(progress: progress) { model.cancelMatchEach() }
            }
            if let progress = model.agentProgress {
                ProgressItem(progress: progress) { model.agentJob?.cancel() }
            }
            if model.importProgress == nil, model.exportProgress == nil, model.matchProgress == nil,
               model.agentProgress == nil,
               let status = model.status {
                Text(status).lineLimit(1)
                if !model.problems.isEmpty {
                    Button("Show Problems") { showingFailures = true }
                        .controlSize(.small)
                        .popover(isPresented: $showingFailures) {
                            ProblemsView(title: model.problemsTitle, problems: model.problems)
                        }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

private struct CollectionMenu: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var askingForName = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Button("New Collection with Selection…") {
                newName = ""
                askingForName = true
            }
            if !model.sidebar.collections.isEmpty {
                Divider()
                ForEach(model.sidebar.collections) { collection in
                    Button("Add to \(collection.name)") {
                        if let id = collection.id { model.addSelection(toCollection: id) }
                    }
                }
            }
            if !model.sidebar.imports.isEmpty {
                Divider()
                Menu("Add to Import") {
                    ForEach(model.sidebar.imports) { entry in
                        Button(entry.name) { model.addSelection(toImportGroup: entry.id) }
                    }
                }
            }
            if case .collection = model.sidebarSelection {
                Divider()
                Button("Remove from This Collection") { model.removeSelectionFromCurrentCollection() }
            }
            if case .importGroup = model.sidebarSelection {
                Divider()
                Button("Remove from This Import") { model.removeSelectionFromCurrentImport() }
            }
        } label: {
            Label("Organize", systemImage: "rectangle.stack.badge.plus")
        }
        .help("Add the selection to a collection or import, or remove it from the current one")
        .alert("New Collection", isPresented: $askingForName) {
            TextField("Name", text: $newName)
            Button("Create") { model.createCollection(named: newName, addingSelection: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ProgressItem: View {
    let progress: ImportStatus
    let cancel: () -> Void

    var body: some View {
        Text(progress.phase).lineLimit(1).monospacedDigit()
        Group {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .frame(width: 140)
        Button("Cancel", action: cancel)
            .controlSize(.small)
    }
}

private struct ProblemsView: View {
    let title: String
    let problems: [Problem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            List(problems, id: \.self) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name)
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 380, height: 220)
        }
        .padding(14)
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}
