import XCTest
import AtelierHDRCore
@testable import AtelierCore

final class HDRReviewRegressionTests: XCTestCase {
    func testImportExcludesUnregisteredHDRFoldersAndExplicitDescendants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateSource = root.appendingPathComponent("test.ATELIERHDR/Sources/source.nef")
        let generation = root.appendingPathComponent("test.ATELIERHDR/Generations/one/result.tif")
        for file in [privateSource, generation, root.appendingPathComponent("original.nef"),
                     root.appendingPathComponent("returned.tif")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        XCTAssertEqual(Set(Importer.collectFiles(from: [root]).map(\.lastPathComponent)), ["original.nef", "returned.tif"])
        XCTAssertTrue(Importer.collectFiles(from: [privateSource, generation, privateSource.deletingLastPathComponent()]).isEmpty)
    }

    func testRefreshReplacesBothCachedPreviewSizesForSameAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("edited.tif"), io = HDRImageIO()
        try io.writeTIFF(HDRImage(width: 64, height: 64, rgb: Array(repeating: 0.1, count: 64*64*3)), to: source)
        let cache = PreviewCache(rootURL: root.appendingPathComponent("Previews"))
        let scheduler = PreviewScheduler(cache: cache)
        scheduler.refresh(for: 1, source: source); scheduler.waitUntilIdle()
        let old = try PreviewCache.Size.allCases.map { try Data(contentsOf: cache.url(for: 1, size: $0)) }
        try io.writeTIFF(HDRImage(width: 64, height: 64, rgb: Array(repeating: 0.7, count: 64*64*3)), to: source)
        scheduler.request(.thumbnail, for: 1, source: source)
        scheduler.request(.preview, for: 1, source: source)
        scheduler.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: cache.url(for: 1, size: .thumbnail)), old[0], "ordinary requests reuse cached data")
        scheduler.refresh(for: 1, source: source); scheduler.waitUntilIdle()
        for (index, size) in PreviewCache.Size.allCases.enumerated() {
            XCTAssertNotEqual(try Data(contentsOf: cache.url(for: 1, size: size)), old[index], "a saved result needs new pixels at both sizes")
        }
    }
}
