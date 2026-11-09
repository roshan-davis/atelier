import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

final class MatchLookModelTests: XCTestCase {
    @MainActor
    func testChangingMatchControlsDisablesApplyBeforeTheRefitStarts() async throws {
        let (model, library) = try await makeModel()
        let id = model.assetID
        model.useCatalogPhoto(id)
        try await waitUntilReady(model)

        model.areaMode = .boxes
        XCTAssertFalse(model.canApply)
        model.photoArea = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        XCTAssertFalse(model.canApply)
        try await waitUntilReady(model)

        model.protectSkin = true
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.differences.isEmpty)
        try await waitUntilReady(model)
        XCTAssertEqual(model.match?.notices, [.noFaces])
        withExtendedLifetime(library) {}  // The model holds its catalog owner weakly.
    }

    @MainActor
    func testLatestReferenceWinsAndBuiltInUsesWholePhotoUntilReturningToCatalog() async throws {
        let (model, library) = try await makeModel()
        let id = model.assetID
        model.areaMode = .boxes
        model.useCatalogPhoto(id)
        try await waitUntilReady(model)
        let recents = model.recent
        let box = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        model.referenceArea = box
        model.protectSkin = true
        model.strength = 42

        model.useCatalogPhoto(id)
        model.useBuiltIn(.furyRoadScene)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.differences.isEmpty)
        try await waitUntilReady(model)
        XCTAssertEqual(model.builtInReference, .furyRoadScene)
        XCTAssertEqual(model.referenceName, "Mad Max: Fury Road — Desert Action")
        XCTAssertEqual(model.areaMode, .wholePhoto)
        model.areaMode = .subject
        XCTAssertEqual(model.areaMode, .wholePhoto)
        XCTAssertFalse(model.usesAreas)
        XCTAssertEqual(model.match?.notices, [.noFaces])
        XCTAssertEqual(model.recent, recents)
        XCTAssertEqual(model.strength, 42)
        XCTAssertEqual(try library.catalog.developSettings(for: id), .neutral)

        let settings = try XCTUnwrap(model.match).settings(strength: 0.42)
        XCTAssertNotEqual(settings, .neutral)
        model.apply()
        XCTAssertEqual(try library.catalog.developSettings(for: id), settings)
        XCTAssertEqual(try library.catalog.developHistory(for: id).steps.map(\.name), ["Import", "Match Look: Mad Max: Fury Road — Desert Action"])

        model.useCatalogPhoto(id)
        XCTAssertFalse(model.canApply)
        try await waitUntilReady(model)
        XCTAssertNil(model.builtInReference)
        XCTAssertEqual(model.areaMode, .boxes)
        XCTAssertTrue(model.usesAreas)
        XCTAssertEqual(model.referenceArea, box)
    }

    @MainActor
    private func makeModel() async throws -> (MatchLookModel, LibraryModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures/landscape.jpg")
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("MatchTest.atelier"))
        let imported = await Importer(catalog: catalog, previews: nil).run(
            sources: [source], options: ImportOptions(buildPreviews: false)
        )
        let id = try XCTUnwrap(imported.importedAssetIDs.first)
        let library = LibraryModel(catalog: catalog)
        let saved = UserDefaults.standard.object(forKey: "matchLook.options")
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: "matchLook.options") }

        let model = MatchLookModel(library: library, assetID: id, targets: [id], url: source, settings: .neutral)
        model.options = .init(whiteBalance: false, color: false)
        return (model, library)
    }

    @MainActor
    private func waitUntilReady(_ model: MatchLookModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while !model.canApply, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.canApply, model.message ?? "Match did not finish")
    }
}
