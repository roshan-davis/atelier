import AtelierCore
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierApp

/// AT-076 E1: a note change the catalog refuses is said in the Notes panel, not dropped.
final class NoteSaveErrorTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierNoteErrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    @MainActor
    func testARefusedNoteSaveIsShownAndClearsOnceAChangeSaves() async throws {
        let (catalog, id) = try await makePhoto()
        let notes = PhotoNotesModel(catalog: catalog)
        notes.show(id)

        notes.startNewNote()
        notes.draftChanged("Crop tighter")
        notes.finishEditing()
        XCTAssertNil(notes.saveError)
        let saved = try XCTUnwrap(try catalog.notes(for: id).first)

        // The catalog refuses every change to notes (as a full disk or a locked file would).
        try catalog.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseNoteUpdate BEFORE UPDATE ON note BEGIN SELECT RAISE(ABORT, 'refused'); END")
            try db.execute(sql: "CREATE TRIGGER refuseNoteDelete BEFORE DELETE ON note BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        notes.toggleCheckbox(saved, line: 0)  // not a checkbox line: nothing to save, no error
        XCTAssertNil(notes.saveError)
        notes.beginEditing(saved)
        notes.draftChanged("Crop tighter, keep the hands")
        notes.finishEditing()
        XCTAssertNotNil(notes.saveError, "an edit the catalog refused must be said")
        XCTAssertEqual(try catalog.notes(for: id).first?.text, "Crop tighter")

        notes.delete(saved)
        XCTAssertNotNil(notes.saveError, "a refused delete must be said")
        XCTAssertNil(notes.recentlyDeleted, "a delete that didn't happen offers no Undo")
        XCTAssertEqual(try catalog.notes(for: id).count, 1)

        try catalog.writer.write { db in
            try db.execute(sql: "DROP TRIGGER refuseNoteUpdate")
            try db.execute(sql: "DROP TRIGGER refuseNoteDelete")
        }
        notes.beginEditing(saved)
        notes.draftChanged("Crop tighter, keep the hands")
        notes.finishEditing()
        XCTAssertNil(notes.saveError, "the error goes once a change saves")
        XCTAssertEqual(try catalog.notes(for: id).first?.text, "Crop tighter, keep the hands")
    }

    /// A catalog with one small JPEG imported.
    private func makePhoto() async throws -> (Catalog, Int64) {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let url = shoot.appendingPathComponent("DSC_1.JPG")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        return (catalog, try XCTUnwrap(result.assetIDsBySource.values.first))
    }
}
