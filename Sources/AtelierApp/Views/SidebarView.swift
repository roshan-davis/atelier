import AtelierCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var askingForName = false
    @State private var newName = ""
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var deleting: RenameTarget?

    enum RenameTarget: Equatable {
        case importGroup(Int64)
        case collection(Int64)
    }

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label {
                    CountedName(name: "All Photographs", count: model.sidebar.totalCount)
                } icon: {
                    Image(systemName: "photo.stack")
                }
                .tag(SidebarItem.all)
            }

            if !model.sidebar.imports.isEmpty {
                Section("Imports") {
                    ForEach(model.sidebar.imports) { entry in
                        Label {
                            CountedName(name: entry.name, count: entry.photoCount)
                        } icon: {
                            Image(systemName: "square.and.arrow.down.on.square")
                        }
                        .help("Imported \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .tag(SidebarItem.importGroup(entry.id))
                        .contextMenu {
                            Button("Rename…") { startRename(.importGroup(entry.id), current: entry.name) }
                            Button("Import More Photos Into This…") {
                                model.sidebarSelection = .importGroup(entry.id)
                                model.beginImport(into: entry.id)
                            }
                            Button("Cull…") { model.beginCull(importGroup: entry.id) }
                            Divider()
                            Button("Delete Import…", role: .destructive) {
                                deleting = .importGroup(entry.id)
                            }
                        }
                    }
                }
            }

            Section("Volumes") {
                ForEach(model.sidebar.volumes) { volume in
                    if let volumeID = volume.id {
                        DisclosureGroup {
                            ForEach(model.sidebar.folders.filter { $0.volumeId == volumeID }) { folder in
                                if let folderID = folder.id {
                                    Label(folder.displayName, systemImage: "folder")
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                        .help(folder.displayName)
                                        .tag(SidebarItem.folder(folderID))
                                }
                            }
                        } label: {
                            VolumeLabel(volume: volume)
                                .tag(SidebarItem.volume(volumeID))
                        }
                    }
                }
            }

            Section {
                ForEach(model.sidebar.collections) { collection in
                    if let id = collection.id {
                        Label(collection.name, systemImage: "rectangle.stack")
                            .tag(SidebarItem.collection(id))
                            .contextMenu {
                                Button("Rename…") { startRename(.collection(id), current: collection.name) }
                                Divider()
                                Button("Delete Collection…", role: .destructive) { deleting = .collection(id) }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button {
                        newName = ""
                        askingForName = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New collection")
                }
            }
        }
        .listStyle(.sidebar)
        .alert("New Collection", isPresented: $askingForName) {
            TextField("Name", text: $newName)
            Button("Create") { model.createCollection(named: newName, addingSelection: false) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                switch renaming {
                case .importGroup(let id): model.renameImportGroup(id, to: renameText)
                case .collection(let id): model.renameCollection(id, to: renameText)
                case nil: break
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil },
                                                              set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                switch deleting {
                case .importGroup(let id): model.deleteImportGroup(id)
                case .collection(let id): model.deleteCollection(id)
                case nil: break
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The photos stay in your catalog and on disk. Only this list is removed.")
        }
    }

    private var deleteTitle: String {
        switch deleting {
        case .importGroup(let id):
            return "Delete the import \"\(model.sidebar.imports.first { $0.id == id }?.name ?? "")\"?"
        case .collection(let id):
            return "Delete the collection \"\(model.sidebar.collections.first { $0.id == id }?.name ?? "")\"?"
        case nil:
            return "Delete?"
        }
    }

    private func startRename(_ target: RenameTarget, current: String) {
        renameText = current
        renaming = target
    }
}

private struct CountedName: View {
    let name: String
    let count: Int

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}

private struct VolumeLabel: View {
    let volume: Volume

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(volume.name)
                Circle()
                    .fill(volume.isOnline ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .help(volume.isOnline ? "Online" : "Offline: browsing previews only")
            }
        } icon: {
            Image(systemName: volume.kind == .nas ? "server.rack" : "externaldrive")
        }
    }
}
