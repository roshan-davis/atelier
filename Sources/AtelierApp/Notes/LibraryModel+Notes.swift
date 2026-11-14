import AtelierCore
import Foundation

/// Photo notes (AT-058): Photo > Add Note… and View > Show Notes.
extension LibraryModel {
    /// Photo > Add Note… (⌥⇧⌘N): shows the panel with a new note to type on the focused photo
    /// (or the Cull view's), which also goes to the other `ids` when typing ends.
    func addNote(to ids: [Int64]) {
        if let cull = cullSession {
            guard let id = cull.focusedAssetID else { return }
            NotesPanel.isVisible = true
            cull.noteRequest = NoteRequest(assetIDs: [id])
            return
        }
        guard !ids.isEmpty else { return }
        // The note opens on the focused photo when it is one of them, else on the first.
        let first = focusedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        if focusedID != first { focusedID = first }
        NotesPanel.isVisible = true
        noteRequest = NoteRequest(assetIDs: [first] + ids.filter { $0 != first })
    }

    var canAddNote: Bool {
        if let cull = cullSession { return cull.focusedAssetID != nil }
        return focusedID != nil && mode != .hdr
    }

    /// The panel's second line: the photo's name, and how many are selected in the Grid.
    var notesSubtitle: String {
        let name = rows.first { $0.id == focusedID }?.filename ?? detail?.asset.filename ?? ""
        let others = mode == .grid ? selection.count : 0
        return others > 1 ? "\(name) · \(others) selected" : name
    }

    /// Every photo a new note goes to, the focused one first.
    var noteTargets: [Int64] {
        let ids = targetIDs
        guard let focusedID, ids.contains(focusedID) else { return ids }
        return [focusedID] + ids.filter { $0 != focusedID }
    }
}
