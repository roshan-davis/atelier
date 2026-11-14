import Foundation
import GRDB

// Cull's reason notes (AT-058 step 3): when a cull ends, each photo not kept gets one note by
// Cull saying why, compared with its group's keeper. Kept photos get none.

extension Catalog {
    /// Writes Cull's notes when a cull ends. Each photo in `rejected` gets its reason note,
    /// replacing Cull's earlier note on it unless the person edited that one (then the edited
    /// note stays and the new one is added). A photo in `kept` that has an unedited Cull note
    /// from an earlier cull keeps it, marked "Kept later". All in one write. Marks the sidecars.
    public func writeCullNotes(rejected: [Int64: String], kept: [Int64], at date: Date = Date()) throws {
        guard !rejected.isEmpty || !kept.isEmpty else { return }
        try writer.write { db in
            var changed: [Int64] = []
            for (assetID, text) in rejected {
                let text = NoteText.cleaned(text)
                guard !text.isEmpty, try Asset.exists(db, key: assetID) else { continue }
                try PhotoNote
                    .filter(Column("assetId") == assetID && Column("source") == NoteSource.cull.rawValue
                            && Column("editedAt") == nil)
                    .deleteAll(db)
                var note = PhotoNote(assetId: assetID, text: text, source: .cull, createdAt: date)
                try note.insert(db)
                changed.append(assetID)
            }
            for assetID in kept {
                let earlier = try PhotoNote
                    .filter(Column("assetId") == assetID && Column("source") == NoteSource.cull.rawValue
                            && Column("editedAt") == nil)
                    .fetchAll(db)
                for note in earlier where !note.text.hasPrefix(Self.keptLaterMark) {
                    try db.execute(sql: "UPDATE note SET text = ? WHERE id = ?",
                                   arguments: [Self.keptLaterMark + "\n" + note.text, note.id])
                    changed.append(assetID)
                }
            }
            try Self.markNotesChanged(db, changed)
        }
    }

    /// The first line added to a Cull note when its photo is kept on a later cull or re-review.
    public static let keptLaterMark = "**Kept later.**"
}
