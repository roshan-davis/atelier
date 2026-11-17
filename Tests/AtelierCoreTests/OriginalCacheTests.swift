import Foundation
import XCTest
@testable import AtelierCore

/// AT-079c: remote originals are read once into a bounded cache on this Mac, used only while they
/// still match the source, let go oldest-opened first, and kept copies are never let go.
final class OriginalCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierOriginals-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("share"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cache(limit: Int64 = 1_000_000, free: Int64 = .max) throws -> OriginalCache {
        try OriginalCache(root: dir.appendingPathComponent("cache"), limit: limit, freeSpace: { free })
    }

    /// A source file of `size` bytes and its hash, as the import cataloged it.
    private func source(_ name: String, size: Int = 1000, byte: UInt8 = 7) throws -> (URL, String) {
        let url = dir.appendingPathComponent("share/\(name)")
        try Data(repeating: byte, count: size).write(to: url)
        return (url, try FileHasher.sha256(of: url))
    }

    func testStoredCopyIsUsedWhileTheSourceMatches() throws {
        let cache = try cache()
        let (url, hash) = try source("DSC_1.NEF")
        var seen: Int64 = 0
        let result = try cache.store(1, from: url, contentHash: hash, progress: { seen = $0 })
        guard case .stored(let copy) = result else { return XCTFail("not stored: \(result)") }
        XCTAssertEqual(seen, 1000)
        XCTAssertEqual(copy.pathExtension, "nef")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: url))
        XCTAssertEqual(cache.readyCopy(for: 1), copy)

        let used = try XCTUnwrap(try cache.copy(for: 1, contentHash: hash, source: OriginalCache.SourceInfo(url)))
        XCTAssertEqual(used.url, copy)
        XCTAssertTrue(used.checked)
        XCTAssertEqual(try cache.usage(), OriginalCache.Usage(cachedBytes: 1000, cachedCount: 1))
    }

    func testSourceUnreachableUsesTheCopyUnchecked() throws {
        let cache = try cache()
        let (url, hash) = try source("a.jpg")
        try cache.store(1, from: url, contentHash: hash)
        let used = try XCTUnwrap(try cache.copy(for: 1, contentHash: hash, source: nil))
        XCTAssertFalse(used.checked)
    }

    func testChangedSourceDropsAnUnkeptCopyAndKeepsAKeptOne() throws {
        let cache = try cache()
        let (a, hashA) = try source("a.jpg")
        let (b, hashB) = try source("b.jpg")
        try cache.store(1, from: a, contentHash: hashA)
        try cache.store(2, from: b, contentHash: hashB, pinned: true)
        let changed = OriginalCache.SourceInfo(size: 999, modified: Date())
        XCTAssertNil(try cache.copy(for: 1, contentHash: hashA, source: changed))
        XCTAssertNil(try cache.entry(for: 1))
        XCTAssertNil(try cache.copy(for: 2, contentHash: hashB, source: changed))
        XCTAssertNotNil(try cache.entry(for: 2), "a kept copy stays, set aside, until the new file is checked")
        XCTAssertNil(cache.readyCopy(for: 2))
    }

    func testAFileThatChangedSinceImportIsNotKept() throws {
        let cache = try cache()
        let (url, hash) = try source("a.jpg")
        try Data(repeating: 9, count: 1000).write(to: url)
        let result = try cache.store(1, from: url, contentHash: hash)
        guard case .changed(let newHash) = result else { return XCTFail("stored a changed file") }
        XCTAssertNotEqual(newHash, hash)
        XCTAssertNil(try cache.entry(for: 1))
        let partial = try FileManager.default.contentsOfDirectory(atPath: cache.root.appendingPathComponent("partial").path)
        XCTAssertEqual(partial, [])
    }

    func testOldestOpenedGoesFirstAndKeptCopiesNeverGo() throws {
        let cache = try cache(limit: 2500)
        var hashes: [Int64: String] = [:]
        for id in Int64(1)...3 {
            let (url, hash) = try source("\(id).jpg", byte: UInt8(id))
            hashes[id] = hash
            try cache.store(id, from: url, contentHash: hash, pinned: id == 1)
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Open 2 again so 3 is now the oldest-opened unkept copy.
        _ = try cache.copy(for: 2, contentHash: hashes[2]!, source: nil)
        let (url4, hash4) = try source("4.jpg", byte: 4)
        try cache.store(4, from: url4, contentHash: hash4)
        XCTAssertNotNil(try cache.entry(for: 1), "kept")
        XCTAssertNotNil(try cache.entry(for: 2))
        XCTAssertNil(try cache.entry(for: 3), "oldest-opened went")
        XCTAssertNotNil(try cache.entry(for: 4))
        XCTAssertEqual(try cache.usage(), OriginalCache.Usage(cachedBytes: 2000, cachedCount: 2, keptBytes: 1000, keptCount: 1))
    }

    func testAtMostAQuarterOfFreeSpace() throws {
        let cache = try cache(limit: 1_000_000, free: 2000)
        XCTAssertEqual(try cache.effectiveLimit(), 500)
        let (url, hash) = try source("big.jpg")
        try cache.store(1, from: url, contentHash: hash)
        // The copy just stored for the open photo stays even alone over the size.
        XCTAssertNotNil(try cache.entry(for: 1))
        XCTAssertEqual(try cache.effectiveLimit(), 750, "measured as if the cache were empty")
    }

    func testClearKeepsKeptCopiesUnlessAsked() throws {
        let cache = try cache()
        let (a, hashA) = try source("a.jpg")
        let (b, hashB) = try source("b.jpg")
        try cache.store(1, from: a, contentHash: hashA)
        try cache.store(2, from: b, contentHash: hashB)
        try cache.setKept([2], true)
        try cache.clear()
        XCTAssertNil(try cache.entry(for: 1))
        XCTAssertNotNil(try cache.entry(for: 2))
        try cache.clear(includingKept: true)
        XCTAssertEqual(try cache.usage(), OriginalCache.Usage())
        XCTAssertNil(cache.readyCopy(for: 2))
    }

    func testCancelledCopyLeavesNothing() throws {
        let cache = try cache()
        let (url, hash) = try source("a.jpg", size: 20_000_000)
        let expectation = expectation(description: "cancelled")
        let task = Task.detached {
            do {
                _ = try cache.store(1, from: url, contentHash: hash, shouldPause: { true })
            } catch is CancellationError {
                expectation.fulfill()
            } catch {
                XCTFail("\(error)")
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
        task.cancel()
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(try cache.entry(for: 1))
        let partial = try FileManager.default.contentsOfDirectory(atPath: cache.root.appendingPathComponent("partial").path)
        XCTAssertEqual(partial, [])
    }

    func testReadableURLPrefersACheckedCopy() throws {
        let cache = try cache()
        let (url, hash) = try source("a.jpg")
        try cache.store(42, from: url, contentHash: hash)
        let catalog = try Catalog()
        XCTAssertEqual(try catalog.readableURL(for: 42, cache: cache), cache.readyCopy(for: 42))
        XCTAssertNil(try catalog.readableURL(for: 43, cache: cache))
    }
}
