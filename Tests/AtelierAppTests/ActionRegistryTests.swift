import AgentActions
import AtelierActions
import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

/// The registry is complete: every catalog action has a handler, and every key runs one.
final class ActionRegistryTests: XCTestCase {
    @MainActor
    func testEveryActionIsBoundAndNoBindingIsStray() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("Actions.atelier"))
        let library = LibraryModel(catalog: catalog)

        let registry = library.actions
        XCTAssertEqual(registry.unbound, [], "Bind these in LibraryModel+Actions.swift")
        XCTAssertEqual(registry.problems, [])
        XCTAssertEqual(AtelierAction.catalog.problems, [])
        // With nothing in the catalog, commands that need a photo are off.
        XCTAssertFalse(registry.isEnabled(AtelierAction.hdr.id))
        XCTAssertTrue(registry.isEnabled(AtelierAction.importPhotos.id))
        XCTAssertEqual(registry.activeShortcut(AtelierAction.writeXMP.id), KeyShortcut("s"))
        XCTAssertNil(registry.activeShortcut(AtelierAction.saveHDR.id), "⌘S is Write XMP outside HDR")
    }
}
