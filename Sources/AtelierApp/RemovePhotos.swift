import AppKit
import AtelierCore

/// The Remove Photo dialog's subject: the photos picked when it opened, so the menu or
/// selection changing underneath doesn't change what is removed.
struct PhotoRemoval: Identifiable {
    let id = UUID()
    /// Photos as the grid shows them (a RAW+JPEG pair counts once).
    let photoCount: Int
    let plan: RemovalPlan
}

extension LibraryModel {
    /// Photo > Remove Photo… (Delete): asks whether to remove the target photos from the catalog
    /// or also move their files to the Trash. A RAW's paired JPEG is included, with a checkbox
    /// per kind of file.
    func beginRemovePhotos() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        do {
            removal = PhotoRemoval(photoCount: ids.count, plan: try catalog.removalPlan(for: pairTargetIDs))
        } catch {
            status = error.localizedDescription
        }
    }

    /// Runs the dialog's choice for the checked kinds of file. Virtual copies picked themselves
    /// only ever leave the catalog.
    func removePhotos(_ removal: PhotoRemoval, types: Set<RemovalPlan.FileType>, fromDisk: Bool) {
        self.removal = nil
        let files = removal.plan.files(of: types)
        let copies = removal.plan.virtualCopies
        let next = photoAfterRemoving(Set(files.map(\.assetID) + copies))
        develop.flushSave()
        do {
            if fromDisk {
                let result = try catalog.deletePhotos(files, virtualCopies: copies)
                finishRemoving(result.trashed + result.missing, copies: copies, next: next)
                report(result, copies: copies.count)
                if !result.notTrashed.isEmpty {
                    // After the sheet has gone.
                    let failures = result.notTrashed
                    Task { @MainActor in self.offerImmediateDeletion(failures) }
                }
            } else {
                try catalog.removePhotos(files.map(\.assetID) + copies)
                finishRemoving(files, copies: copies, next: next)
                let photos = removal.photoCount
                status = "Removed \(photos) photo\(photos == 1 ? "" : "s") from the catalog. The files are still on disk."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    /// The photo to show once these are gone: the next one in the grid, else the one before.
    private func photoAfterRemoving(_ removed: Set<Int64>) -> Int64? {
        guard let first = rows.firstIndex(where: { removed.contains($0.id) }) else { return focusedID }
        return rows[first...].first { !removed.contains($0.id) }?.id
            ?? rows[..<first].last { !removed.contains($0.id) }?.id
    }

    private func finishRemoving(_ files: [RemovalPlan.File], copies: [Int64], next: Int64?) {
        let removed = files.map(\.assetID) + copies
        for id in removed {
            previews.remove(for: id)
            ThumbnailLoader.shared.invalidate(id)
        }
        guard removed.contains(where: { selection.contains($0) || $0 == focusedID }) else { return }
        selection = next.map { Set([$0]) } ?? []
        focusedID = next
        if next == nil { mode = .grid }
    }

    private func report(_ result: DeletionResult, copies: Int) {
        var parts: [String] = []
        if !result.trashed.isEmpty {
            parts.append("Moved \(result.trashed.count) file\(result.trashed.count == 1 ? "" : "s") to the Trash")
        }
        if !result.missing.isEmpty {
            parts.append("removed \(result.missing.count) photo\(result.missing.count == 1 ? "" : "s") whose file was already gone")
        }
        if copies > 0 { parts.append("removed \(copies) virtual cop\(copies == 1 ? "y" : "ies")") }
        if !result.offline.isEmpty {
            parts.append("\(result.offline.count) file\(result.offline.count == 1 ? " is" : "s are") offline and stayed in the catalog; connect the drive to delete \(result.offline.count == 1 ? "it" : "them")")
        }
        if parts.isEmpty { return }
        let text = parts.joined(separator: "; ")
        status = text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Most network shares have no Trash. As in Finder, ask before deleting those files for good.
    private func offerImmediateDeletion(_ failures: [(file: RemovalPlan.File, reason: String)]) {
        let files = failures.map { $0.file }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = files.count == 1
            ? "“\(files[0].filename)” can’t be moved to the Trash."
            : "\(files.count) files can’t be moved to the Trash."
        alert.informativeText = "\(failures[0].reason)\n\nYou can delete \(files.count == 1 ? "it" : "them") immediately instead. This can’t be undone. Until then, \(files.count == 1 ? "the photo stays" : "the photos stay") in the catalog."
        alert.addButton(withTitle: "Keep")
        let delete = alert.addButton(withTitle: "Delete Immediately")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            let next = photoAfterRemoving(Set(files.map(\.assetID)))
            let result = try catalog.deletePhotosImmediately(files)
            finishRemoving(result.trashed + result.missing, copies: [], next: next)
            let deleted = result.trashed.count
            status = "Deleted \(deleted) file\(deleted == 1 ? "" : "s")"
                + (result.notTrashed.isEmpty ? "" : ". \(result.notTrashed.count) couldn’t be deleted: \(result.notTrashed[0].reason)")
        } catch {
            status = error.localizedDescription
        }
    }
}
