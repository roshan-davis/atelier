import AtelierCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var askingForName = false
    @State private var newName = ""

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label {
                    HStack {
                        Text("All Photographs")
                        Spacer()
                        Text("\(model.sidebar.totalCount)").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "photo.stack")
                }
                .tag(SidebarItem.all)
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
                                Button("Delete Collection", role: .destructive) { model.deleteCollection(id) }
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
