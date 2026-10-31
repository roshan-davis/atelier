import XCTest
import GRDB
import AtelierHDRCore
@testable import AtelierCore

final class ProcessorDocumentTests: XCTestCase {
    func testRealTIFFReturnReplayRevisionAndProjectIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.tif")
        try HDRImageIO().writeTIFF(HDRImage(width: 8, height: 6, rgb: Array(repeating: 0.18, count: 144)), to: source)
        let catalog = try Catalog()
        let outcome = try Importer(catalog: catalog, previews: nil).importFile(source, options: ImportOptions(buildPreviews: false))
        let sourceID: Int64
        switch outcome { case .imported(let id, _, _), .existing(let id): sourceID = id }
        let projectURL = root.appendingPathComponent("result.atelierhdr")
        let store = try HDRProjectStore.create(at: projectURL, source: source)
        let manifest = try await store.save(settings: HDRSettings())
        let request = ProcessorDocument(sourceAssetID: sourceID, sourceURL: source, sourceHash: manifest.sourceHash,
            projectURL: projectURL, expectedProjectID: manifest.projectID, outputID: manifest.outputID)
        func receipt(_ m: HDRProjectManifest) -> ProcessorReceipt {
            ProcessorReceipt(jobID: request.jobID, projectID: m.projectID, outputID: m.outputID, revision: m.revision,
                sourceHash: m.sourceHash, resultHash: m.resultHash!, generationID: m.generationID!, width: m.width, height: m.height)
        }
        let first = try catalog.acceptProcessorResult(receipt(manifest), request: request)
        XCTAssertEqual(try catalog.acceptProcessorResult(receipt(manifest), request: request), first)
        XCTAssertEqual(try catalog.derivation(of: first)?.assetId, sourceID)
        XCTAssertEqual(try catalog.processorAssociation(for: first)?.projectID, manifest.projectID)
        // Opening the same committed output under a new job is already cataloged. It
        // must not re-import, invalidate previews or trigger host navigation/status.
        var reopenedRequest = request; reopenedRequest.jobID = UUID()
        var reopenedReceipt = receipt(manifest); reopenedReceipt.jobID = reopenedRequest.jobID
        XCTAssertTrue(try catalog.hasConsumedProcessorResult(reopenedReceipt, request: reopenedRequest))
        XCTAssertEqual(try catalog.acceptProcessorResult(reopenedReceipt, request: reopenedRequest), first)
        var settings = HDRSettings(); settings.exposure = 0.5
        let next = try await store.save(settings: settings)
        XCTAssertEqual(try catalog.acceptProcessorResult(receipt(next), request: request), first)
        XCTAssertEqual(try catalog.processorAssociation(for: first)?.revision, 2)
        XCTAssertEqual(try catalog.acceptProcessorResult(receipt(manifest), request: request), first)
        XCTAssertEqual(try catalog.processorAssociation(for: first)?.revision, 2)
        let count = try await catalog.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset") }
        XCTAssertEqual(count, 2)
        var wrong = receipt(next); wrong.sourceHash = "wrong"
        XCTAssertThrowsError(try catalog.acceptProcessorResult(wrong, request: request))
        wrong = receipt(next); wrong.projectID = UUID()
        XCTAssertThrowsError(try catalog.acceptProcessorResult(wrong, request: request))
        let versions = try await catalog.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM version WHERE derivedAssetId IS NOT NULL") }
        XCTAssertEqual(versions, 1)
        XCTAssertEqual(try HDRProjectStore.hash(source), manifest.sourceHash)
    }
}
