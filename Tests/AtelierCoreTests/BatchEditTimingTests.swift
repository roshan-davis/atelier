import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// AT-076 P2, measure first: a batch edit (Sync, a preset or Paste on a selection) on an on-disk
/// catalog, as the app opens it. Times the batch, counts its commits, and counts how often the
/// Grid's query (the Library's ValueObservation) runs because of it. Prints BATCHBENCH lines.
/// Opt-in (about a minute on a Mac): `ATELIER_BATCH_BENCH=1 swift test --filter BatchEditTimingTests`.
final class BatchEditTimingTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBatchBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testBatchEditTime() async throws {
        guard ProcessInfo.processInfo.environment["ATELIER_BATCH_BENCH"] == "1" else {
            throw XCTSkip("Set ATELIER_BATCH_BENCH=1 to time batch edits.")
        }
        let catalog = try Catalog(packageURL: workDir.appendingPathComponent("Bench.atelier", isDirectory: true))
        let ids = try await importPhotos(200, into: catalog)
        // Each photo starts with its own short edit history, as a shoot being worked on would.
        for id in ids {
            for step in 0..<20 {
                var settings = try catalog.developSettings(for: id)
                settings.exposure = Double(step) / 20
                try catalog.saveDevelopSettings(settings, for: id, step: "Exposure")
            }
        }

        let commits = CommitCounter()
        catalog.writer.add(transactionObserver: commits, extent: .databaseLifetime)
        let gridRuns = Counter()
        let observation = ValueObservation.tracking { db -> Int in
            gridRuns.add()
            return try Catalog.fetchAssetRows(db, filter: LibraryFilter()).count
        }
        let cancellable = observation.start(in: catalog.writer, scheduling: .async(onQueue: DispatchQueue(label: "bench.grid")),
                                            onError: { XCTFail("\($0)") }, onChange: { _ in })
        defer { cancellable.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        for count in [10, 50, 200] {
            var preset = DevelopSettings.neutral
            preset.contrast = Double(count) / 4
            preset.shadows = 20
            commits.reset()
            gridRuns.reset()
            let began = Date()
            try catalog.applyDevelopSettings(preset, to: Array(ids.prefix(count)), step: "Sync Settings")
            let ms = Int((Date().timeIntervalSince(began) * 1000).rounded())
            try await Task.sleep(for: .seconds(1))
            print("BATCHBENCH photos=\(count) ms=\(ms) commits=\(commits.value) grid_query_runs=\(gridRuns.value)")
            XCTAssertEqual(try catalog.developSettings(for: ids[count - 1]).contrast, Double(count) / 4)
        }
    }

    private func importPhotos(_ count: Int, into catalog: Catalog) async throws -> [Int64] {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        for index in 0..<count {
            let url = shoot.appendingPathComponent(String(format: "DSC_%04d.JPG", index))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        return result.assetIDsBySource.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }.map(\.value)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

/// Counts committed transactions that changed something.
private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    private let counter = Counter()
    private var changed = false
    var value: Int { counter.value }
    func reset() { counter.reset() }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) { changed = true }
    func databaseDidCommit(_ db: Database) {
        if changed { counter.add() }
        changed = false
    }
    func databaseDidRollback(_ db: Database) { changed = false }
}
