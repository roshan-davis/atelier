import AtelierCore
import Foundation
import GRDB

/// The notes of the photo one notes panel shows (AT-058), kept current from the catalog, with the
/// note being typed. The Library window and the Cull view each have their own, so a note written
/// in one shows in the other at once (both watch the catalog).
@MainActor
final class PhotoNotesModel: ObservableObject {
    let catalog: Catalog
    @Published private(set) var assetID: Int64?
    /// Newest first, as saved.
    @Published private(set) var notes: [PhotoNote] = []
    /// The note open for typing, and its text as typed (saved shortly after each change).
    @Published private(set) var editingID: Int64? {
        didSet { if editingID != oldValue { editingSeen = false } }
    }
    /// The catalog has shown the note being typed at least once, so its absence later means it
    /// was deleted elsewhere (and not that the list is from before it was added).
    private var editingSeen = false
    /// A new note is being typed that has no text yet, so it isn't in the catalog. Its first
    /// save adds it (then `editingID` is set), so an empty note is never written.
    @Published private(set) var isNew = false
    /// Set once the new note's first save added it: later saves of the same typing aren't edits.
    private var typingNewNote = false
    @Published private(set) var draft = ""
    /// The note just deleted, while its Undo shows.
    @Published private(set) var recentlyDeleted: PhotoNote?

    /// Other selected photos a new note also goes to when typing ends ("Adding to 12 photos").
    @Published private(set) var alsoFor: [Int64] = []
    private var observation: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var undoTimer: Task<Void, Never>?

    init(catalog: Catalog) {
        self.catalog = catalog
    }

    deinit {
        observation?.cancel()
        pendingSave?.cancel()
        undoTimer?.cancel()
    }

    var isEditing: Bool { editingID != nil || isNew }

    /// Shows another photo's notes. Typing in progress is saved first.
    func show(_ id: Int64?) {
        guard id != assetID else { return }
        finishEditing()
        recentlyDeleted = nil
        assetID = id
        notes = []
        observation?.cancel()
        guard let id else { return }
        let observed = ValueObservation.tracking { db in try Catalog.fetchNotes(db, assetID: id) }
        let writer = catalog.writer
        observation = Task { [weak self] in
            do {
                for try await notes in observed.values(in: writer) {
                    guard let self, !Task.isCancelled, self.assetID == id else { return }
                    self.notes = notes
                    // The note being typed was deleted elsewhere (an agent's undo): stop typing.
                    if let editing = self.editingID {
                        if notes.contains(where: { $0.id == editing }) {
                            self.editingSeen = true
                        } else if self.editingSeen {
                            self.pendingSave?.cancel()
                            self.editingID = nil
                            self.typingNewNote = false
                            self.alsoFor = []
                        }
                    }
                }
            } catch {}
        }
    }

    /// Photo > Add Note… and the panel's + button: a new note to type, on top. `others` get the
    /// same text when typing ends.
    func startNewNote(alsoFor others: [Int64] = []) {
        guard let assetID else { return }
        finishEditing()
        alsoFor = others.filter { $0 != assetID }
        draft = ""
        isNew = true
    }

    func beginEditing(_ note: PhotoNote) {
        guard let id = note.id, id != editingID else { return }
        finishEditing()
        typingNewNote = false
        draft = note.text
        editingID = id
    }

    /// Each change is saved about half a second after typing pauses, and when typing ends.
    func draftChanged(_ text: String) {
        guard text != draft else { return }
        draft = text
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    private func saveDraft() {
        pendingSave?.cancel()
        pendingSave = nil
        if isNew {
            guard let assetID, !NoteText.cleaned(draft).isEmpty,
                  let note = (try? catalog.addNote(draft, to: [assetID]))?.first, let id = note.id else { return }
            isNew = false
            typingNewNote = true
            editingID = id
            return
        }
        guard let id = editingID else { return }
        _ = try? catalog.updateNote(id, text: draft, marksEdited: !typingNewNote)
    }

    /// Esc, ⌘Return, clicking Done, another photo or hiding the panel. An empty note goes away;
    /// a new note's text is also added to the other selected photos.
    func finishEditing() {
        pendingSave?.cancel()
        pendingSave = nil
        if isNew {
            let text = NoteText.cleaned(draft)
            if let assetID, !text.isEmpty { _ = try? catalog.addNote(text, to: [assetID] + alsoFor) }
            isNew = false
            alsoFor = []
            draft = ""
            return
        }
        guard let id = editingID else { return }
        let text = NoteText.cleaned(draft)
        _ = try? catalog.updateNote(id, text: text, marksEdited: !typingNewNote)
        typingNewNote = false
        let removed = (try? catalog.finishNote(id)) ?? false
        if !removed, !alsoFor.isEmpty { _ = try? catalog.addNote(text, to: alsoFor) }
        editingID = nil
        alsoFor = []
        draft = ""
    }

    /// Clicking a checkbox ticks or unticks it, without opening the note for typing.
    func toggleCheckbox(_ note: PhotoNote, line: Int) {
        guard let id = note.id else { return }
        let text = id == editingID ? draft : note.text
        let toggled = NoteText.togglingCheckbox(atLine: line, in: text)
        guard toggled != text else { return }
        if id == editingID { draft = toggled }
        _ = try? catalog.updateNote(id, text: toggled)
    }

    /// Deletes a note at once (no question, as Notes does) with Undo in the panel for ten seconds.
    func delete(_ note: PhotoNote) {
        guard let id = note.id else { return }
        if id == editingID {
            pendingSave?.cancel()
            typingNewNote = false
            editingID = nil
            alsoFor = []
            draft = ""
        }
        guard let deleted = try? catalog.deleteNote(id) else { return }
        notes.removeAll { $0.id == id }
        // A note emptied while typing has nothing to bring back: no sound, no Undo.
        guard !NoteText.cleaned(deleted.text).isEmpty else { return }
        DeleteFeedback.play(.remove)
        recentlyDeleted = deleted
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.recentlyDeleted?.id == deleted.id else { return }
            self?.recentlyDeleted = nil
        }
    }

    func undoDelete() {
        guard let note = recentlyDeleted else { return }
        try? catalog.restoreNote(note)
        recentlyDeleted = nil
    }
}
