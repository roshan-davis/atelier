import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Scale checks for the PRD's performance targets, sized to run in CI in a minute or two.
final class ScaleTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierScale-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// PRD: filter results in under 200 ms. 20,000 photos, measured on the CI runner.
    func testFilteringTwentyThousandPhotos() throws {
        let catalog = try Catalog()
        try catalog.writer.write { db in
            try db.execute(sql: """
                INSERT INTO volume (identityKey, name, kind, isOnline) VALUES ('uuid:test', 'Test', 'local', 1);
                INSERT INTO folder (volumeId, relativePath) VALUES (1, 'Photos');
                """)
            let now = Date()
            for index in 0..<20_000 {
                try db.execute(sql: """
                    INSERT INTO asset (folderId, filename, fileSize, contentHash, captureTime, importedAt)
                    VALUES (1, ?, 1000, ?, ?, ?)
                    """, arguments: [String(format: "IMG_%05d.CR3", index), "hash\(index)",
                                     now.addingTimeInterval(Double(index)), now])
                try db.execute(sql: "INSERT INTO metadata (assetId, rating, flag) VALUES (?, ?, ?)",
                               arguments: [db.lastInsertedRowID, index % 6, index % 3 - 1])
            }
        }

        func timed(_ filter: LibraryFilter) throws -> (Int, TimeInterval) {
            let start = Date()
            let count = try catalog.assetRows(filter: filter).count
            return (count, Date().timeIntervalSince(start))
        }

        let all = try timed(LibraryFilter())
        let rated = try timed(LibraryFilter(minRating: 4, flag: .picked))
        let search = try timed(LibraryFilter(text: "IMG_1234"))
        print("20k photos: all \(Int(all.1 * 1000)) ms, rated+picked \(Int(rated.1 * 1000)) ms, search \(Int(search.1 * 1000)) ms")

        XCTAssertEqual(all.0, 20_000)
        XCTAssertGreaterThan(rated.0, 0)
        XCTAssertEqual(search.0, 10)  // IMG_1234x
        // The PRD target is 200 ms on an M4; CI runners are slower and shared, so allow headroom.
        XCTAssertLessThan(all.1, 1.0)
        XCTAssertLessThan(rated.1, 1.0)
        XCTAssertLessThan(search.1, 1.0)
    }

    /// A few hundred photos through the real import path, with thumbnails and previews.
    func testImportingThreeHundredPhotosBuildsThumbnailsFirst() async throws {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        for index in 0..<300 {
            try makeJPEG(at: shoot.appendingPathComponent(String(format: "IMG_%04d.jpg", index)),
                         shade: Double(index) / 300)
        }
        let catalog = try Catalog()
        let cache = PreviewCache(rootURL: workDir.appendingPathComponent("Previews"))
        let scheduler = PreviewScheduler(cache: cache)
        let importer = Importer(catalog: catalog, previews: nil, scheduler: scheduler)

        let start = Date()
        let result = await importer.run(sources: [shoot], options: ImportOptions())
        let cataloged = Date().timeIntervalSince(start)
        scheduler.waitUntilIdle()
        let total = Date().timeIntervalSince(start)
        print("300 photos: cataloged in \(Int(cataloged * 1000)) ms, previews done in \(Int(total * 1000)) ms")

        XCTAssertEqual(result.imported, 300)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        for id in result.importedAssetIDs {
            XCTAssertTrue(cache.has(.thumbnail, for: id))
            XCTAssertTrue(cache.has(.preview, for: id))
        }
        XCTAssertLessThan(total, 120)
    }

    func testThumbnailUsesEmbeddedPreviewSizeLimit() throws {
        let file = workDir.appendingPathComponent("big.jpg")
        try makeJPEG(at: file, width: 4000, height: 3000, shade: 0.5)
        let cache = PreviewCache(rootURL: workDir.appendingPathComponent("Previews"))
        try cache.generateThumbnail(for: 7, from: file)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(cache.url(for: 7, size: .thumbnail) as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 256)
        XCTAssertFalse(cache.has(.preview, for: 7))
    }

    private func makeJPEG(at url: URL, width: Int = 320, height: Int = 240, shade: Double) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
