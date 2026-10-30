import AppKit
import AtelierCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showInspector = true
    @AppStorage("panel.width") private var panelWidth = 320.0
    @AppStorage(Theme.defaultsKey) private var theme: Theme = .system

    var body: some View {
        // Like Lightroom Classic, the Filmstrip runs the full width of the window, under
        // both side panels.
        VStack(spacing: 0) {
            NavigationSplitView {
                Group {
                    if model.mode == .develop {
                        DevelopSidebar(develop: model.develop)
                    } else {
                        SidebarView()
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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
                            }
                            if model.rows.isEmpty {
                                EmptyLibraryView()
                            }
                        }
                        Divider()
                        StatusBar()
                    }
                    // Let the photo column shrink to whatever is left and never draw past it.
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(Color(nsColor: theme.chrome))
                    .clipped()
                    if showInspector {
                        PanelResizeHandle(width: $panelWidth)
                        InspectorView()
                            .frame(width: panelWidth)
                            .clipped()
                            .layoutPriority(1)
                            .background(Color(nsColor: theme.panel))
                    }
                }
            }
            FilmstripView()
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
                .help("Grid (G), loupe (E) or develop (D)")

                CollectionMenu()

                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $model.showingImportSheet) {
            ImportSheet()
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
        .environment(\.theme, theme)
        .onAppear { theme.apply() }
        .onChange(of: theme) { _, newTheme in newTheme.apply() }
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
            if model.importProgress == nil, model.exportProgress == nil, model.matchProgress == nil,
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

/// The divider between the photo and the right panel; drag it to resize the panel.
private struct PanelResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? width
                            startWidth = start
                            width = min(560, max(280, start - value.translation.width))
                        }
                        .onEnded { _ in startWidth = nil })
                    .cursor(.columnResize)
            )
            .help("Drag to resize the panel")
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
