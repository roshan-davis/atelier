import AppKit
import AtelierCore
import XCTest
@testable import AtelierApp

/// AT-076 D1: Develop's tools are one state. Opening one closes the others, a picker closes
/// them (Lens Blur stays, its Refine doesn't), and Lens Blur's Refine is nested in Lens Blur.
final class DevelopToolTests: XCTestCase {
    @MainActor
    func testOneToolAtATimeAndRefineNestsInLensBlur() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Gray.png")
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try CIContext().writePNGRepresentation(of: source, to: url, format: .RGBA8, colorSpace: DevelopRenderer.sRGB)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [url], options: ImportOptions(buildPreviews: false))
        let assetID = try XCTUnwrap(result.importedAssetIDs.first)
        let develop = DevelopController(catalog: catalog,
                                        previews: PreviewCache(rootURL: folder.appendingPathComponent("Previews")))
        develop.open(assetID)

        develop.isCropping = true
        XCTAssertEqual(develop.tool, .crop)
        develop.isRemoving = true
        XCTAssertEqual(develop.tool, .remove)
        XCTAssertFalse(develop.isCropping)
        develop.isCropping = false  // not the open tool: nothing changes
        XCTAssertEqual(develop.tool, .remove)

        develop.compareMode = .sideBySide
        develop.isMasking = true
        XCTAssertEqual(develop.tool, .masking)
        XCTAssertEqual(develop.compareMode, .off, "opening a tool leaves the compare view")
        develop.picker = .whiteBalance
        XCTAssertNil(develop.tool, "a picker closes the tools")
        XCTAssertEqual(develop.picker, .whiteBalance)
        develop.isGuiding = true
        XCTAssertNil(develop.picker, "opening a tool puts the picker away")

        develop.isLensBlurring = true
        XCTAssertEqual(develop.tool, .lensBlur(refining: false))
        XCTAssertFalse(develop.isGuiding)
        develop.startLensBlurRefine()
        XCTAssertEqual(develop.tool, .lensBlur(refining: true))
        XCTAssertTrue(develop.isMasking)
        XCTAssertTrue(develop.isLensBlurring)
        XCTAssertEqual(develop.maskScope, .lensBlur)
        develop.picker = .lensFocus
        XCTAssertEqual(develop.tool, .lensBlur(refining: false), "the focus picker leaves Refine, not Lens Blur")
        XCTAssertEqual(develop.maskScope, .look)
        develop.startLensBlurRefine()
        develop.finishLensBlurRefine()
        XCTAssertEqual(develop.tool, .lensBlur(refining: false))

        develop.startLensBlurRefine()
        develop.isLensBlurring = false
        XCTAssertNil(develop.tool, "closing Lens Blur closes its Refine")
        XCTAssertEqual(develop.maskScope, .look)
        XCTAssertFalse(develop.isMasking)
    }
}
