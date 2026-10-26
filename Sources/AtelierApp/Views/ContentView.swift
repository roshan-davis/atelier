import AtelierCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                FilterBar()
                Divider()
                ZStack {
                    switch model.mode {
                    case .grid:
                        GridView(model: model)
                    case .loupe:
                        LoupeView()
                    }
                    if model.rows.isEmpty {
                        EmptyLibraryView()
                    }
                }
                Divider()
                StatusBar()
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.beginImport() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import photos (⇧⌘I)")

                Picker("View", selection: $model.mode) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(ViewMode.grid)
                    Label("Loupe", systemImage: "photo").tag(ViewMode.loupe)
                }
                .pickerStyle(.segmented)
                .help("Grid (G) or loupe (E)")

                CollectionMenu()

                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $model.showingImportSheet) {
            ImportSheet()
        }
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
                Button("Import Photos…") { model.beginImport() }
            }
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        HStack {
            Text("\(model.rows.count) photos")
            if model.selection.count > 1 {
                Text("· \(model.selection.count) selected")
            }
            Spacer()
            if let status = model.status {
                Text(status).lineLimit(1)
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
