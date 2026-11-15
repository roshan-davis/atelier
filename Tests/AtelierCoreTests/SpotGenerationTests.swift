import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import AtelierCore

/// The Remove tool's Generative AI spots (AT-066 step 4): their settings, what is sent to
/// ComfyUI, and how the generated fill is drawn. ComfyUI itself isn't run here.
final class SpotGenerationTests: XCTestCase {
    typealias Spot = DevelopSettings.Spot

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpotPatches-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func value(_ image: CIImage, x: Int, yFromTop: Int) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        let y = Int(image.extent.height) - 1 - yFromTop
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        return Array(pixel.prefix(3))
    }

    private func gray(_ level: CGFloat, width: CGFloat = 160, height: CGFloat = 100) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat, size: Int) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    // MARK: Settings

    func testGenerativeAndPatchRoundTripAndOldSpotsDecode() throws {
        let patch = Spot.Patch(region: DevelopSettings.MaskRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                               mean: [0.2, 0.3, 0.4], seed: 7)
        var settings = DevelopSettings()
        settings.spots = [Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 0.2, y: 0.3)],
                               generative: true, patch: patch),
                          Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 0.6, y: 0.3)])]
        let json = try settings.encoded()
        let decoded = try DevelopSettings.decoded(from: json).spots
        XCTAssertEqual(decoded, settings.spots)
        XCTAssertEqual(decoded[0].patch, patch)
        // A spot without Generative AI writes neither key, so old catalogs and presets read the same.
        var plain = DevelopSettings()
        plain.spots = [settings.spots[1]]
        let plainJSON = try plain.encoded()
        XCTAssertFalse(plainJSON.contains("generative"))
        XCTAssertFalse(plainJSON.contains("patch"))
        let old = try DevelopSettings.decoded(from: #"{"schemaVersion":3,"spots":[{"mode":"contentAware","points":[{"x":0.5,"y":0.5}]}]}"#)
        XCTAssertEqual(old.spots.first?.generative, false)
        XCTAssertNil(old.spots.first?.patch)
    }

    // MARK: Drawing the generated fill

    /// A red patch over the whole 160 × 100 photo and a spot at (40, 50).
    private func redPatch(mean: Double, in store: SpotPatches) throws -> Spot {
        let patch = Spot.Patch(region: DevelopSettings.MaskRect(x: 0, y: 0, width: 1, height: 1),
                               mean: [mean, mean, mean], seed: 1)
        try store.save(solid(red: 0.8, green: 0.2, blue: 0.2, size: 32), id: patch.id, provenance: ["test": true])
        return Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 40.0 / 160, y: 0.5)],
                    size: 12.0 / 160, feather: 0, generative: true, patch: patch)
    }

    func testAGenerativeSpotShowsItsPatchOnlyOnTheSpot() throws {
        let store = SpotPatches(folder: folder)
        let spot = try redPatch(mean: 0.4, in: store)
        let out = SpotRenderer.apply([spot], to: gray(0.4), patches: store)
        let inside = value(out, x: 40, yFromTop: 50)
        XCTAssertEqual(inside[0], 0.8, accuracy: 0.01)
        XCTAssertEqual(inside[1], 0.2, accuracy: 0.01)
        XCTAssertEqual(value(out, x: 120, yFromTop: 20)[0], 0.4, accuracy: 0.001, "outside the spot nothing changes")
    }

    func testThePatchFollowsALaterExposureChange() throws {
        let store = SpotPatches(folder: folder)
        // Made when the area averaged 0.4; the photo is now twice as bright.
        let spot = try redPatch(mean: 0.4, in: store)
        let out = SpotRenderer.apply([spot], to: gray(0.8), patches: store)
        let inside = value(out, x: 40, yFromTop: 50)
        XCTAssertEqual(inside[0], 1.6, accuracy: 0.03)
        XCTAssertEqual(inside[1], 0.4, accuracy: 0.02)
    }

    func testAMissingPatchFileFallsBackToContentAware() throws {
        let store = SpotPatches(folder: folder)
        var spot = try redPatch(mean: 0.4, in: store)
        spot.patch?.id = UUID()
        let image = CIImage(color: .white).cropped(to: CGRect(x: 38, y: 48, width: 4, height: 4)).composited(over: gray(0.4))
        let fills = SpotFills(context: CIContext(), waits: true)
        let out = SpotRenderer.apply([spot], to: image, fills: fills, upstream: 1, patches: store)
        XCTAssertEqual(value(out, x: 40, yFromTop: 50)[0], 0.4, accuracy: 0.03, "the speck is filled from around it")
    }

    func testAPatchIsIgnoredWhenGenerativeIsOff() throws {
        let store = SpotPatches(folder: folder)
        var spot = try redPatch(mean: 0.4, in: store)
        spot.generative = false
        let out = SpotRenderer.apply([spot], to: gray(0.4), patches: store)
        XCTAssertEqual(value(out, x: 40, yFromTop: 50)[0], 0.4, accuracy: 0.05)
    }

    // MARK: What is sent

    func testTheInputCoversTheSpotWithItsBrushAsTheHole() throws {
        let spot = Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 0.5, y: 0.5)], size: 0.05,
                        generative: true)
        let input = try XCTUnwrap(SpotGeneration.prepare(spot, on: gray(0.4, width: 800, height: 600), context: context))
        // The region holds the spot with room around it, inside the photo.
        let region = input.region
        XCTAssertLessThan(region.x, 0.5 - 0.025)
        XCTAssertGreaterThan(region.x + region.width, 0.5 + 0.025)
        XCTAssertGreaterThanOrEqual(region.x, 0)
        XCTAssertLessThanOrEqual(region.y + region.height, 1.0001)
        XCTAssertEqual(input.image.width, input.mask.width)
        XCTAssertEqual(input.image.height, input.mask.height)
        XCTAssertEqual(input.image.width, Int((region.width * 800).rounded()))
        for channel in input.mean { XCTAssertEqual(channel, 0.4, accuracy: 0.01) }
        // White at the spot, black in the corner.
        let box = try XCTUnwrap(AIImaging.bounds(of: input.mask))
        let center = CGPoint(x: (0.5 - region.x) * 800, y: (0.5 - region.y) * 600)
        XCTAssertTrue(box.contains(center))
        XCTAssertGreaterThan(box.width, 40, "the brush (40 px across) and a little more")
        XCTAssertLessThan(box.width, 56)
    }

    func testTheSpotsBeforeItAreInTheInput() throws {
        let session = try XCTUnwrap(makeSession())
        var settings = DevelopSettings()
        let first = Spot(mode: .clone, points: [DevelopSettings.MaskPoint(x: 0.5, y: 0.5)], size: 0.05,
                         offset: DevelopSettings.MaskPoint(x: 0.3, y: 0))
        let second = Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 0.5, y: 0.5)], size: 0.05,
                          generative: true)
        settings.spots = [first, second]
        XCTAssertNotNil(session.imageUnderSpot(second.id, settings: settings))
        XCTAssertNil(session.imageUnderSpot(UUID(), settings: settings))
    }

    /// A session on a small gray TIFF.
    private func makeSession() -> DevelopSession? {
        let url = folder.appendingPathComponent("gray.tif")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, solid(red: 0.5, green: 0.5, blue: 0.5, size: 64), nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return DevelopRenderer.shared.session(for: url, maxPixelSize: nil)
    }
}
