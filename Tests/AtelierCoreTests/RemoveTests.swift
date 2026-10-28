import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class RemoveTests: XCTestCase {
    private var workDir: URL!
    private var trashDir: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierRemove-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        workDir = root.appendingPathComponent("Shoot", isDirectory: true)
        trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir.deletingLastPathComponent())
    }

    /// DSC_1.NEF + DSC_1.JPG (a pair) and DSC_2.JPG.
    private func importShoot() async throws -> (Catalog, raw: Int64, jpeg: Int64, single: Int64) {
        for name in ["DSC_1.NEF", "DSC_1.JPG", "DSC_2.JPG"] { try makeJPEG(at: workDir.appendingPathComponent(name)) }
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [workDir], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        let byName = Dictionary(uniqueKeysWithValues: result.assetIDsBySource.map { ($0.key.lastPathComponent, $0.value) })
        return (catalog, try XCTUnwrap(byName["DSC_1.NEF"]), try XCTUnwrap(byName["DSC_1.JPG"]),
                try XCTUnwrap(byName["DSC_2.JPG"]))
    }

    private func fakeTrash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: workDir.appendingPathComponent(name).path)
    }

    func testPlanHasACheckboxPerKindOfFile() async throws {
        let (catalog, raw, jpeg, single) = try await importShoot()
        let copy = try catalog.createVirtualCopy(of: raw)

        let plan = try catalog.removalPlan(for: try catalog.withPairSiblings([raw, single, copy]))
        XCTAssertEqual(Set(plan.files.map(\.assetID)), [raw, jpeg, single])
        XCTAssertEqual(plan.virtualCopies, [copy])
        XCTAssertEqual(plan.fileTypes.map(\.label), ["RAW (.NEF)", "JPEG (.JPG)"])
        XCTAssertEqual(plan.files.first { $0.assetID == raw }?.virtualCopyCount, 1)
        let jpegs = plan.files(of: [plan.fileTypes[1]])
        XCTAssertEqual(Set(jpegs.map(\.assetID)), [jpeg, single])
        XCTAssertTrue(plan.files.allSatisfy { $0.url != nil })
    }

    func testRemoveLeavesTheFiles() async throws {
        let (catalog, raw, jpeg, single) = try await importShoot()
        let copy = try catalog.createVirtualCopy(of: raw)
        let plan = try catalog.removalPlan(for: try catalog.withPairSiblings([raw]))

        // JPEG unchecked: only the RAW (and its virtual copy) leave; the JPEG now shows on its own.
        try catalog.removePhotos(plan.files(of: [plan.fileTypes[0]]).map(\.assetID))
        let rows = try catalog.assetRows(filter: LibraryFilter())
        XCTAssertEqual(Set(rows.map(\.id)), [jpeg, single])
        XCTAssertFalse(rows.contains { $0.id == copy })
        XCTAssertTrue(exists("DSC_1.NEF") && exists("DSC_1.JPG"))
    }

    func testDeleteFromDiskTrashesFilesAndTheirSidecar() async throws {
        let (catalog, raw, jpeg, single) = try await importShoot()
        try Data("<x:xmpmeta/>".utf8).write(to: workDir.appendingPathComponent("DSC_1.xmp"))
        let plan = try catalog.removalPlan(for: try catalog.withPairSiblings([raw]))

        // The RAW goes; the sidecar stays for the JPEG.
        var result = try catalog.deletePhotos(plan.files(of: [plan.fileTypes[0]]), trash: fakeTrash)
        XCTAssertEqual(result.trashed.map(\.assetID), [raw])
        XCTAssertFalse(exists("DSC_1.NEF"))
        XCTAssertTrue(exists("DSC_1.JPG") && exists("DSC_1.xmp"))
        XCTAssertNil(try catalog.detail(for: raw))

        // Then the JPEG, and the sidecar with it.
        result = try catalog.deletePhotos(try catalog.removalPlan(for: [jpeg]).files, trash: fakeTrash)
        XCTAssertEqual(result.trashed.map(\.assetID), [jpeg])
        XCTAssertFalse(exists("DSC_1.JPG") || exists("DSC_1.xmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent("DSC_1.xmp").path))
        XCTAssertEqual(try catalog.assetRows(filter: LibraryFilter()).map(\.id), [single])
    }

    func testFilesThatCantBeTrashedKeepTheirPhoto() async throws {
        let (catalog, _, _, single) = try await importShoot()
        struct NoTrash: LocalizedError { var errorDescription: String? { "The volume has no Trash." } }
        let files = try catalog.removalPlan(for: [single]).files

        let result = try catalog.deletePhotos(files) { _ in throw NoTrash() }
        XCTAssertEqual(result.notTrashed.map { $0.file.assetID }, [single])
        XCTAssertEqual(result.notTrashed.first?.reason, "The volume has no Trash.")
        XCTAssertNotNil(try catalog.detail(for: single))
        XCTAssertTrue(exists("DSC_2.JPG"))

        // A file that is already gone just leaves the catalog.
        try FileManager.default.removeItem(at: workDir.appendingPathComponent("DSC_2.JPG"))
        let missing = try catalog.deletePhotos(files, trash: fakeTrash)
        XCTAssertEqual(missing.missing.map(\.assetID), [single])
        XCTAssertNil(try catalog.detail(for: single))
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
