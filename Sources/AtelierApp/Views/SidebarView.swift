import AtelierCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var askingForName = false
    @State private var newName = ""
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var deleting: RenameTarget?
    @State private var makingPrivate: RenameTarget?

    enum RenameTarget: Equatable {
        case importGroup(Int64)
        case collection(Int64)
    }

    var body: some View {
        privateDialog(dialogs(List(selection: $model.sidebarSelection) {
            librarySection
            importsSection
            volumesSection
            collectionsSection
        }
        .listStyle(.sidebar)))
    }

    // Split up so the compiler can type-check each part in reasonable time.

    @ViewBuilder private var librarySection: some View {
        Section {
            Label {
                CountedName(name: "All Photographs", count: model.sidebar.totalCount)
            } icon: {
                Image(systemName: "photo.stack")
            }
            .tag(SidebarItem.all)
        } header: {
            HStack {
                Text("Library")
                Spacer()
                if model.filter.showsPrivate {
                    Button {
                        model.privatePhotos.hide()
                    } label: {
                        Label("Hide Private", systemImage: "lock.open.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Private photos are shown. Click to hide them again (View > Hide Private Photos).")
                }
            }
        }
    }

    @ViewBuilder private var importsSection: some View {
        if !model.sidebar.imports.isEmpty {
            Section("Imports") {
                ForEach(model.sidebar.imports) { entry in
                    importRow(entry)
                }
            }
        }
    }

    private func importRow(_ entry: ImportGroupSummary) -> some View {
        Label {
            CountedName(name: entry.name, count: entry.photoCount, isPrivate: entry.isPrivate)
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
            if entry.isPrivate {
                Button("Make Not Private") { model.setPrivate(false, importGroup: entry.id) }
            } else {
                Button("Make Private…") { makingPrivate = .importGroup(entry.id) }
            }
            Divider()
            Button("Delete Import…", role: .destructive) {
                model.beginDeleteImport(entry.id)
            }
        }
    }

    @ViewBuilder private var volumesSection: some View {
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
    }

    @ViewBuilder private var collectionsSection: some View {
        Section {
            ForEach(model.sidebar.collections) { collection in
                if let id = collection.id {
                    collectionRow(collection, id: id)
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

    private func collectionRow(_ collection: PhotoCollection, id: Int64) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(collection.name).lineLimit(1)
                if collection.isPrivate { PrivateMark() }
            }
        } icon: {
            Image(systemName: "rectangle.stack")
        }
        .help(collection.name)
        .tag(SidebarItem.collection(id))
        .contextMenu {
            Button("Rename…") { startRename(.collection(id), current: collection.name) }
            Divider()
            if collection.isPrivate {
                Button("Make Not Private") { model.setPrivate(false, collection: id) }
            } else if !collection.isSet {
                Button("Make Private…") { makingPrivate = .collection(id) }
            }
            Divider()
            Button("Delete Collection…", role: .destructive) { deleting = .collection(id) }
        }
    }

    /// The New Collection, Rename, Delete and Make Private dialogs.
    private func dialogs(_ content: some View) -> some View {
        content
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

    private func privateDialog(_ content: some View) -> some View {
        content
            .confirmationDialog(privateTitle, isPresented: Binding(get: { makingPrivate != nil },
                                                                   set: { if !$0 { makingPrivate = nil } })) {
                Button("Make Private") {
                    switch makingPrivate {
                    case .importGroup(let id): model.setPrivate(true, importGroup: id)
                    case .collection(let id): model.setPrivate(true, collection: id)
                    case nil: break
                    }
                    makingPrivate = nil
                }
                Button("Cancel", role: .cancel) { makingPrivate = nil }
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

    private var privateTitle: String {
        switch makingPrivate {
        case .importGroup(let id):
            return "Make \u{201C}\(model.sidebar.imports.first { $0.id == id }?.name ?? "")\u{201D} private?"
        case .collection(let id):
            return "Make \u{201C}\(model.sidebar.collections.first { $0.id == id }?.name ?? "")\u{201D} private?"
        case nil:
            return "Make private?"
        }
    }

    private func startRename(_ target: RenameTarget, current: String) {
        renameText = current
        renaming = target
    }
}

/// The lock after a private import's or collection's name.
private struct PrivateMark: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help("Private: hidden until View > Show Private Photos…")
    }
}

private struct CountedName: View {
    let name: String
    let count: Int
    var isPrivate = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            if isPrivate { PrivateMark() }
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
