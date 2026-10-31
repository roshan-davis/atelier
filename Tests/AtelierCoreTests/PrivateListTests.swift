import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// AT-023: private imports and collections hide their photos everywhere until shown.
final class PrivateListTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierPrivate-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private struct Library {
        let catalog: Catalog
        let shootGroup: Int64, publicGroup: Int64
        let raw: Int64, jpeg: Int64, portrait: Int64, landscape: Int64
    }

    /// "Shoot" holds a RAW+JPEG pair and a portrait; "Public" a landscape.
    private func makeLibrary() async throws -> Library {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        let open = workDir.appendingPathComponent("Public", isDirectory: true)
        for dir in [shoot, open] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for name in ["DSC_1.NEF", "DSC_1.JPG", "DSC_2.JPG"] { try makeJPEG(at: shoot.appendingPathComponent(name)) }
        try makeJPEG(at: open.appendingPathComponent("DSC_9.JPG"))
        let catalog = try Catalog()
        let importer = Importer(catalog: catalog, previews: nil)
        let first = await importer.run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        let second = await importer.run(sources: [open], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(first.failures + second.failures, [])
        let ids = Dictionary(uniqueKeysWithValues: (first.assetIDsBySource.merging(second.assetIDsBySource) { a, _ in a })
            .map { ($0.key.lastPathComponent, $0.value) })
        return Library(catalog: catalog,
                       shootGroup: try XCTUnwrap(first.importGroupId), publicGroup: try XCTUnwrap(second.importGroupId),
                       raw: try XCTUnwrap(ids["DSC_1.NEF"]), jpeg: try XCTUnwrap(ids["DSC_1.JPG"]),
                       portrait: try XCTUnwrap(ids["DSC_2.JPG"]), landscape: try XCTUnwrap(ids["DSC_9.JPG"]))
    }

    private func ids(_ catalog: Catalog, _ filter: LibraryFilter) throws -> Set<Int64> {
        Set(try catalog.assetRows(filter: filter).map(\.id))
    }

    func testPrivateImportHidesItsPhotosEverywhere() async throws {
        let lib = try await makeLibrary()
        let catalog = lib.catalog
        // The portrait is also in a collection with the landscape: private wins.
        let favourites = try XCTUnwrap(try catalog.createCollection(named: "Favourites").id)
        try catalog.addAssets([lib.portrait, lib.landscape], toCollection: favourites)
        try catalog.setImportGroup(lib.shootGroup, isPrivate: true)

        let hidden = LibraryFilter(groupsRawPairs: false)
        var shown = hidden
        shown.privacy = .shown
        XCTAssertEqual(try ids(catalog, hidden), [lib.landscape])
        XCTAssertEqual(try ids(catalog, shown), [lib.raw, lib.jpeg, lib.portrait, lib.landscape])
        var only = hidden
        only.privacy = .only
        XCTAssertEqual(try ids(catalog, only), [lib.raw, lib.jpeg, lib.portrait])
        var inCollection = hidden
        inCollection.scope = .collection(favourites)
        XCTAssertEqual(try ids(catalog, inCollection), [lib.landscape])
        // Search can't find them either.
        var search = hidden
        search.text = "DSC_2"
        XCTAssertEqual(try ids(catalog, search), [])
        // Clearing the filter keeps them hidden.
        XCTAssertFalse(search.cleared.showsPrivate)

        try await catalog.writer.read { db in
            XCTAssertEqual(try Catalog.fetchPhotoCount(db, groupingRawPairs: false), 1)
            XCTAssertEqual(try Catalog.fetchPhotoCount(db, groupingRawPairs: false, privacy: .shown), 4)
            let summaries = try Catalog.fetchImportGroupSummaries(db)
            XCTAssertEqual(summaries.map(\.id), [lib.publicGroup])
            let all = try Catalog.fetchImportGroupSummaries(db, privacy: .shown)
            XCTAssertEqual(Set(all.map(\.id)), [lib.shootGroup, lib.publicGroup])
            XCTAssertEqual(all.first { $0.id == lib.shootGroup }?.isPrivate, true)
            // The Shoot folder holds only private photos, so its name is hidden too.
            XCTAssertEqual(try Catalog.fetchFolders(db).map(\.displayName).filter { $0.contains("Shoot") }, [])
            XCTAssertEqual(try Catalog.fetchFolders(db, privacy: .shown).map(\.displayName).filter { $0.contains("Shoot") }.count, 1)
            XCTAssertEqual(try Catalog.fetchPrivateListCount(db), 1)
            // Show Only: just the private entry, its photos and its folder.
            XCTAssertEqual(try Catalog.fetchImportGroupSummaries(db, privacy: .only).map(\.id), [lib.shootGroup])
            XCTAssertEqual(try Catalog.fetchPhotoCount(db, groupingRawPairs: false, privacy: .only), 3)
            XCTAssertEqual(try Catalog.fetchFolders(db, privacy: .only).map(\.displayName).filter { !$0.contains("Shoot") }, [])
            XCTAssertEqual(try Catalog.fetchCollections(db, privacy: .only).map(\.name), [])
        }
        XCTAssertEqual(try catalog.privatePhotoIDs(among: [lib.portrait, lib.landscape]), [lib.portrait])

        try catalog.setImportGroup(lib.shootGroup, isPrivate: false)
        XCTAssertEqual(try ids(catalog, hidden).count, 4)
    }

    func testCopiesStacksAndPairSiblingsFollowThePrivatePhoto() async throws {
        let lib = try await makeLibrary()
        let catalog = lib.catalog
        let shoot = try XCTUnwrap(try catalog.createCollection(named: "Model shoot").id)
        // Only the RAW and the portrait are in the private collection, not the JPEG behind the RAW.
        try catalog.addAssets([lib.raw, lib.portrait], toCollection: shoot)
        let copy = try catalog.createVirtualCopy(of: lib.portrait)
        // Even taken out of the collection the copy follows its original.
        try catalog.removeAssets([copy], fromCollection: shoot)
        try catalog.setCollection(shoot, isPrivate: true)

        let hidden = LibraryFilter(groupsRawPairs: false)
        XCTAssertEqual(try ids(catalog, hidden), [lib.landscape])
        XCTAssertEqual(try catalog.privatePhotoIDs(among: [lib.jpeg, copy, lib.landscape]), [lib.jpeg, copy])
        try await catalog.writer.read { db in
            XCTAssertEqual(try Catalog.fetchCollections(db).map(\.name), [])
            XCTAssertEqual(try Catalog.fetchCollections(db, privacy: .shown).map(\.name), ["Model shoot"])
        }
    }

    func testCollectionSetsCantBePrivate() throws {
        let catalog = try Catalog()
        let set = try catalog.writer.write { db -> Int64 in
            var record = PhotoCollection(name: "Sets", isSet: true)
            try record.insert(db)
            return try XCTUnwrap(record.id)
        }
        try catalog.setCollection(set, isPrivate: true)
        try catalog.writer.read { db in
            XCTAssertEqual(try Catalog.fetchPrivateListCount(db), 0)
        }
    }

    private func makeJPEG(at url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
