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

        model.skinMode = .protect
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
        model.skinMode = .protect
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
    func testSkinChoiceAndBatchApplyUseASeparateMaskForEachPortrait() async throws {
        let (model, library) = try await makeModel(fixtures: ["portrait", "portrait-light", "landscape"])
        model.useBuiltIn(.matrixPortrait)
        try await waitUntilReady(model)
        XCTAssertEqual(model.skinMode, .protect)

        model.skinMode = .match
        XCTAssertEqual(model.applyMode, .each)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.differences.isEmpty)
        model.skinMode = .off
        XCTAssertEqual(model.applyMode, .same)
        model.skinMode = .match
        model.options.tone = false
        try await waitUntilReady(model)

        model.useBuiltIn(.furyRoadScene)
        for _ in 0..<200 where model.match?.notices.contains(.noSkinInReference) != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.skinMode, .match)
        XCTAssertEqual(model.match?.notices, [.noSkinInReference])
        XCTAssertFalse(model.canApply)

        model.useBuiltIn(.matrixPortrait)
        model.strength = 60
        try await waitUntilReady(model)
        let before = try library.catalog.developSettings(for: model.assetID)
        XCTAssertEqual(before, .neutral)
        XCTAssertTrue(model.differences.contains { $0.name.hasPrefix("Skin ") })
        let expected = try XCTUnwrap(model.match).settings(strength: 0.6)
        model.apply()
        for _ in 0..<400 where library.matchProgress != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(library.matchProgress)
        XCTAssertEqual(try library.catalog.developSettings(for: model.assetID), expected)
        let first = try XCTUnwrap(expected.masks.first)
        let second = try XCTUnwrap(library.catalog.developSettings(for: model.targets[1]).masks.first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.components.first?.shape, second.components.first?.shape)
        XCTAssertEqual(try library.catalog.developSettings(for: model.targets[2]), .neutral)
        for id in model.targets.prefix(2) {
            let history = try library.catalog.developHistory(for: id)
            XCTAssertEqual(history.steps.map(\.name), ["Import", "Match Look: The Matrix — Portrait"])
        }
        XCTAssertTrue(library.status?.contains("Skipped face color on 1 additional photo") == true)
    }

    @MainActor
    func testMissingSkinAllowsGlobalFitAndDoesNotBlockOtherPortraits() async throws {
        let (model, library) = try await makeModel(fixtures: ["landscape", "portrait"])
        model.skinMode = .match
        model.useBuiltIn(.furyRoadScene)
        try await waitUntilReady(model)
        XCTAssertEqual(model.match?.notices, [.noSkinInPhoto, .noSkinInReference])
        XCTAssertFalse(model.differences.isEmpty)

        model.options.tone = false
        for _ in 0..<200 where model.isMatching { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isMatching)
        XCTAssertFalse(model.canApply)

        model.useBuiltIn(.matrixPortrait)
        try await waitUntilReady(model)
        XCTAssertEqual(model.match?.notices, [.noSkinInPhoto])
        XCTAssertTrue(model.differences.isEmpty)

        model.apply()
        for _ in 0..<400 where library.matchProgress != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(library.matchProgress)
        XCTAssertEqual(try library.catalog.developSettings(for: model.assetID), .neutral)
        XCTAssertTrue(try library.catalog.developHistory(for: model.assetID).steps.isEmpty)
        XCTAssertEqual(try library.catalog.developSettings(for: model.targets[1]).masks.first?.name,
                       LookMatch.skinMaskName)
        XCTAssertTrue(library.status?.contains("Matched 1 photo, 1 unchanged") == true)
    }

    @MainActor
    private func makeModel(fixtures: [String] = ["landscape"]) async throws -> (MatchLookModel, LibraryModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        let sources = fixtures.map { directory.appendingPathComponent($0 + ".jpg") }
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("MatchTest.atelier"))
        var ids: [Int64] = []
        for source in sources {
            let imported = await Importer(catalog: catalog, previews: nil).run(
                sources: [source], options: ImportOptions(buildPreviews: false)
            )
            ids.append(try XCTUnwrap(imported.importedAssetIDs.first))
        }
        let id = try XCTUnwrap(ids.first)
        let library = LibraryModel(catalog: catalog)
        let saved = UserDefaults.standard.object(forKey: "matchLook.options")
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: "matchLook.options") }

        let model = MatchLookModel(library: library, assetID: id, targets: ids, url: sources[0], settings: .neutral)
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
