import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// AT-058: photo notes in the catalog, virtual copies, search, agent undo and XMP sidecars, and
/// the Markdown subset they are written in.
final class NotesTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierNotes-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// A catalog with `count` JPEGs imported from one folder, ids in file name order.
    private func makeLibrary(_ names: [String] = ["DSC_1.JPG", "DSC_2.JPG"],
                             catalog: Catalog? = nil) async throws -> (Catalog, [Int64]) {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        for name in names where !FileManager.default.fileExists(atPath: shoot.appendingPathComponent(name).path) {
            try makeJPEG(at: shoot.appendingPathComponent(name))
        }
        let catalog = try catalog ?? Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        let byName = Dictionary(uniqueKeysWithValues: result.assetIDsBySource.map { ($0.key.lastPathComponent, $0.value) })
        return (catalog, try names.map { try XCTUnwrap(byName[$0]) })
    }

    // MARK: Catalog

    func testAddEditDeleteAndRestore() async throws {
        let (catalog, ids) = try await makeLibrary()
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let added = try catalog.addNote("  Crop tighter\n- [ ] print 8x10  \n", to: ids, at: written)
        XCTAssertEqual(added.count, 2, "one note per photo")
        XCTAssertEqual(added[0].text, "Crop tighter\n- [ ] print 8x10", "blank ends are trimmed")
        XCTAssertEqual(added[0].author, "You")
        XCTAssertTrue(try catalog.addNote("   ", to: ids).isEmpty, "blank text adds nothing")

        let later = written.addingTimeInterval(60)
        let second = try XCTUnwrap(try catalog.addNote("Try black and white", source: .agent, appName: "Claude",
                                                       to: [ids[0]], at: later).first)
        XCTAssertEqual(second.author, "Claude")
        let notes = try catalog.notes(for: ids[0])
        XCTAssertEqual(notes.map(\.text), ["Try black and white", "Crop tighter\n- [ ] print 8x10"], "newest first")
        XCTAssertEqual(try catalog.notes(for: ids[1]).count, 1)

        let id = try XCTUnwrap(added[0].id)
        let edited = try XCTUnwrap(try catalog.updateNote(id, text: "Crop tighter\n- [x] print 8x10", at: later))
        XCTAssertEqual(edited.editedAt, later)
        XCTAssertEqual(edited.createdAt.timeIntervalSince1970, written.timeIntervalSince1970, accuracy: 0.001)

        let deleted = try XCTUnwrap(try catalog.deleteNote(id))
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.text), ["Try black and white"])
        try catalog.restoreNote(deleted)
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.id), [second.id, id], "Undo puts back the same note")
        XCTAssertNil(try catalog.updateNote(999_999, text: "gone"))
    }

    func testEmptiedNoteIsRemovedWhenTypingEnds() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG"])
        XCTAssertTrue(try catalog.addNote("  \n ", to: ids).isEmpty, "blank text adds nothing")
        XCTAssertTrue(try catalog.assetRows(filter: LibraryFilter(notes: .hasNotes)).isEmpty)

        let note = try XCTUnwrap(try catalog.addNote("Eyes closed", to: ids).first)
        let id = try XCTUnwrap(note.id)
        XCTAssertNil(note.editedAt)
        XCTAssertFalse(try catalog.finishNote(id))
        XCTAssertNotNil(try catalog.updateNote(id, text: "Eyes closed, soft")?.editedAt)
        _ = try catalog.updateNote(id, text: "")
        XCTAssertTrue(try catalog.finishNote(id), "a note emptied while typing goes away when typing ends")
        XCTAssertTrue(try catalog.notes(for: ids[0]).isEmpty)
        XCTAssertTrue(try catalog.assetRows(filter: LibraryFilter(notes: .hasNotes)).isEmpty)
    }

    func testNotesFollowVirtualCopiesAndThenStayTheirOwn() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG"])
        try catalog.addNote("Shop print", to: ids)
        let copy = try catalog.createVirtualCopy(of: ids[0])
        XCTAssertEqual(try catalog.notes(for: copy).map(\.text), ["Shop print"], "a new copy starts with the notes")

        try catalog.addNote("B&W version", to: [copy])
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.text), ["Shop print"], "the original keeps its own")
        XCTAssertEqual(try catalog.notes(for: copy).count, 2)
        try catalog.removeVirtualCopies([copy])
        XCTAssertTrue(try catalog.notes(for: copy).isEmpty)
    }

    func testSearchAndFiltersFindNotes() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG", "DSC_2.JPG", "DSC_3.JPG"])
        try catalog.addNote("**Eyes** closed on the left", to: [ids[0]])
        try catalog.addNote("- [ ] send to Anna\n- [x] crop", to: [ids[1]])
        func found(_ filter: LibraryFilter) throws -> [Int64] { try catalog.assetRows(filter: filter).map(\.id).sorted() }

        XCTAssertEqual(try found(LibraryFilter(text: "closed")), [ids[0]])
        XCTAssertEqual(try found(LibraryFilter(text: "anna")), [ids[1]], "search ignores case")
        XCTAssertEqual(try found(LibraryFilter(notes: .hasNotes)), [ids[0], ids[1]])
        XCTAssertEqual(try found(LibraryFilter(notes: .noNotes)), [ids[2]])
        XCTAssertEqual(try found(LibraryFilter(notes: .openCheckboxes)), [ids[1]])
        let rows = try catalog.assetRows(filter: LibraryFilter())
        XCTAssertEqual(rows.filter(\.hasNotes).map(\.id).sorted(), [ids[0], ids[1]], "the thumbnail badge")
        XCTAssertEqual(LibraryFilter(notes: .hasNotes).summary, ["Has Notes"])
        XCTAssertTrue(LibraryFilter(notes: .noNotes).isFiltering)
        XCTAssertNil(LibraryFilter(notes: .hasNotes).cleared.notes)

        // Saved with the session.
        let session = SavedSession(filter: LibraryFilter(notes: .openCheckboxes))
        let decoded = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.filter(base: LibraryFilter()).notes, .openCheckboxes)
    }

    /// An agent's note is one change: undo takes it off again, only while it is still the latest.
    func testLibraryStatesIncludeNotesForAgentUndo() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG"])
        try catalog.addNote("Mine", to: ids)
        let before = try catalog.libraryStates(for: ids)
        XCTAssertEqual(before[ids[0]]?.notes.map(\.text), ["Mine"])

        try catalog.addNote("Looks soft", source: .agent, appName: "Claude", to: ids)
        XCTAssertNotEqual(try catalog.libraryStates(for: ids), before)
        try catalog.restoreLibraryStates(before)
        XCTAssertEqual(try catalog.libraryStates(for: ids), before)
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.text), ["Mine"])
    }

    // MARK: XMP

    func testSidecarKeepsNotesInAtelierFieldPerFile() throws {
        let sidecar = workDir.appendingPathComponent("DSC_1.xmp")
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = [NotesRecovery.Note(text: "- Eyes closed\n- Softer than DSC_2", source: .cull, created: created)]
        let jpeg = [NotesRecovery.Note(text: "JPEG for the client", source: .person, created: created,
                                       edited: created.addingTimeInterval(5))]
        try XMPSidecar.write(XMPFields(rating: 2, caption: "Harbor", notes: raw), toSidecar: sidecar, filename: "DSC_1.NEF")
        try XMPSidecar.write(XMPFields(rating: 2, caption: "Harbor", notes: jpeg), toSidecar: sidecar, filename: "DSC_1.JPG")

        XCTAssertEqual(XMPSidecar.read(sidecar: sidecar, filename: "DSC_1.NEF")?.notes, raw)
        XCTAssertEqual(XMPSidecar.read(sidecar: sidecar, filename: "DSC_1.JPG")?.notes, jpeg)
        XCTAssertNil(XMPSidecar.read(sidecar: sidecar)?.notes, "notes are read only for a named file")
        XCTAssertEqual(XMPSidecar.read(sidecar: sidecar)?.caption, "Harbor", "the caption is untouched")

        // Never in Caption, Instructions or User Comment.
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("atelier:Notes"))
        XCTAssertFalse(text.contains("photoshop:Instructions"))
        XCTAssertFalse(text.contains("UserComment"))

        // No notes left for one file takes only its entry out; nil leaves the field alone.
        try XMPSidecar.write(XMPFields(rating: 2, notes: []), toSidecar: sidecar, filename: "DSC_1.JPG")
        XCTAssertNil(XMPSidecar.read(sidecar: sidecar, filename: "DSC_1.JPG")?.notes)
        try XMPSidecar.write(XMPFields(rating: 3), toSidecar: sidecar, filename: "DSC_1.NEF")
        XCTAssertEqual(XMPSidecar.read(sidecar: sidecar, filename: "DSC_1.NEF")?.notes, raw)
        try XMPSidecar.write(XMPFields(rating: 3, notes: []), toSidecar: sidecar, filename: "DSC_1.NEF")
        XCTAssertFalse(try String(contentsOf: sidecar, encoding: .utf8).contains("atelier:Notes"))
    }

    func testNotesRoundTripThroughSidecarIntoNewCatalog() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG"])
        try catalog.addNote("First note", to: ids, at: Date(timeIntervalSince1970: 1_800_000_000))
        try catalog.addNote("Second, by an app", source: .agent, appName: "Claude", to: ids,
                            at: Date(timeIntervalSince1970: 1_800_000_100))
        let emptied = try XCTUnwrap(try catalog.addNote("x", to: ids).first?.id)
        _ = try catalog.updateNote(emptied, text: "")
        let result = try catalog.writeXMPSidecars(for: ids)
        XCTAssertEqual(result.written, 1)
        let dirty = try catalog.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT xmpDirty FROM metadata WHERE assetId = ?", arguments: [ids[0]])
        }
        XCTAssertEqual(dirty, false)

        let (fresh, freshIDs) = try await makeLibrary(["DSC_1.JPG"], catalog: try Catalog())
        let restored = try fresh.notes(for: freshIDs[0])
        XCTAssertEqual(restored.map(\.text), ["Second, by an app", "First note"], "the empty note isn't written")
        XCTAssertEqual(restored.first?.author, "Claude")
        XCTAssertEqual(restored.last?.createdAt.timeIntervalSince1970 ?? 0, 1_800_000_000, accuracy: 1)
        XCTAssertNil(try fresh.detail(for: freshIDs[0])?.metadata.caption, "notes never become the caption")
    }

    func testChangingANoteMarksTheSidecarUnsaved() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG"])
        _ = try catalog.writeXMPSidecars(for: ids)
        let note = try XCTUnwrap(try catalog.addNote("Check focus", to: ids).first)
        func dirty() throws -> Bool {
            try catalog.writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT xmpDirty FROM metadata WHERE assetId = ?", arguments: [ids[0]]) ?? false
            }
        }
        XCTAssertTrue(try dirty())
        _ = try catalog.writeXMPSidecars(for: ids)
        XCTAssertFalse(try dirty())
        try catalog.updateNote(try XCTUnwrap(note.id), text: "Focus is fine")
        XCTAssertTrue(try dirty())
        _ = try catalog.writeXMPSidecars(for: ids)
        try catalog.deleteNote(try XCTUnwrap(note.id))
        XCTAssertTrue(try dirty())
    }

    // MARK: Markdown subset

    func testLinesReadTheMarkdownSubset() {
        let lines = NoteText.lines("Plain\n- bullet\n  - [x] done\n    1. third level\n      - too deep\n12) twelve\n*not a list*")
        XCTAssertEqual(lines[0], NoteText.Line(marker: .none, content: "Plain"))
        XCTAssertEqual(lines[1], NoteText.Line(marker: .bullet, content: "bullet"))
        XCTAssertEqual(lines[2], NoteText.Line(indent: 1, marker: .checkbox(checked: true), content: "done"))
        XCTAssertEqual(lines[3], NoteText.Line(indent: 2, marker: .numbered(1), content: "third level"))
        XCTAssertEqual(lines[4].indent, NoteText.maxIndent, "two levels at most")
        XCTAssertEqual(lines[5].marker, .numbered(12))
        XCTAssertEqual(lines[6].marker, .none, "italic text isn't a bullet")
        XCTAssertEqual(NoteText.line("\t- tabbed").indent, 1)
    }

    func testListButtonsToggleLists() {
        XCTAssertEqual(NoteText.togglingList(.bullet, lines: ["Crop", "  Horizon"]), ["- Crop", "- Horizon"])
        XCTAssertEqual(NoteText.togglingList(.bullet, lines: ["- Crop", "- Horizon"]), ["Crop", "Horizon"],
                       "a list of that kind goes back to plain lines")
        XCTAssertEqual(NoteText.togglingList(.numbered, lines: ["- Crop", "  - Horizon"]), ["1. Crop", "  2. Horizon"])
        XCTAssertEqual(NoteText.togglingList(.checkbox, lines: ["- [x] Done", "Todo"]), ["- [x] Done", "- [ ] Todo"])
        XCTAssertEqual(NoteText.togglingList(.checkbox, lines: [""]), ["- [ ] "])
    }

    func testNoteColors() {
        XCTAssertEqual(NoteColor.yellow.paper(customHex: "").hex, "FFEB6B")
        XCTAssertEqual(NoteColor.custom.paper(customHex: "#336699").hex, "336699")
        XCTAssertEqual(NoteColor.custom.paper(customHex: "nonsense"), NoteColor.yellow.preset)
        XCTAssertNil(NoteColor.RGB(hex: "12345"))
        for color in NoteColor.allCases where color != .custom {
            XCTAssertTrue(color.paper(customHex: "").inkIsDark, "\(color) paper takes dark ink")
        }
        XCTAssertFalse(NoteColor.custom.paper(customHex: "202040").inkIsDark, "a dark custom color takes light ink")
        XCTAssertEqual(NoteColor.defaultOpacity, 0.85)
    }

    func testTypingHelpers() {
        XCTAssertEqual(NoteText.continuation(after: "- milk"), .continueWith("- "))
        XCTAssertEqual(NoteText.continuation(after: "  - [x] done"), .continueWith("  - [ ] "))
        XCTAssertEqual(NoteText.continuation(after: "3. third"), .continueWith("4. "))
        XCTAssertEqual(NoteText.continuation(after: "- "), .endList, "Return on an empty item ends the list")
        XCTAssertEqual(NoteText.continuation(after: "Just text"), .newLine)

        XCTAssertEqual(NoteText.typedShortcut("[] "), "- [ ] ")
        XCTAssertEqual(NoteText.typedShortcut("  * item"), "  - item")
        XCTAssertNil(NoteText.typedShortcut("- already"))

        XCTAssertEqual(NoteText.indented("- a", by: 1), "  - a")
        XCTAssertEqual(NoteText.indented("    - a", by: 1), "    - a", "no deeper than two levels")
        XCTAssertEqual(NoteText.indented("  1. a", by: -1), "1. a")
        XCTAssertEqual(NoteText.indented("plain", by: 1), "plain")

        let note = "Shopping\n- [ ] film\n- [x] battery"
        XCTAssertEqual(NoteText.togglingCheckbox(atLine: 1, in: note), "Shopping\n- [x] film\n- [x] battery")
        XCTAssertEqual(NoteText.togglingCheckbox(atLine: 0, in: note), note, "not a checkbox line")
        XCTAssertTrue(NoteText.hasOpenCheckbox(note))
        XCTAssertFalse(NoteText.hasOpenCheckbox("- [x] done"))
        XCTAssertEqual(NoteText.plain("- **Eyes** closed\n1. *soft*"), "Eyes closed\nsoft")
    }

    // MARK: Cull's reasons (AT-058 step 3)

    func testCullNotesReplaceUneditedOnesAndMarkKeptLater() async throws {
        let (catalog, ids) = try await makeLibrary(["DSC_1.JPG", "DSC_2.JPG", "DSC_3.JPG"])
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try catalog.writeCullNotes(rejected: [ids[0]: "Not kept: group of 3\n- Eyes closed", ids[1]: "Not kept\n- Softer"],
                                   kept: [ids[2]], at: first)
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.source), [.cull])
        XCTAssertEqual(try catalog.notes(for: ids[0]).first?.author, "Cull")
        XCTAssertTrue(try catalog.notes(for: ids[2]).isEmpty, "kept photos get no note")

        // The person edits the second photo's note; a person's own note stays whatever happens.
        let edited = try XCTUnwrap(try catalog.notes(for: ids[1]).first?.id)
        try catalog.updateNote(edited, text: "Not kept\n- Softer\n- but I like the light", at: first.addingTimeInterval(5))
        try catalog.addNote("Print this one?", to: [ids[0]], at: first.addingTimeInterval(6))

        // Culled again: the unedited Cull note is replaced, the edited one kept beside the new one.
        let second = first.addingTimeInterval(60)
        try catalog.writeCullNotes(rejected: [ids[0]: "Not kept\n- Highlights clipped", ids[1]: "Not kept\n- Eyes half closed"],
                                   kept: [], at: second)
        XCTAssertEqual(try catalog.notes(for: ids[0]).map(\.text), ["Not kept\n- Highlights clipped", "Print this one?"])
        XCTAssertEqual(try catalog.notes(for: ids[1]).map(\.text),
                       ["Not kept\n- Eyes half closed", "Not kept\n- Softer\n- but I like the light"])

        // Kept on re-review: the old Cull note stays, marked once.
        try catalog.writeCullNotes(rejected: [:], kept: [ids[0]], at: second)
        try catalog.writeCullNotes(rejected: [:], kept: [ids[0]], at: second)
        let kept = try XCTUnwrap(try catalog.notes(for: ids[0]).first { $0.source == .cull })
        XCTAssertEqual(kept.text, Catalog.keptLaterMark + "\nNot kept\n- Highlights clipped")
    }

    private func makeJPEG(at url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
