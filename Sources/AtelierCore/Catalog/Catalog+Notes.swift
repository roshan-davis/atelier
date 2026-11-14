import Foundation
import GRDB

// Photo notes (AT-058): private sticky notes on a photo, written by the person, by Cull or by
// a chat app. Each catalog photo has its own list (virtual copies included); a new virtual copy,
// stacked edit or AI result starts with a copy of its source's notes, as with title and
// caption. Notes never go into exported files or the IPTC/Dublin Core fields; XMP sidecars keep
// them only in Atelier's own `atelier:Notes` field (see `NotesRecovery`).

/// Who wrote a note.
public enum NoteSource: String, Codable, Hashable, Sendable, DatabaseValueConvertible {
    /// The person, in the notes panel.
    case person
    /// Cull's reasons for not keeping a photo (AT-058 step 3).
    case cull
    /// A chat app over MCP; `PhotoNote.appName` says which.
    case agent
}

public struct PhotoNote: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    public var id: Int64?
    public var assetId: Int64
    /// Plain text in Atelier's small Markdown subset (`NoteText`): bullets, numbered lists,
    /// checkboxes, bold, italic and links.
    public var text: String
    public var source: NoteSource
    /// The chat app's name, for notes by `.agent`.
    public var appName: String?
    public var createdAt: Date
    /// When the text last changed after it was written; nil if never.
    public var editedAt: Date?

    public init(id: Int64? = nil, assetId: Int64, text: String, source: NoteSource = .person, appName: String? = nil,
                createdAt: Date = Date(), editedAt: Date? = nil) {
        self.id = id
        self.assetId = assetId
        self.text = text
        self.source = source
        self.appName = appName
        self.createdAt = createdAt
        self.editedAt = editedAt
    }

    /// "You", "Cull" or the chat app's name, as the panel shows it.
    public var author: String {
        switch source {
        case .person: return "You"
        case .cull: return "Cull"
        case .agent: return appName ?? "Chat app"
        }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Catalog {
    static func registerNotesMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10-notes") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .integer).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("source", .text).notNull().defaults(to: NoteSource.person.rawValue)
                t.column("appName", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("editedAt", .datetime)
            }
        }
    }

    /// A photo's notes, newest first.
    public static func fetchNotes(_ db: Database, assetID: Int64) throws -> [PhotoNote] {
        try PhotoNote.filter(Column("assetId") == assetID)
            .order(Column("createdAt").desc, Column("id").desc)
            .fetchAll(db)
    }

    public func notes(for assetID: Int64) throws -> [PhotoNote] {
        try writer.read { db in try Self.fetchNotes(db, assetID: assetID) }
    }

    /// Adds the same note to each photo (one note per photo, so each can be edited on its own).
    /// Blank text adds nothing. Returns the new notes. Marks the sidecars to write.
    @discardableResult
    public func addNote(_ text: String, source: NoteSource = .person, appName: String? = nil,
                        to assetIDs: [Int64], at date: Date = Date()) throws -> [PhotoNote] {
        let text = NoteText.cleaned(text)
        guard !text.isEmpty, !assetIDs.isEmpty else { return [] }
        return try writer.write { db in
            var added: [PhotoNote] = []
            for assetID in assetIDs {
                guard try Asset.exists(db, key: assetID) else { continue }
                var note = PhotoNote(assetId: assetID, text: text, source: source, appName: appName, createdAt: date)
                try note.insert(db)
                added.append(note)
            }
            try Self.markNotesChanged(db, added.map(\.assetId))
            return added
        }
    }

    /// Changes a note's text and its edited time. Returns the note as saved, or nil when it is gone.
    @discardableResult
    /// `marksEdited: false` while a note is still being typed for the first time.
    public func updateNote(_ id: Int64, text: String, at date: Date = Date(),
                           marksEdited: Bool = true) throws -> PhotoNote? {
        try writer.write { db in
            guard var note = try PhotoNote.fetchOne(db, key: id) else { return nil }
            guard note.text != text else { return note }
            // A note typed into for the first time isn't "edited".
            if marksEdited, !note.text.isEmpty { note.editedAt = date }
            note.text = text
            // Only these two columns, so the Library's photo list (which reads only whether a
            // note exists) isn't fetched again each time typing pauses.
            try db.execute(sql: "UPDATE note SET text = ?, editedAt = ? WHERE id = ?",
                           arguments: [note.text, note.editedAt, id])
            try Self.markNotesChanged(db, [note.assetId])
            return note
        }
    }

    /// The person finished typing: a note emptied while typing is removed, any other one stays. Returns true when it was removed.
    @discardableResult
    public func finishNote(_ id: Int64) throws -> Bool {
        try writer.write { db in
            guard let note = try PhotoNote.fetchOne(db, key: id),
                  NoteText.cleaned(note.text).isEmpty else { return false }
            try PhotoNote.deleteOne(db, key: id)
            try Self.markNotesChanged(db, [note.assetId])
            return true
        }
    }

    /// Deletes a note and returns it, so the panel's Undo can put it back.
    @discardableResult
    public func deleteNote(_ id: Int64) throws -> PhotoNote? {
        try writer.write { db in
            guard let note = try PhotoNote.fetchOne(db, key: id) else { return nil }
            try PhotoNote.deleteOne(db, key: id)
            try Self.markNotesChanged(db, [note.assetId])
            return note
        }
    }

    /// Puts a deleted note back as it was (same id and times), if its photo is still there.
    public func restoreNote(_ note: PhotoNote) throws {
        try writer.write { db in
            guard try Asset.exists(db, key: note.assetId) else { return }
            var restored = note
            try restored.insert(db, onConflict: .replace)
            try Self.markNotesChanged(db, [note.assetId])
        }
    }

    /// Notes only change Atelier's own XMP field, but that is part of the sidecar.
    static func markNotesChanged(_ db: Database, _ assetIDs: [Int64]) throws {
        guard !assetIDs.isEmpty else { return }
        try AssetMetadata.filter(keys: assetIDs).updateAll(db, Column("xmpDirty").set(to: true))
    }

    /// A new virtual copy, stacked edit or AI result starts with its source's notes (once: a
    /// photo that already has notes keeps them).
    static func copyNotes(_ db: Database, from parentID: Int64, to derivedID: Int64) throws {
        try db.execute(sql: """
            INSERT INTO note (assetId, text, source, appName, createdAt, editedAt)
            SELECT :derived, text, source, appName, createdAt, editedAt FROM note
            WHERE assetId = :parent AND NOT EXISTS (SELECT 1 FROM note WHERE assetId = :derived)
            ORDER BY createdAt, id
            """, arguments: ["parent": parentID, "derived": derivedID])
    }

    /// Replaces a photo's notes with `notes` (an agent's undo, a sidecar on import). Ids are kept
    /// when given, so a note put back is the same note.
    static func replaceNotes(_ db: Database, of assetID: Int64, with notes: [PhotoNote]) throws {
        try PhotoNote.filter(Column("assetId") == assetID).deleteAll(db)
        for note in notes {
            var copy = note
            copy.assetId = assetID
            try copy.insert(db, onConflict: .replace)
        }
    }

    /// SQL that is true when the photo `alias` has a note. It reads only `note.assetId`, so the
    /// Library's photo list is fetched again when a note is added or deleted, not while one is
    /// typed (a note is only written once it has text; one emptied while typing still counts
    /// until typing ends and `finishNote` removes it).
    static func hasNotesCondition(_ alias: String = "asset") -> String {
        "EXISTS (SELECT 1 FROM note WHERE note.assetId = \(alias).id)"
    }
}
