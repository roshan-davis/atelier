import AppKit
import AtelierCore
import XCTest
@testable import AtelierApp
@testable import AtelierCore

/// The Lens Blur mode (AT-074) end to end on a checkerboard, with a stand-in depth model that
/// puts everything far away (so Lens Blur at 100 blurs the whole photo): the blur shows in the
/// mode only, goes when the mode closes (Rosh, Nov 16, 2026: closing kept the blur), also at
/// full size, never reaches the stored previews, and other tools close the mode.
@MainActor
final class DevelopLensBlurModeTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensBlurMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DepthMap.standIn = { image in
            let width = max(1, image.width / 8), height = max(1, image.height / 8)
            return DepthMap.Field(width: width, height: height, values: Array(repeating: 1, count: width * height))
        }
    }

    override func tearDown() async throws {
        DepthMap.standIn = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testBlurShowsOnlyInTheModeAndGoesWhenItCloses() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        try await waitFor(controller, "sharp before the mode") { $0 > 0.15 }

        controller.isLensBlurring = true
        try await waitFor(controller, "blurred in the mode") { $0 < 0.05 }

        controller.isLensBlurring = false
        try await waitFor(controller, "sharp after Close") { $0 > 0.15 }
    }

    func testFullSizeRenderFollowsTheMode() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        controller.wantsFullResolution = true
        try await waitFor(controller, "sharp full size before the mode", fullSize: true) { $0 > 0.15 }

        controller.isLensBlurring = true
        try await waitFor(controller, "blurred full size in the mode", fullSize: true) { $0 < 0.05 }

        controller.isLensBlurring = false
        try await waitFor(controller, "sharp full size after Close", fullSize: true) { $0 > 0.15 }
    }

    func testBeforeInTheModeIsThePhotoWithoutTheBlur() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        controller.isLensBlurring = true
        try await waitFor(controller, "blurred in the mode") { $0 < 0.05 }
        controller.showingBefore = true
        try await waitFor(controller, "Before is sharp") { $0 > 0.15 }
        controller.showingBefore = false
        try await waitFor(controller, "blurred again") { $0 < 0.05 }
    }

    func testStoredPreviewsNeverShowTheBlur() async throws {
        let (controller, previews) = try await openBlurredCheckerboard()
        let assetID = try XCTUnwrap(controller.assetID)
        controller.isLensBlurring = true
        try await waitFor(controller, "blurred in the mode") { $0 < 0.05 }
        // An edit in the mode is saved, and the photo's own previews are stored again.
        controller.set(.lensBlurAmount, to: 90)
        controller.flushSave()
        let url = previews.url(for: assetID, size: .preview)
        var contrast: Double?
        for _ in 0..<200 {
            if let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                contrast = Self.contrast(of: image)
                if let contrast, contrast > 0.15 { break }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(contrast ?? 0, 0.15, "The stored preview shows the blur")
    }

    func testOtherToolsCloseTheModeButRefineKeepsIt() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        controller.isLensBlurring = true
        controller.startLensBlurRefine()
        XCTAssertTrue(controller.isLensBlurring, "Refine opens inside the mode")
        controller.finishLensBlurRefine()
        XCTAssertTrue(controller.isLensBlurring)

        controller.isCropping = true
        XCTAssertFalse(controller.isLensBlurring, "Crop closes the mode")
        controller.isCropping = false

        controller.isLensBlurring = true
        controller.isMasking = true
        XCTAssertFalse(controller.isLensBlurring, "Masking closes the mode")
        controller.isMasking = false

        controller.isLensBlurring = true
        controller.isRemoving = true
        XCTAssertFalse(controller.isLensBlurring, "Remove closes the mode")
    }

    // MARK: Helpers

    /// A 512 px checkerboard of 4 px squares with Lens Blur applied at 100, opened in Develop.
    private func openBlurredCheckerboard() async throws -> (DevelopController, PreviewCache) {
        let url = folder.appendingPathComponent("Checks.png")
        let squares = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 4, "inputSharpness": 1,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        try CIContext().writePNGRepresentation(of: squares, to: url, format: .RGBA8, colorSpace: DevelopRenderer.sRGB)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(
            sources: [url], options: ImportOptions(buildPreviews: false))
        let assetID = try XCTUnwrap(result.importedAssetIDs.first)
        var settings = DevelopSettings.neutral
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100
        try catalog.saveDevelopSettings(settings, for: assetID)
        let previews = PreviewCache(rootURL: folder.appendingPathComponent("Previews"))
        let controller = DevelopController(catalog: catalog, previews: previews)
        controller.open(assetID)
        return (controller, previews)
    }

    /// Waits until the photo on screen (or the full-size image) has a contrast that `matches`.
    private func waitFor(_ controller: DevelopController, _ what: String, fullSize: Bool = false,
                         matches: (Double) -> Bool) async throws {
        var observed: Double?
        for _ in 0..<300 {
            let shown = controller.displayImage
            // Full size: only once the photo on screen is the full-size render.
            if fullSize, shown == nil || shown !== controller.fullImage {
                observed = nil
            } else if let image = shown?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                observed = Self.contrast(of: image)
                if let observed, matches(observed) { return }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Expected \(what); contrast was \(String(describing: observed)), mode \(controller.isLensBlurring)")
    }

    /// The mean difference between neighbouring pixels in the middle: about 0.25 for these 4 px
    /// black-and-white squares (a step every 4 px), near 0 once Lens Blur at 100 (13 px) smooths them.
    static func contrast(of image: CGImage) -> Double {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        // The middle 64 px of the image, at 1:1 when the image is at least that large.
        let x = CGFloat(image.width - size) / 2, y = CGFloat(image.height - size) / 2
        context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var total = 0.0
        for row in 0..<size {
            for column in 1..<size {
                total += abs(Double(data[row * size + column]) - Double(data[row * size + column - 1])) / 255
            }
        }
        return total / Double(size * (size - 1))
    }
}
