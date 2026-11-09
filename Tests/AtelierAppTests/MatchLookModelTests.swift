import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

final class MatchLookModelTests: XCTestCase {
    @MainActor
    func testChangingMatchControlsDisablesApplyBeforeTheRefitStarts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures/landscape.jpg")
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("MatchTest.atelier"))
        let imported = await Importer(catalog: catalog, previews: nil).run(
            sources: [source], options: ImportOptions(buildPreviews: false)
        )
        let id = try XCTUnwrap(imported.importedAssetIDs.first)
        let library = LibraryModel(catalog: catalog)
        let saved = UserDefaults.standard.object(forKey: "matchLook.options")
        defer { UserDefaults.standard.set(saved, forKey: "matchLook.options") }

        let model = MatchLookModel(library: library, assetID: id, targets: [id], url: source, settings: .neutral)
        model.options = .init(whiteBalance: false, color: false)
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
