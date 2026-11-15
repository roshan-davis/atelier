import CoreImage
import XCTest
@testable import AtelierCore

/// The Remove tool's spots (AT-066): stored as settings, a source picked next to them, and
/// Heal and Clone drawn on the corrected photo.
final class SpotTests: XCTestCase {
    private typealias Spot = DevelopSettings.Spot
    private typealias Point = DevelopSettings.MaskPoint

    // MARK: Settings

    func testSpotsRoundTripAndOldSettingsLoadWithout() throws {
        var settings = DevelopSettings()
        settings.spots = [Spot(mode: .heal, points: [Point(x: 0.3, y: 0.4)], size: 0.05, feather: 40, opacity: 80,
                               offset: Point(x: 0.1, y: 0))]
        XCTAssertFalse(settings.isNeutral)
        let decoded = try DevelopSettings.decoded(from: try settings.encoded())
        XCTAssertEqual(decoded, settings)

        let old = try DevelopSettings.decoded(from: #"{"schemaVersion":3,"exposure":0.5}"#)
        XCTAssertEqual(old.spots, [])
        XCTAssertFalse(try old.encoded().contains("spots"), "settings without spots write nothing new")
    }

    func testASpotMissingFieldsTakesDefaults() throws {
        let json = #"{"schemaVersion":3,"spots":[{"points":[{"x":0.5,"y":0.5}]}]}"#
        let spot = try XCTUnwrap(DevelopSettings.decoded(from: json).spots.first)
        XCTAssertEqual(spot.mode, .heal)
        XCTAssertEqual(spot.size, Spot.defaultSize)
        XCTAssertEqual(spot.opacity, 100)
        XCTAssertEqual(spot.offset, Point(x: 0, y: 0))
    }

    func testPresetsNeverCarrySpots() {
        var photo = DevelopSettings()
        photo.spots = [Spot(mode: .clone, points: [Point(x: 0.2, y: 0.2)])]
        var look = DevelopSettings()
        look[.exposure] = 1
        look.spots = [Spot(mode: .heal, points: [Point(x: 0.8, y: 0.8)])]
        let preset = DevelopPreset(name: "Look", parts: Set(DevelopPreset.Part.allCases), settings: look)
        XCTAssertEqual(preset.applied(to: photo).spots, photo.spots)
    }

    // MARK: Source

    func testCandidatesClearTheSpotAndStayOnThePhoto() {
        let photo = CGSize(width: 3000, height: 2000)
        let spot = Spot(mode: .heal, points: [Point(x: 0.5, y: 0.5)], size: 0.02)
        let candidates = SpotSource.candidates(for: spot, photo: photo)
        XCTAssertEqual(candidates.count, 16)
        let bounds = spot.bounds(in: photo)
        for offset in candidates {
            let moved = spot.bounds(in: photo, offset: offset)
            XCTAssertFalse(moved.intersects(bounds), "the source must not overlap the spot")
            XCTAssertTrue(CGRect(origin: .zero, size: photo).contains(moved))
        }
        // In a corner, only sources toward the middle fit.
        let corner = Spot(mode: .heal, points: [Point(x: 0.01, y: 0.015)], size: 0.02)
        for offset in SpotSource.candidates(for: corner, photo: photo) {
            XCTAssertGreaterThanOrEqual(offset.x, 0)
            XCTAssertGreaterThanOrEqual(offset.y, 0)
        }
    }

    func testRankingPrefersASourceThatLooksLikeTheSurroundings() throws {
        let photo = CGSize(width: 1000, height: 1000)
        // Dark above y = 0.45, light below; the spot sits in the light half near the edge.
        let brightness: (Point) -> Double? = { $0.y < 0.45 ? 0.1 : 0.9 }
        let spot = Spot(mode: .heal, points: [Point(x: 0.5, y: 0.52)], size: 0.04)
        let best = try XCTUnwrap(SpotSource.ranked(for: spot, photo: photo, brightness: brightness).first)
        XCTAssertGreaterThanOrEqual(spot.center.y + best.y, 0.52, "the source should come from the light half")
        // Without the photo, the nearest candidate comes first.
        XCTAssertEqual(SpotSource.ranked(for: spot, photo: photo, brightness: nil),
                       SpotSource.candidates(for: spot, photo: photo))
    }

    func testNextSourceCyclesThroughTheRanking() {
        let photo = CGSize(width: 1000, height: 1000)
        let ranked = [Point(x: 0.1, y: 0), Point(x: 0, y: 0.1), Point(x: -0.1, y: 0)]
        XCTAssertEqual(SpotSource.next(after: ranked[0], in: ranked, photo: photo), ranked[1])
        XCTAssertEqual(SpotSource.next(after: ranked[2], in: ranked, photo: photo), ranked[0])
        XCTAssertEqual(SpotSource.next(after: Point(x: 0.4, y: 0.4), in: ranked, photo: photo), ranked[0])
    }

    func testStrokeHitTesting() {
        let photo = CGSize(width: 1000, height: 1000)
        let stroke = Spot(mode: .clone, points: [Point(x: 0.2, y: 0.5), Point(x: 0.6, y: 0.5)], size: 0.04,
                          offset: Point(x: 0, y: 0.2))
        XCTAssertTrue(stroke.contains(Point(x: 0.4, y: 0.51), photo: photo))
        XCTAssertFalse(stroke.contains(Point(x: 0.4, y: 0.6), photo: photo))
        XCTAssertTrue(stroke.sourceContains(Point(x: 0.4, y: 0.7), photo: photo))
    }

    // MARK: Rendering

    func testKernelsBuild() {
        XCTAssertTrue(SpotRenderer.kernelsAvailable)
    }

    /// Left half gray 0.2, right half 0.6, with a white speck at (40, 50) in the left half.
    private func speckled() -> CIImage {
        let left = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        // (40, 50) from the top left is y = 50 in Core Image's bottom-left space too (height 100).
        let speck = CIImage(color: .white).cropped(to: CGRect(x: 38, y: 48, width: 4, height: 4))
        return speck.composited(over: right.composited(over: left))
    }

    private static let sharedContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func value(_ image: CIImage, x: Int, yFromTop: Int, shared: Bool = false) -> Float {
        let context = shared ? Self.sharedContext
            : CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixel = [Float](repeating: 0, count: 4)
        let y = Int(image.extent.height) - 1 - yFromTop
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        return pixel[0]
    }

    func testCloneCopiesTheSourceOverTheSpot() {
        let image = speckled()
        // Spot on the speck (40, 50 of 200 x 100), source 20 px up: plain 0.2 gray.
        let spot = Spot(mode: .clone, points: [Point(x: 40.0 / 200, y: 0.5)], size: 12.0 / 200, feather: 0,
                        offset: Point(x: 0, y: -0.2))
        let out = SpotRenderer.apply([spot], to: image)
        XCTAssertEqual(out.extent, image.extent)
        XCTAssertEqual(value(image, x: 40, yFromTop: 50), 1, accuracy: 0.01)
        XCTAssertEqual(value(out, x: 40, yFromTop: 50), 0.2, accuracy: 0.02)
        XCTAssertEqual(value(out, x: 80, yFromTop: 50), 0.2, accuracy: 0.001, "outside the spot nothing changes")
    }

    func testHealMatchesTheSpotsSurroundings() {
        let image = speckled()
        // The source is in the lighter right half; Heal must still land on the left's 0.2.
        let spot = Spot(mode: .heal, points: [Point(x: 40.0 / 200, y: 0.5)], size: 12.0 / 200, feather: 0,
                        offset: Point(x: 0.4, y: 0))
        let healed = SpotRenderer.apply([spot], to: image)
        XCTAssertEqual(value(healed, x: 40, yFromTop: 50), 0.2, accuracy: 0.03)
        var clone = spot
        clone.mode = .clone
        XCTAssertEqual(value(SpotRenderer.apply([clone], to: image), x: 40, yFromTop: 50), 0.6, accuracy: 0.02,
                       "Clone copies the source as it is")
    }

    /// The pipeline hands spots its cached corrected photo. Rendering near the spot first and
    /// then far from it, in one context, must not smear the spot's area over the rest
    /// (Rosh, Nov 14, 2026: the whole photo turned into stretched blocks).
    func testACachedPhotoStaysWholeAroundTheSpot() {
        let cached = speckled().insertingIntermediate(cache: true)
        for mode in [Spot.Mode.heal, .clone] {
            let spot = Spot(mode: mode, points: [Point(x: 40.0 / 200, y: 0.5)], size: 12.0 / 200, feather: 0,
                            offset: Point(x: 0, y: -0.2))
            let out = SpotRenderer.apply([spot], to: cached)
            XCTAssertEqual(value(out, x: 40, yFromTop: 50, shared: true), 0.2, accuracy: 0.03)
            XCTAssertEqual(value(out, x: 180, yFromTop: 10, shared: true), 0.6, accuracy: 0.001, "\(mode)")
            XCTAssertEqual(value(out, x: 5, yFromTop: 95, shared: true), 0.2, accuracy: 0.001, "\(mode)")
        }
    }

    func testOpacityAndOrder() {
        let image = speckled()
        let half = Spot(mode: .clone, points: [Point(x: 40.0 / 200, y: 0.5)], size: 12.0 / 200, feather: 0, opacity: 50,
                        offset: Point(x: 0, y: -0.2))
        XCTAssertEqual(value(SpotRenderer.apply([half], to: image), x: 40, yFromTop: 50), 0.6, accuracy: 0.03)
    }

    func testVisualizeShowsTheSpeckOnWhite() {
        let view = SpotRenderer.visualize(speckled(), amount: 50)
        XCTAssertEqual(value(view, x: 70, yFromTop: 20), 1, accuracy: 0.01, "flat areas are white")
        XCTAssertLessThan(value(view, x: 38, yFromTop: 50), 0.5, "the speck's edge is dark")
    }
}
