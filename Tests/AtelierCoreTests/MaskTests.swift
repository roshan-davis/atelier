import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class MaskTests: XCTestCase {
    private typealias Mask = DevelopSettings.Mask
    private typealias Component = DevelopSettings.MaskComponent
    private typealias Point = DevelopSettings.MaskPoint

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierMasks-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testCropMappingRoundTrips() {
        let size = CGSize(width: 300, height: 200)
        var crop = DevelopSettings.Crop()
        crop.quarterTurns = 1
        crop.flipHorizontal = true
        crop.angle = 7
        crop.x = 0.1
        crop.y = 0.15
        crop.width = 0.7
        crop.height = 0.6
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 40), CGPoint(x: 299, y: 199)] {
            let output = crop.outputPoint(fromSource: point, sourceSize: size)
            let back = crop.sourcePoint(fromOutput: output, sourceSize: size)
            XCTAssertEqual(back.x, point.x, accuracy: 0.001)
            XCTAssertEqual(back.y, point.y, accuracy: 0.001)
        }
    }

    func testQuarterTurnMovesTopLeftToTopRight() {
        var crop = DevelopSettings.Crop()
        crop.quarterTurns = 1
        let output = crop.outputPoint(fromSource: .zero, sourceSize: CGSize(width: 300, height: 200))
        // The turned photo is 200 wide; the old top-left corner is now its top-right.
        XCTAssertEqual(output.x, 200, accuracy: 0.001)
        XCTAssertEqual(output.y, 0, accuracy: 0.001)
    }

    func testMaskSpaceMatchesTheView() {
        let space = MaskSpace(sourceSize: CGSize(width: 400, height: 200), crop: DevelopSettings.Crop(),
                              rect: CGRect(x: 10, y: 20, width: 200, height: 100), outputSize: CGSize(width: 400, height: 200))
        let view = space.viewPoint(Point(x: 0.5, y: 0.5))
        XCTAssertEqual(view.x, 110, accuracy: 0.001)
        XCTAssertEqual(view.y, 70, accuracy: 0.001)
        XCTAssertEqual(space.maskPoint(view).x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(space.viewLength(0.25), 50, accuracy: 0.001)

        let radial = space.radial(center: view, width: 40, height: 20, feather: 50)
        XCTAssertEqual(radial.radiusX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(radial.radiusY, 0.1, accuracy: 0.0001)
        XCTAssertEqual(radial.angle, 0, accuracy: 0.0001)
        let ellipse = space.ellipse(radial)
        XCTAssertEqual(ellipse.u.x - ellipse.center.x, 40, accuracy: 0.01)
        XCTAssertEqual(ellipse.v.y - ellipse.center.y, 20, accuracy: 0.01)
    }

    func testMasksSurviveSavingAndOldDocumentsHaveNone() throws {
        var settings = DevelopSettings()
        var mask = Mask(name: settings.nextMaskName(), components: [
            Component(.linear(.init(start: Point(x: 0.5, y: 0), end: Point(x: 0.5, y: 0.4)))),
            Component(.luminance(.init(low: 60, high: 100)), mode: .intersect),
        ])
        mask[.exposure] = -1.2
        mask[.dehaze] = 30
        mask.amount = 150
        settings.masks = [mask]
        XCTAssertEqual(settings.nextMaskName(), "Mask 2")
        XCTAssertFalse(settings.isNeutral)

        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?.effective(.exposure) ?? 0, -1.8, accuracy: 0.0001)
        XCTAssertTrue(try DevelopSettings.decoded(from: #"{"schemaVersion":2,"exposure":0.5}"#).masks.isEmpty)

        // A mask from a newer version that can't be read leaves the rest of the settings alone.
        let future = try DevelopSettings.decoded(from: #"{"exposure":0.5,"masks":[{"components":[{"kind":"sky"}]}]}"#)
        XCTAssertEqual(future.exposure, 0.5)
        XCTAssertTrue(future.masks.isEmpty)
    }

    func testPresetsLeaveMasksOutUnlessChosen() {
        var source = DevelopSettings()
        source.masks = [Mask(name: "Mask 1", components: [Component(.subject(.init()))])]
        source.exposure = 1
        let look = DevelopPreset(name: "Look", settings: source)
        XCTAssertTrue(look.applied(to: .neutral).masks.isEmpty)
        let withMasks = DevelopPreset(name: "Masks", parts: [.masks], settings: source)
        XCTAssertEqual(withMasks.applied(to: .neutral).masks, source.masks)
    }

    func testLuminanceRangeWeight() {
        let range = DevelopSettings.LuminanceRange(low: 40, high: 60, smoothness: 0)
        XCTAssertEqual(range.weight(at: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(range.weight(at: 0.1), 0, accuracy: 0.0001)
        let soft = DevelopSettings.LuminanceRange(low: 40, high: 60, smoothness: 100)
        XCTAssertGreaterThan(soft.weight(at: 0.3), 0)
        XCTAssertLessThan(soft.weight(at: 0.3), 1)
    }

    func testBrushPaintsAndErases() throws {
        let paint = DevelopSettings.MaskStroke(points: [Point(x: 0.2, y: 0.5), Point(x: 0.8, y: 0.5)], size: 0.2, feather: 0)
        let erase = DevelopSettings.MaskStroke(points: [Point(x: 0.5, y: 0.5)], size: 0.1, feather: 0, erases: true)
        let image = try XCTUnwrap(DevelopRenderer.brushMask([paint, erase], width: 100, height: 100))
        XCTAssertGreaterThan(try gray(image, x: 30, y: 50), 0.9)
        XCTAssertLessThan(try gray(image, x: 50, y: 50), 0.1)
        XCTAssertLessThan(try gray(image, x: 50, y: 10), 0.1)
    }

    func testLinearGradientBrightensOnlyItsSide() throws {
        let file = workDir.appendingPathComponent("gray.jpg")
        try makeJPEG(at: file, gray: 0.35)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
        var settings = DevelopSettings()
        // Full effect at the top, gone by the middle.
        var mask = Mask(name: "Mask 1", components: [
            Component(.linear(.init(start: Point(x: 0.5, y: 0.1), end: Point(x: 0.5, y: 0.45)))),
        ])
        mask[.exposure] = 1.5
        settings.masks = [mask]
        let neutral = try XCTUnwrap(session.render(.neutral))
        let render = try XCTUnwrap(session.render(settings))
        XCTAssertGreaterThan(try luma(render, x: 32, y: 3), try luma(neutral, x: 32, y: 3) + 0.15)
        XCTAssertEqual(try luma(render, x: 32, y: 58), try luma(neutral, x: 32, y: 58), accuracy: 0.02)

        // Masks stay on the photo when it is turned: the top edge is now on the right.
        var turned = settings
        var crop = DevelopSettings.Crop()
        crop.quarterTurns = 1
        turned.crop = crop
        let turnedRender = try XCTUnwrap(session.render(turned))
        XCTAssertGreaterThan(try luma(turnedRender, x: 60, y: 32), try luma(turnedRender, x: 3, y: 32) + 0.15)

        // A hidden mask does nothing; an inverted one lands on the other side.
        settings.masks[0].isHidden = true
        XCTAssertEqual(try luma(XCTUnwrap(session.render(settings)), x: 32, y: 3), try luma(neutral, x: 32, y: 3), accuracy: 0.02)
        settings.masks[0].isHidden = false
        settings.masks[0].inverted = true
        let inverted = try XCTUnwrap(session.render(settings))
        XCTAssertGreaterThan(try luma(inverted, x: 32, y: 58), try luma(neutral, x: 32, y: 58) + 0.15)
    }

    func testRadialSubtractAndOverlay() throws {
        let file = workDir.appendingPathComponent("gray.jpg")
        try makeJPEG(at: file, gray: 0.35)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 64))
        var settings = DevelopSettings()
        let radial = DevelopSettings.RadialGradient(center: Point(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4, feather: 10)
        let hole = DevelopSettings.RadialGradient(center: Point(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.1, feather: 0)
        var mask = Mask(name: "Mask 1", components: [Component(.radial(radial)), Component(.radial(hole), mode: .subtract)])
        mask[.exposure] = -2
        settings.masks = [mask]
        let neutral = try XCTUnwrap(session.render(.neutral))
        let render = try XCTUnwrap(session.render(settings))
        // Darker in the ring, untouched in the hole and outside.
        XCTAssertLessThan(try luma(render, x: 32, y: 16), try luma(neutral, x: 32, y: 16) - 0.1)
        XCTAssertEqual(try luma(render, x: 32, y: 32), try luma(neutral, x: 32, y: 32), accuracy: 0.03)
        XCTAssertEqual(try luma(render, x: 1, y: 1), try luma(neutral, x: 1, y: 1), accuracy: 0.03)

        let overlay = try XCTUnwrap(session.render(settings, overlay: mask.id))
        let pixel = try rgb(overlay, x: 32, y: 16)
        XCTAssertGreaterThan(pixel.r, pixel.g + 0.1)
    }

    func testBrushReachesTheEndOfTheStroke() {
        // Mouse samples closer together than the dab spacing used to leave the end unpainted.
        let points = (0...40).map { CGPoint(x: Double($0) * 0.7, y: 0) }
        let dabs = DevelopRenderer.dabPositions(along: points, spacing: 2)
        XCTAssertEqual(dabs.last, points.last)
        XCTAssertGreaterThan(dabs.count, 12)
        for (a, b) in zip(dabs, dabs.dropFirst()) { XCTAssertLessThanOrEqual(b.x - a.x, 2.0001) }
    }

    func testMasksKeepTheirInBetweenValues() throws {
        // A 50% gray mask must stay 50% in linear light, or every feather looks hard.
        let gray = CGColorSpaceCreateDeviceGray()
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let mask = DevelopRenderer.rawMask(try XCTUnwrap(context.makeImage()))
        var pixel = [Float](repeating: 0, count: 4)
        DevelopRenderer.shared.context.render(mask, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                              format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        XCTAssertEqual(Double(pixel[0]), 0.5, accuracy: 0.02)
    }

    func testSelectObjectKeepsItsBoxAndOldSubjectsStayHard() throws {
        let box = DevelopSettings.MaskRect(Point(x: 0.6, y: 0.7), Point(x: 0.2, y: 0.3))
        XCTAssertEqual(box.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.4, accuracy: 0.0001)
        var settings = DevelopSettings()
        settings.masks = [Mask(name: "Mask 1", components: [Component(.subject(.init(box: box, feather: 35)))])]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?.components.first?.kind, .object)
        let old = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"subject"}]}]}"#)
        XCTAssertEqual(old.masks.first?.components.first?.shape, .subject(.init(feather: 0)))
    }

    // MARK: Helpers

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// Luma at a pixel, counted from the top left.
    private func luma(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let p = try rgb(image, x: x, y: y)
        return 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
    }

    private func gray(_ image: CGImage, x: Int, y: Int) throws -> Double {
        try rgb(image, x: x, y: y).g
    }

    private func makeJPEG(at url: URL, gray: Double) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
