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
    private let showsOverlay = UserDefaults.standard.bool(forKey: "masks.showOverlay")

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
        UserDefaults.standard.set(showsOverlay, forKey: "masks.showOverlay")
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

    /// Close shows the unblurred photo at once, not after the blurred renders still running
    /// (Rosh, Nov 16, 2026: "close still taking time to get to remove the blur"), and no blurred
    /// render lands on it afterwards.
    func testCloseTakesTheBlurAwayAtOnce() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        try await waitFor(controller, "sharp before the mode") { $0 > 0.15 }
        controller.isLensBlurring = true
        try await waitFor(controller, "blurred in the mode") { $0 < 0.05 }
        // A change in the mode, so a blurred render is on its way when Close comes.
        controller.set(.lensBlurAmount, to: 90)
        controller.isLensBlurring = false
        let shown = try XCTUnwrap(controller.displayImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(Self.contrast(of: shown), 0.15, "sharp the moment Close is clicked")
        XCTAssertNil(controller.lensBlurWork, "no progress line outside the mode")
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let later = try XCTUnwrap(controller.displayImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertGreaterThan(Self.contrast(of: later), 0.15, "a blurred render landed after Close")
        }
    }

    func testFullSizeRenderFollowsTheMode() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        controller.wantsFullResolution = true
        try await waitFor(controller, "sharp full size before the mode", fullSize: true) { $0 > 0.15 }

        controller.isLensBlurring = true
        try await waitFor(controller, "blurred full size in the mode", fullSize: true) { $0 < 0.05 }

        controller.isLensBlurring = false
        XCTAssertTrue(controller.displayImage === controller.fullImage, "the full-size photo is put back at once")
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
        // A Develop edit made while the mode renders the blur: the previews are stored again,
        // unblurred. (An edit to Lens Blur alone doesn't store them: they never show it.)
        controller.set(.exposure, to: 0.1)
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

    /// Cancel (and every way out but Save) puts the photo back as it was when the mode opened,
    /// history included (Rosh, Nov 16, 2026: reopening showed the cancelled values).
    func testCancelUndoesTheModesChanges() async throws {
        let (controller, catalog) = try await openBlurredCheckerboardWithCatalog()
        let assetID = try XCTUnwrap(controller.assetID)
        try await waitFor(controller, "sharp before the mode") { $0 > 0.15 }
        let steps = controller.history.steps.count
        controller.isLensBlurring = true
        controller.set(.lensBlurAmount, to: 40)
        controller.flushSave()
        XCTAssertTrue(controller.lensBlurHasChanges)
        controller.isLensBlurring = false
        XCTAssertEqual(controller.settings[.lensBlurAmount], 100, "Cancel puts the amount back")
        XCTAssertEqual(try catalog.developSettings(for: assetID)[.lensBlurAmount], 100, "and saves it")
        XCTAssertEqual(controller.history.steps.count, steps, "no history step from the cancelled edit")
        controller.isLensBlurring = true
        XCTAssertEqual(controller.settings[.lensBlurAmount], 100, "reopening shows the values from before")
    }

    /// After a Save the changes stay, whichever way the mode closes.
    func testSavedChangesStay() async throws {
        let (controller, _) = try await openBlurredCheckerboard()
        try await waitFor(controller, "sharp before the mode") { $0 > 0.15 }
        controller.isLensBlurring = true
        controller.set(.lensBlurAmount, to: 40)
        controller.keepLensBlurChanges()
        XCTAssertFalse(controller.lensBlurHasChanges)
        controller.isLensBlurring = false
        XCTAssertEqual(controller.settings[.lensBlurAmount], 40)
    }

    /// Show Overlay in Refine shows the Focus area even with nothing selected, and the photo under it
    /// without the blur, so it comes up without waiting for a blur render (Rosh, Nov 16, 2026:
    /// the overlay often didn't show, or showed late).
    func testOverlayInRefineSkipsTheBlur() async throws {
        var focus = DevelopSettings.Mask(name: "Focus",
                                         components: [.init(.radial(.init(center: .init(x: 0.1, y: 0.1),
                                                                           radiusX: 0.05, radiusY: 0.05)))])
        focus.lensBlurRole = .focus
        let (controller, _, _) = try await openBlurredCheckerboardParts(areas: [focus])
        controller.showMaskOverlay = false
        controller.isLensBlurring = true
        try await waitFor(controller, "blurred in the mode") { $0 < 0.05 }
        controller.startLensBlurRefine()
        controller.selectedMaskID = nil
        controller.showMaskOverlay = true
        try await waitFor(controller, "the overlay's photo without the blur") { $0 > 0.15 }
        controller.showMaskOverlay = false
        try await waitFor(controller, "blurred again once the overlay is off") { $0 < 0.05 }
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

    /// A photo that never had Lens Blur blurs as soon as the mode opens (Apply turned on), and
    /// Cancel takes that back; a photo whose Lens Blur was turned off keeps it off.
    func testTheModeAppliesLensBlurToAPhotoThatNeverHadIt() async throws {
        var never = DevelopSettings.neutral
        never[.lensBlurApply] = 0
        let (controller, _, catalog) = try await openBlurredCheckerboardParts(settings: never)
        let assetID = try XCTUnwrap(controller.assetID)
        try await waitFor(controller, "the photo") { $0 > 0.15 }
        XCTAssertEqual(controller.settings[.lensBlurApply], 0)
        controller.isLensBlurring = true
        XCTAssertEqual(controller.settings[.lensBlurApply], 1, "Apply is turned on")
        controller.set(.lensBlurAmount, to: 100)
        try await waitFor(controller, "blurred as the mode opens") { $0 < 0.05 }
        controller.isLensBlurring = false
        XCTAssertEqual(controller.settings[.lensBlurApply], 0, "Cancel turns it off again")
        XCTAssertEqual(try catalog.developSettings(for: assetID)[.lensBlurApply], 0)

        // Turned off by hand after using it (another Amount): it stays off.
        var used = never
        used[.lensBlurAmount] = 30
        let (other, _, _) = try await openBlurredCheckerboardParts(settings: used)
        other.isLensBlurring = true
        XCTAssertEqual(other.settings[.lensBlurApply], 0, "a photo that had Lens Blur keeps Apply off")
        other.isLensBlurring = false
    }

    // MARK: Helpers

    private func openBlurredCheckerboardWithCatalog() async throws -> (DevelopController, Catalog) {
        let (controller, _, catalog) = try await openBlurredCheckerboardParts()
        return (controller, catalog)
    }

    /// A 512 px checkerboard of 4 px squares with Lens Blur applied at 100, opened in Develop.
    private func openBlurredCheckerboard() async throws -> (DevelopController, PreviewCache) {
        let (controller, previews, _) = try await openBlurredCheckerboardParts()
        return (controller, previews)
    }

    private func openBlurredCheckerboardParts(areas: [DevelopSettings.Mask] = [], settings start: DevelopSettings? = nil) async throws
        -> (DevelopController, PreviewCache, Catalog) {
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
        settings.lensBlurAreas = areas
        if let start { settings = start }
        try catalog.saveDevelopSettings(settings, for: assetID)
        let previews = PreviewCache(rootURL: folder.appendingPathComponent("Previews"))
        let controller = DevelopController(catalog: catalog, previews: previews)
        controller.open(assetID)
        return (controller, previews, catalog)
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
