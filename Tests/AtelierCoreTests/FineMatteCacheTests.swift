import Foundation
import XCTest
@testable import AtelierCore

/// Fine Edges' mattes shared across sessions (PR #153): Save reuses the editor's matte, waits for
/// one being found instead of finding it again, and only the last few are kept.
final class FineMatteCacheTests: XCTestCase {
    private func key(_ file: String = "/photos/a.nef", x: Int = 10) -> FineMatteCache.Key {
        FineMatteCache.Key(file: file, geometry: DevelopSettings.neutral.lensGeometryKey, model: .hairDetail,
                           x: x, y: 20, width: 100, height: 100, gridWidth: 256, gridHeight: 170)
    }

    func testAMatteFoundInTheBackgroundIsReusedWithoutRunningAgain() {
        let cache = FineMatteCache()
        let runs = Counter()
        XCTAssertEqual(cache.lookup(key()), .missing)
        let done = expectation(description: "found")
        XCTAssertTrue(cache.startIfIdle(key(), find: { runs.add(); return [0.5] }, done: { done.fulfill() }))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cache.lookup(key()), .found([0.5]))
        // Save (another session, same photo and square) gets it without running the model.
        XCTAssertEqual(cache.matte(for: key(), find: { runs.add(); return [0.9] }), [0.5])
        XCTAssertFalse(cache.startIfIdle(key(), find: { runs.add(); return [0.9] }, done: {}))
        XCTAssertEqual(runs.value, 1)
    }

    func testSaveWaitsForTheRunAlreadyGoingInsteadOfStartingASecond() {
        let cache = FineMatteCache()
        let runs = Counter()
        let release = DispatchSemaphore(value: 0)
        cache.startIfIdle(key(), find: { runs.add(); release.wait(); return [0.25] }, done: {})
        XCTAssertEqual(cache.lookup(key()), .pending)
        let saved = expectation(description: "Save got the matte")
        DispatchQueue.global().async {
            XCTAssertEqual(cache.matte(for: self.key(), find: { runs.add(); return [0.75] }), [0.25])
            saved.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(runs.value, 1, "one run of the model for both")
    }

    func testAFailedMatteIsRememberedAndOtherPhotosAreSeparate() {
        let cache = FineMatteCache()
        XCTAssertNil(cache.matte(for: key(), find: { nil }))
        XCTAssertEqual(cache.lookup(key()), .found(nil))
        XCTAssertEqual(cache.lookup(key("/photos/b.nef")), .missing)
        XCTAssertEqual(cache.lookup(key(x: 11)), .missing)
    }

    func testOnlyTheLastFewAreKept() {
        let cache = FineMatteCache(limit: 2)
        for x in 0..<3 { _ = cache.matte(for: key(x: x), find: { [Float(x)] }) }
        XCTAssertEqual(cache.lookup(key(x: 0)), .missing)
        XCTAssertEqual(cache.lookup(key(x: 2)), .found([2]))
        cache.removeAll()
        XCTAssertEqual(cache.lookup(key(x: 2)), .missing)
    }
}

final class SubjectMaskCacheTests: XCTestCase {
    func testSaveSeesTheSubjectTheEditorFound() throws {
        let cache = SubjectMaskCache(limit: 2)
        let key = SubjectMaskCache.Key(file: "/photos/a.nef", geometry: DevelopSettings.neutral.lensGeometryKey, box: nil)
        XCTAssertNil(cache.lookup(key), "not known yet")
        let mask = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage())
        cache.store(key, mask)
        XCTAssertTrue(cache.lookup(key)! === mask)
        var other = key
        other.file = "/photos/b.nef"
        cache.store(other, nil)
        XCTAssertNotNil(cache.lookup(other), "Vision found nothing: remembered")
        XCTAssertNil(cache.lookup(other)!, "as no mask")
        var third = key
        third.box = DevelopSettings.MaskRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        cache.store(third, mask)
        XCTAssertNil(cache.lookup(key), "only the last two are kept")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
