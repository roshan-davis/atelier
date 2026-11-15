import CoreImage
import XCTest
@testable import AtelierCore

/// Content-Aware Remove's fill (AT-066 step 3).
final class ContentAwareFillTests: XCTestCase {
    private typealias Pixels = ContentAwareFill.Pixels

    /// A `size` × `size` image from `color(x, y)`, with a round hole of `radius` in the middle.
    private func image(size: Int, radius: Double, _ color: (Int, Int) -> Float) -> (Pixels, [Bool]) {
        var rgb = [Float](repeating: 0, count: size * size * 3)
        var hole = [Bool](repeating: false, count: size * size)
        let c = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let inHole = hypot(Double(x) + 0.5 - c, Double(y) + 0.5 - c) <= radius
                hole[y * size + x] = inHole
                // The hole holds something to remove: white.
                let v = inHole ? 1 : color(x, y)
                for k in 0..<3 { rgb[(y * size + x) * 3 + k] = v }
            }
        }
        return (Pixels(width: size, height: size, rgb: rgb), hole)
    }

    func testFlatAreaFillsWithItsColor() {
        let (pixels, hole) = image(size: 64, radius: 8) { _, _ in 0.3 }
        let out = ContentAwareFill.fill(pixels, hole: hole)
        for i in 0..<hole.count where hole[i] {
            XCTAssertEqual(out.rgb[i * 3], 0.3, accuracy: 0.001)
        }
        for i in 0..<hole.count where !hole[i] {
            XCTAssertEqual(out.rgb[i * 3], pixels.rgb[i * 3], "outside the hole nothing changes")
        }
    }

    func testStripesCarryOnThroughTheHole() {
        // Vertical stripes 4 px wide: every filled pixel takes its column's stripe.
        let stripe: (Int, Int) -> Float = { x, _ in (x / 4) % 2 == 0 ? 0.2 : 0.7 }
        let (pixels, hole) = image(size: 96, radius: 10, stripe)
        let out = ContentAwareFill.fill(pixels, hole: hole)
        var wrong = 0, total = 0
        for y in 0..<96 {
            for x in 0..<96 where hole[y * 96 + x] {
                total += 1
                if abs(out.rgb[(y * 96 + x) * 3] - stripe(x, y)) > 0.15 { wrong += 1 }
            }
        }
        XCTAssertLessThan(Double(wrong) / Double(total), 0.1, "\(wrong) of \(total) filled pixels off the stripes")
    }

    func testSameSeedSameFill() {
        let noise: (Int, Int) -> Float = { x, y in Float((x * 7919 + y * 104_729) % 97) / 97 }
        let (pixels, hole) = image(size: 64, radius: 9, noise)
        XCTAssertEqual(ContentAwareFill.fill(pixels, hole: hole, seed: 3), ContentAwareFill.fill(pixels, hole: hole, seed: 3))
    }

    func testNoHoleChangesNothing() {
        let (pixels, _) = image(size: 32, radius: 0) { x, _ in Float(x) / 32 }
        XCTAssertEqual(ContentAwareFill.fill(pixels, hole: [Bool](repeating: false, count: 32 * 32)), pixels)
    }

    // MARK: On the photo

    private func value(_ image: CIImage, x: Int, yFromTop: Int) -> Float {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixel = [Float](repeating: 0, count: 4)
        let y = Int(image.extent.height) - 1 - yFromTop
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        return pixel[0]
    }

    func testAContentAwareSpotRemovesTheSpeck() {
        // Gray 0.4 with a white speck at (40, 50) of 160 × 100.
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 100))
        let image = CIImage(color: .white).cropped(to: CGRect(x: 38, y: 48, width: 4, height: 4)).composited(over: gray)
        let spot = DevelopSettings.Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 40.0 / 160, y: 0.5)],
                                        size: 12.0 / 160, feather: 0)
        let fills = SpotFills(context: CIContext(), waits: true)
        let out = SpotRenderer.apply([spot], to: image, fills: fills, upstream: 1)
        XCTAssertEqual(value(image, x: 40, yFromTop: 50), 1, accuracy: 0.01)
        XCTAssertEqual(value(out, x: 40, yFromTop: 50), 0.4, accuracy: 0.03)
        XCTAssertEqual(value(out, x: 120, yFromTop: 20), 0.4, accuracy: 0.001, "outside the spot nothing changes")
        // Without fills (the editor before the fill is in) it shows Heal, which also clears it.
        XCTAssertEqual(value(SpotRenderer.apply([spot], to: image), x: 40, yFromTop: 50), 0.4, accuracy: 0.05)
    }

    func testOldSpotsAndVariationDecode() throws {
        let json = #"{"schemaVersion":3,"spots":[{"mode":"heal","points":[{"x":0.5,"y":0.5}]},{"mode":"contentAware","points":[{"x":0.2,"y":0.2}],"variation":2}]}"#
        let spots = try DevelopSettings.decoded(from: json).spots
        XCTAssertEqual(spots.map(\.mode), [.heal, .contentAware])
        XCTAssertEqual(spots.map(\.variation), [0, 2])
        var settings = DevelopSettings()
        settings.spots = [DevelopSettings.Spot(mode: .contentAware, points: [DevelopSettings.MaskPoint(x: 0.1, y: 0.1)])]
        XCTAssertFalse(try settings.encoded().contains("variation"), "variation 0 is not written")
    }
}
