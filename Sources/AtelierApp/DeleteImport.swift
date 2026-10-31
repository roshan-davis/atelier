import AppKit
import AtelierCore

/// The Delete Import dialog's subject, fixed when it opens.
struct ImportDeletion: Identifiable {
    /// The import entry.
    let id: Int64
    let name: String
    /// Photos as the sidebar counts them (a RAW+JPEG pair once).
    let photoCount: Int
    /// Every file behind the entry's photos, for the optional Delete Files.
    let plan: RemovalPlan
}

extension LibraryModel {
    /// Right-click an import > Delete Import…: removes the entry and, only when asked, its photos
    /// and their files.
    func beginDeleteImport(_ id: Int64) {
        guard let entry = sidebar.imports.first(where: { $0.id == id }) else { return }
        do {
            let ids = try catalog.assetRows(filter: LibraryFilter(scope: .importGroup(id), groupsRawPairs: false, privacy: filter.privacy)).map(\.id)
            deletingImport = ImportDeletion(id: id, name: entry.name, photoCount: entry.photoCount,
                                            plan: try catalog.removalPlan(for: ids))
        } catch {
            status = error.localizedDescription
        }
    }

    /// Deletes the entry; with `files`, first moves its photos' files to the Trash and takes the
    /// photos out of the catalog, as Remove Photo > Delete from Disk does.
    func deleteImport(_ deletion: ImportDeletion, files: Bool) {
        deletingImport = nil
        if files {
            let removal = PhotoRemoval(photoCount: deletion.photoCount, plan: deletion.plan)
            removePhotos(removal, types: Set(deletion.plan.fileTypes), fromDisk: true)
            if sidebarSelection == .importGroup(deletion.id) { sidebarSelection = .all }
            do {
                try catalog.deleteImportGroup(deletion.id)
            } catch {
                status = error.localizedDescription
            }
        } else {
            deleteImportGroup(deletion.id)
        }
    }
}
