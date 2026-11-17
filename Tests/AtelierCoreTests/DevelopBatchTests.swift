import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// AT-076 P2: `Catalog.updateDevelop` changes a batch of photos in one transaction.
final class DevelopBatchTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierDevelopBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testEachPhotoChangesOnItsOwnSettingsWithOneHistoryStep() async throws {
        let (catalog, ids) = try await makePhotos(3)
        var first = DevelopSettings.neutral
        first.exposure = 1
        try catalog.saveDevelopSettings(first, for: ids[0], step: "Exposure")

        let saved = try catalog.updateDevelop(ids, step: "Preset: Warm") { _, current in
            var warmed = current
            warmed.vibrance = 25
            return warmed
        }
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(try catalog.developSettings(for: ids[0]).exposure, 1, "built on the photo's own settings")
        XCTAssertEqual(try catalog.developSettings(for: ids[0]).vibrance, 25)
        XCTAssertEqual(try catalog.developHistory(for: ids[0]).steps.map(\.name), ["Import", "Exposure", "Preset: Warm"])
        XCTAssertEqual(try catalog.developHistory(for: ids[2]).steps.map(\.name), ["Import", "Preset: Warm"])
    }

    func testNilLeavesAPhotoAsItIs() async throws {
        let (catalog, ids) = try await makePhotos(2)
        var edited = DevelopSettings.neutral
        edited.contrast = 30
        let saved = try catalog.updateDevelop(ids, step: "Contrast") { id, _ in id == ids[0] ? edited : nil }
        XCTAssertEqual(Array(saved.keys), [ids[0]])
        XCTAssertEqual(try catalog.developSettings(for: ids[1]), .neutral)
        XCTAssertTrue(try catalog.developHistory(for: ids[1]).steps.isEmpty)
    }

    func testAFailureSavesNothing() async throws {
        let (catalog, ids) = try await makePhotos(3)
        struct Refused: Error {}
        var edited = DevelopSettings.neutral
        edited.contrast = 30
        XCTAssertThrowsError(try catalog.updateDevelop(ids, step: "Contrast") { id, _ in
            if id == ids[2] { throw Refused() }
            return edited
        })
        for id in ids { XCTAssertEqual(try catalog.developSettings(for: id), .neutral, "rolled back") }
    }

    func testABatchIsOneCommit() async throws {
        let (catalog, ids) = try await makePhotos(5)
        let commits = Commits()
        catalog.writer.add(transactionObserver: commits, extent: .databaseLifetime)
        var edited = DevelopSettings.neutral
        edited.contrast = 30
        try catalog.applyDevelopSettings(edited, to: ids, step: "Sync Settings")
        XCTAssertEqual(commits.count, 1)
        for id in ids { XCTAssertEqual(try catalog.developSettings(for: id).contrast, 30) }
    }

    private func makePhotos(_ count: Int) async throws -> (Catalog, [Int64]) {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        for index in 0..<count {
            let url = shoot.appendingPathComponent("DSC_\(index).JPG")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        return (catalog, result.assetIDsBySource.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }.map(\.value))
    }
}

private final class Commits: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var commits = 0
    private var changed = false
    var count: Int { lock.withLock { commits } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) { changed = true }
    func databaseDidCommit(_ db: Database) {
        if changed { lock.withLock { commits += 1 } }
        changed = false
    }
    func databaseDidRollback(_ db: Database) { changed = false }
}
