import XCTest
@testable import AtelierApp

/// AT-076 R2: the download state Depth and Fine Edges share.
@MainActor
final class ModelDownloadStateTests: XCTestCase {
    private final class Download: ModelDownloadState<String> {}

    func testADownloadReportsProgressAndEnds() async throws {
        let download = Download()
        var done = false
        download.startDownload("model", install: { progress in progress(0.5) }, finished: { done = true })
        XCTAssertEqual(download.downloading, "model")
        try await waitUntil { download.downloading == nil }
        XCTAssertTrue(done)
        XCTAssertNil(download.progress)
        XCTAssertNil(download.error)
    }

    func testAFailureShowsItsError() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "No network" } }
        let download = Download()
        download.startDownload("model", install: { _ in throw Refused() }, finished: {})
        try await waitUntil { download.downloading == nil }
        XCTAssertEqual(download.error, "No network")
    }

    /// An install that ignores Cancel and finishes anyway changes nothing, and doesn't clear a
    /// download started after the Cancel.
    func testNothingHappensAfterCancel() async throws {
        let download = Download()
        var finishedFirst = false
        let gate = AsyncStream<Void>.makeStream()
        download.startDownload("first", install: { _ in for await _ in gate.stream {} },
                               finished: { finishedFirst = true })
        download.cancel()
        XCTAssertNil(download.downloading)
        download.startDownload("second", install: { _ in try await Task.sleep(for: .seconds(30)) }, finished: {})
        gate.continuation.finish()  // the first install returns now, as if it ignored Cancel
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(finishedFirst)
        XCTAssertEqual(download.downloading, "second")
        download.cancel()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
