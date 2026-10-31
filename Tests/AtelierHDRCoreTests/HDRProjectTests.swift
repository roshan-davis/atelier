import XCTest
@testable import AtelierHDRCore

final class HDRProjectTests: XCTestCase {
    func testOwnedSourceAndForkSurviveOriginalRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.tif")
        let io = HDRImageIO()
        try io.writeTIFF(HDRImage(width: 4, height: 3, rgb: Array(repeating: 0.18, count: 36)), to: source)
        let originalHash = try HDRProjectStore.hash(source)
        let projectURL = root.appendingPathComponent("test.atelierhdr")
        let project = try HDRProjectStore.create(at: projectURL, source: source)
        let first = try await project.save(settings: HDRSettings())
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(try HDRProjectStore.hash(source), originalHash)
        try FileManager.default.removeItem(at: source)
        let reopened = try HDRProjectStore.open(projectURL)
        let second = try await reopened.save(settings: HDRSettings())
        XCTAssertEqual(second.projectID, first.projectID)
        XCTAssertEqual(second.outputID, first.outputID)
        XCTAssertEqual(second.revision, 2)
        let fork = try await reopened.fork(to: root.appendingPathComponent("fork.atelierhdr"))
        let forkManifest = await fork.manifest
        XCTAssertNotEqual(forkManifest.projectID, second.projectID)
        XCTAssertNotEqual(forkManifest.outputID, second.outputID)
        XCTAssertEqual(forkManifest.sourceHash, second.sourceHash)
        XCTAssertEqual(forkManifest.revision, 0)
        let result = await reopened.resultURL()
        try FileManager.default.removeItem(at: result)
        try await reopened.publish()
        XCTAssertEqual(try HDRProjectStore.hash(result), second.resultHash)
        let pointer = try Data(contentsOf: projectURL.appendingPathComponent("project.json"))
        do {
            _ = try await reopened.save(settings: HDRSettings(), cancellation: { throw CancellationError() })
            XCTFail("Save should cancel")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: projectURL.appendingPathComponent("project.json")), pointer)
    }

    func testChangedOwnedSourceAndFutureManifestAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.bin")
        try Data("original".utf8).write(to: source)
        let projectURL = root.appendingPathComponent("test.atelierhdr")
        let store = try HDRProjectStore.create(at: projectURL, source: source)
        let owned = await store.sourceURL()
        try Data("changed".utf8).write(to: owned)
        XCTAssertThrowsError(try HDRProjectStore.open(projectURL))
        try Data("original".utf8).write(to: owned)
        let pointer = projectURL.appendingPathComponent("project.json")
        var manifest = await store.manifest; manifest.schemaVersion = 99
        try JSONEncoder().encode(manifest).write(to: pointer)
        XCTAssertThrowsError(try HDRProjectStore.open(projectURL))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }
    func testRelinkAndStaleWriterPreserveCommittedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.tif")
        try HDRImageIO().writeTIFF(HDRImage(width: 8, height: 6, rgb: Array(repeating: 0.18, count: 144)), to: source)
        let hash = try HDRProjectStore.hash(source)
        let url = root.appendingPathComponent("project.atelierhdr")
        let first = try HDRProjectStore.create(at: url, source: source)
        let stale = try HDRProjectStore.open(url)
        let committed = try await first.save(settings: HDRSettings())
        do {
            _ = try await stale.save(settings: HDRSettings())
            XCTFail("A stale writer must not replace the newer revision")
        } catch HDRError.invalidProject {}
        let owned = await first.sourceURL()
        try FileManager.default.moveItem(at: owned, to: root.appendingPathComponent("missing-source.tif"))
        XCTAssertThrowsError(try HDRProjectStore.open(url))
        XCTAssertEqual(try HDRProjectStore.metadata(at: url).projectID, committed.projectID)
        let wrong = root.appendingPathComponent("wrong.tif")
        try Data("different source".utf8).write(to: wrong)
        XCTAssertThrowsError(try HDRProjectStore.relink(url, from: wrong))
        try HDRProjectStore.relink(url, from: source)
        let reopened = try HDRProjectStore.open(url)
        let recovered = await reopened.manifest
        XCTAssertEqual(recovered, committed)
        XCTAssertEqual(try HDRProjectStore.hash(source), hash)
        var checks = 0
        do {
            _ = try await reopened.save(settings: HDRSettings(), cancellation: {
                checks += 1
                if checks == 5 { throw CancellationError() }
            })
            XCTFail("Mid-processing cancellation must stop publication")
        } catch is CancellationError {}
        let after = try HDRProjectStore.metadata(at: url)
        XCTAssertEqual(after, committed)
    }

    func testGenerationRetentionAndAbandonedFirstSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.tif")
        try HDRImageIO().writeTIFF(HDRImage(width: 8, height: 6, rgb: Array(repeating: 0.2, count: 144)), to: original)
        let originalHash = try HDRProjectStore.hash(original)
        let url = root.appendingPathComponent("kept.atelierhdr")
        let store = try HDRProjectStore.create(at: url, source: original)
        var generations: [UUID] = []
        for i in 0..<5 {
            var settings = HDRSettings(); settings.exposure = Float(i) / 10
            let saved = try await store.save(settings: settings)
            generations.append(try XCTUnwrap(saved.generationID))
        }
        let folders = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Generations").path)
        XCTAssertEqual(Set(folders), Set(generations.suffix(2).map(\.uuidString)))
        let reopened = try HDRProjectStore.open(url)
        try FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("tif"))
        try await reopened.publish()
        let discardedSaved = try await store.discardIfUnsaved()
        XCTAssertFalse(discardedSaved, "committed work must never be abandoned")
        let abandonedURL = root.appendingPathComponent("abandoned.atelierhdr")
        let abandoned = try HDRProjectStore.create(at: abandonedURL, source: original)
        let discarded = try await abandoned.discardIfUnsaved()
        XCTAssertTrue(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedURL.path))
        XCTAssertEqual(try HDRProjectStore.hash(original), originalHash)
    }

}
