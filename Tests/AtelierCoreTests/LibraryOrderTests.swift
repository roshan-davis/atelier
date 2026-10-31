import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// The Filmstrip's Sort and Filter menus and the thumbnail status badges (AT-018).
final class LibraryOrderTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierOrder-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Three photos, B.jpg shot first, then C.jpg, then A.jpg; returned in that capture order.
    private func makeCatalog() async throws -> (Catalog, [Int64]) {
        for name in ["A", "B", "C"] { try makeJPEG(at: workDir.appendingPathComponent("\(name).jpg")) }
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        let offsets = ["B.jpg": 0.0, "C.jpg": 1.0, "A.jpg": 2.0]
        try await catalog.writer.write { db in
            for (url, id) in result.assetIDsBySource {
                try db.execute(sql: "UPDATE asset SET captureTime = ? WHERE id = ?",
                               arguments: [Date(timeIntervalSince1970: offsets[url.lastPathComponent]!), id])
            }
        }
        let ids = try catalog.assetRows(filter: LibraryFilter()).map(\.id)
        XCTAssertEqual(ids.count, 3)
        return (catalog, ids)
    }

    private func names(_ catalog: Catalog, _ filter: LibraryFilter) throws -> [String] {
        try catalog.assetRows(filter: filter).map(\.filename)
    }

    func testSortsByEachKeyBothWays() async throws {
        let (catalog, ids) = try await makeCatalog()
        XCTAssertEqual(try names(catalog, LibraryFilter()), ["B.jpg", "C.jpg", "A.jpg"])
        XCTAssertEqual(try names(catalog, LibraryFilter(ascending: false)), ["A.jpg", "C.jpg", "B.jpg"])
        XCTAssertEqual(try names(catalog, LibraryFilter(sort: .fileName)), ["A.jpg", "B.jpg", "C.jpg"])
        XCTAssertEqual(try names(catalog, LibraryFilter(sort: .fileName, ascending: false)), ["C.jpg", "B.jpg", "A.jpg"])

        // Rating: ties keep capture order.
        try catalog.setRating(5, for: [ids[2]])
        try catalog.setRating(3, for: [ids[1]])
        XCTAssertEqual(try names(catalog, LibraryFilter(sort: .rating, ascending: false)), ["A.jpg", "C.jpg", "B.jpg"])
        XCTAssertEqual(try names(catalog, LibraryFilter(sort: .rating)), ["B.jpg", "C.jpg", "A.jpg"])

        // Edit time: newest edit first when descending; unedited photos last.
        var settings = DevelopSettings()
        settings.exposure = 0.5
        try catalog.saveDevelopSettings(settings, for: ids[0])
        try await Task.sleep(for: .milliseconds(20))
        try catalog.saveDevelopSettings(settings, for: ids[2])
        XCTAssertEqual(try names(catalog, LibraryFilter(sort: .editTime, ascending: false)), ["A.jpg", "B.jpg", "C.jpg"])

        // Import order runs without error (all three came in together).
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(sort: .importOrder)).count, 3)
    }

    func testStatusBadgesAndEditedFilter() async throws {
        let (catalog, ids) = try await makeCatalog()
        var rows = try catalog.assetRows(filter: LibraryFilter())
        XCTAssertFalse(rows.contains { $0.hasEdits || $0.isCropped || $0.hasMasks || $0.isOffline })

        var exposure = DevelopSettings()
        exposure.exposure = 0.7
        try catalog.saveDevelopSettings(exposure, for: ids[0])
        var cropped = DevelopSettings()
        var crop = DevelopSettings.Crop()
        crop.width = 0.5
        cropped.crop = crop
        cropped.masks = [DevelopSettings.Mask(name: "Mask 1", components: [DevelopSettings.MaskComponent(.subject(.init()))])]
        try catalog.saveDevelopSettings(cropped, for: ids[1])
        // Reset back to neutral counts as unedited again.
        try catalog.saveDevelopSettings(exposure, for: ids[2])
        try catalog.saveDevelopSettings(.neutral, for: ids[2])

        rows = try catalog.assetRows(filter: LibraryFilter())
        XCTAssertEqual(rows.map(\.hasEdits), [true, true, false])
        XCTAssertEqual(rows.map(\.isCropped), [false, true, false])
        XCTAssertEqual(rows.map(\.hasMasks), [false, true, false])

        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(edited: true)).map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter(edited: false)).map(\.id), [ids[2]])

        try await catalog.writer.write { db in try db.execute(sql: "UPDATE volume SET isOnline = 0") }
        XCTAssertTrue(try catalog.assetRows(filter: LibraryFilter()).allSatisfy(\.isOffline))
    }

    func testClearedKeepsScopeAndOrder() {
        let filter = LibraryFilter(scope: .collection(3), minRating: 2, flag: .picked, colorLabel: .red, edited: true,
                                   text: "sea", groupsRawPairs: false, sort: .rating, ascending: false)
        XCTAssertTrue(filter.isFiltering)
        XCTAssertEqual(filter.cleared, LibraryFilter(scope: .collection(3), groupsRawPairs: false, sort: .rating, ascending: false))
        XCTAssertFalse(filter.cleared.isFiltering)
        XCTAssertEqual(filter.summary, ["Picked", "★2+", "Red", "Edited", "“sea”"])
        XCTAssertEqual(LibraryFilter(flag: Flag.none).summary, ["Unflagged"])
        XCTAssertEqual(filter.cleared.summary, [])
    }

    func testSessionKeepsSortAndEditedAndReadsOldSessions() throws {
        let filter = LibraryFilter(edited: false, sort: .fileName, ascending: false)
        let saved = SavedSession(filter: filter)
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(SavedSession.self, from: data)
        XCTAssertEqual(loaded.filter(base: LibraryFilter()), filter)

        // A session saved before sorting existed: the same keys without the new ones.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["edited", "sort", "descending"] { old[key] = nil }
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(restored.filter(base: LibraryFilter()), LibraryFilter())
    }

    private func makeJPEG(at url: URL, width: Int = 120, height: Int = 80) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
