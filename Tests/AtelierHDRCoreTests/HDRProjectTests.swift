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
}
