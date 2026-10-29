import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class TransformTests: XCTestCase {
    private let size = CGSize(width: 3000, height: 2000)

    private func angleFromVertical(_ a: CGPoint, _ b: CGPoint) -> Double {
        atan2(abs(Double(b.x - a.x)), abs(Double(b.y - a.y))) * 180 / .pi
    }

    private func angleFromHorizontal(_ a: CGPoint, _ b: CGPoint) -> Double {
        atan2(abs(Double(b.y - a.y)), abs(Double(b.x - a.x))) * 180 / .pi
    }

    func testMatrixInverseRoundTrip() throws {
        var settings = DevelopSettings()
        settings[.transformVertical] = -30
        settings[.transformHorizontal] = 20
        settings[.transformRotate] = 3
        settings[.transformAspect] = 25
        settings[.transformScale] = 110
        settings[.transformOffsetX] = 10
        let geometry = LensGeometry(settings: settings, size: size, focalLength35: 24)
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.7)] {
            let back = geometry.sourcePoint(fromOutput: geometry.outputPoint(fromSource: point))
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
        XCTAssertTrue(LensGeometry(settings: .neutral, size: size, focalLength35: 50).isIdentity)
    }

    func testNegativeVerticalWidensTheTop() {
        var settings = DevelopSettings()
        settings[.transformVertical] = -40
        let geometry = LensGeometry(settings: settings, size: size, focalLength35: 35)
        let tl = geometry.outputPoint(fromSource: CGPoint(x: 0, y: 0)), tr = geometry.outputPoint(fromSource: CGPoint(x: 1, y: 0))
        let bl = geometry.outputPoint(fromSource: CGPoint(x: 0, y: 1)), br = geometry.outputPoint(fromSource: CGPoint(x: 1, y: 1))
        XCTAssertGreaterThan(tr.x - tl.x, (br.x - bl.x) * 1.1)
        // The center stays put.
        let center = geometry.outputPoint(fromSource: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
    }

    /// Vertical and horizontal lines of a building, as a camera tilted up and turned sees them.
    private func tiltedLines(vertical: Double, rotate: Double = 0) -> [LineSegment] {
        var settings = DevelopSettings()
        settings[.transformVertical] = vertical
        settings[.transformRotate] = rotate
        let camera = LensGeometry(settings: settings, size: size, focalLength35: 28)
        var lines: [LineSegment] = []
        for x in [0.15, 0.35, 0.6, 0.85] {
            lines.append(LineSegment(start: camera.outputPoint(fromSource: CGPoint(x: x, y: 0.15)),
                                     end: camera.outputPoint(fromSource: CGPoint(x: x, y: 0.85))))
        }
        for y in [0.3, 0.7] {
            lines.append(LineSegment(start: camera.outputPoint(fromSource: CGPoint(x: 0.2, y: y)),
                                     end: camera.outputPoint(fromSource: CGPoint(x: 0.8, y: y))))
        }
        return lines
    }

    func testVerticalUprightMakesConvergingLinesParallel() throws {
        let lines = tiltedLines(vertical: 35, rotate: 2)
        // The verticals really converge before the correction.
        XCTAssertGreaterThan(angleFromVertical(lines[0].start, lines[0].end), 3)
        let upright = try XCTUnwrap(UprightSolver.solve(.vertical, lines: lines, size: size, focalLength35: 28))
        var settings = DevelopSettings()
        settings.upright = upright
        let geometry = LensGeometry(settings: settings, size: size, focalLength35: 28)
        for line in lines.prefix(4) {
            let a = geometry.outputPoint(fromSource: line.start), b = geometry.outputPoint(fromSource: line.end)
            XCTAssertLessThan(angleFromVertical(a, b), 0.3)
        }
        XCTAssertGreaterThan(upright.pitch, 5)
    }

    func testLevelOnlyRotates() throws {
        let lines = tiltedLines(vertical: 0, rotate: 3)
        let upright = try XCTUnwrap(UprightSolver.solve(.level, lines: lines, size: size, focalLength35: 35))
        XCTAssertEqual(upright.roll, -3, accuracy: 0.1)
        XCTAssertEqual(upright.pitch, 0)
        XCTAssertEqual(upright.yaw, 0)
    }

    func testGuidesSolveTheirOwnLines() throws {
        // Two leaning guides, as drawn along a painting's sides.
        let guides = [LineSegment(start: CGPoint(x: 0.3, y: 0.85), end: CGPoint(x: 0.33, y: 0.2)),
                      LineSegment(start: CGPoint(x: 0.72, y: 0.85), end: CGPoint(x: 0.69, y: 0.2))]
        let upright = try XCTUnwrap(UprightSolver.solve(.guided, lines: guides, size: size, focalLength35: 50))
        var settings = DevelopSettings()
        settings.upright = upright
        let geometry = LensGeometry(settings: settings, size: size, focalLength35: 50)
        for guide in guides {
            let a = geometry.outputPoint(fromSource: guide.start), b = geometry.outputPoint(fromSource: guide.end)
            XCTAssertLessThan(angleFromVertical(a, b), 0.3)
        }
        XCTAssertNil(UprightSolver.solve(.guided, lines: [], size: size, focalLength35: 50))
        XCTAssertNil(UprightSolver.solve(.vertical, lines: Array(guides.prefix(1)), size: size, focalLength35: 50))
    }

    func testGuidedWaitsForTwoGuides() {
        // As in Lightroom, one guide does not change the photo.
        let one = [LineSegment(start: CGPoint(x: 0.3, y: 0.85), end: CGPoint(x: 0.33, y: 0.2))]
        XCTAssertNil(UprightSolver.solve(.guided, lines: one, size: size, focalLength35: 50))
    }

    func testThreeAndFourGuidesAllEndStraight() throws {
        // A facade shot tilted up and to the side, with guides drawn a little imprecisely and a
        // focal length that does not match the lens, as Lightroom still straightens every guide.
        let tilted = Perspective(pitch: 12, yaw: -9, roll: 2, focal: LensGeometry.focal(24)).matrix
        let inverse = try XCTUnwrap(tilted.inverted)
        let hw = 0.5, hh = 1.0 / 3
        func photo(_ x: Double, _ y: Double) -> CGPoint {
            let p = inverse.apply(SIMD2(x, y))
            return CGPoint(x: p.x / (2 * hw) + 0.5, y: p.y / (2 * hh) + 0.5)
        }
        let verticals = [LineSegment(start: photo(-0.3, -0.25), end: photo(-0.28, 0.25)),
                         LineSegment(start: photo(0.3, -0.25), end: photo(0.33, 0.25))]
        let horizontals = [LineSegment(start: photo(-0.35, -0.2), end: photo(0.35, -0.22)),
                           LineSegment(start: photo(-0.35, 0.2), end: photo(0.35, 0.19))]
        for guides in [verticals + horizontals.prefix(1), verticals + horizontals] {
            let upright = try XCTUnwrap(UprightSolver.solve(.guided, lines: guides, size: size, focalLength35: 35))
            var settings = DevelopSettings()
            settings.upright = upright
            let geometry = LensGeometry(settings: settings, size: size, focalLength35: 35)
            for (index, guide) in guides.enumerated() {
                let a = geometry.outputPoint(fromSource: guide.start), b = geometry.outputPoint(fromSource: guide.end)
                let lean = index < 2 ? angleFromVertical(a, b) : angleFromHorizontal(a, b)
                XCTAssertLessThan(lean, 0.1, "guide \(index + 1) of \(guides.count)")
            }
        }
    }

    func testWholePhotoViewKeepsEveryCornerInFrame() {
        var settings = DevelopSettings()
        settings.upright = .init(mode: .guided, pitch: 18, yaw: -12, roll: 4)
        settings.showsWholePhoto = true
        let geometry = LensGeometry(settings: settings, size: size, focalLength35: 24)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
            let output = geometry.outputPoint(fromSource: corner)
            XCTAssertTrue((0...1).contains(output.x) && (0...1).contains(output.y), "\(corner) lands at \(output)")
        }
        // View only: never saved.
        var saved = settings
        saved.showsWholePhoto = false
        XCTAssertEqual(try settings.encoded(), try saved.encoded())
    }

    func testUprightWithoutShearStillDecodes() throws {
        // Settings saved before Guided had a slant.
        let json = #"{"mode":"guided","pitch":4,"yaw":-1,"roll":0.5,"guides":[]}"#
        let upright = try JSONDecoder().decode(DevelopSettings.Upright.self, from: Data(json.utf8))
        XCTAssertEqual(upright, .init(mode: .guided, pitch: 4, yaw: -1, roll: 0.5))
    }

    func testLineDetectorFindsDrawnLines() {
        let width = 400, height = 300
        let drawn = [(CGPoint(x: 100, y: 30), CGPoint(x: 112, y: 270)), (CGPoint(x: 150, y: 200), CGPoint(x: 370, y: 212))]
        var pixels = [Float](repeating: 0.2, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: x, y: y)
                for (a, b) in drawn where distance(p, a, b) < 1.6 { pixels[y * width + x] = 0.9 }
            }
        }
        let found = LineDetector.detect(pixels, width: width, height: height)
        for (a, b) in drawn {
            let expected = atan2(Double(b.y - a.y), Double(b.x - a.x))
            let match = found.contains { segment in
                let dx = Double(segment.end.x - segment.start.x) * Double(width)
                let dy = Double(segment.end.y - segment.start.y) * Double(height)
                var diff = abs(atan2(dy, dx) - expected).truncatingRemainder(dividingBy: .pi)
                if diff > .pi / 2 { diff = .pi - diff }
                return diff < 1.5 * .pi / 180 && (dx * dx + dy * dy).squareRoot() > 150
            }
            XCTAssertTrue(match, "no segment along \(a) to \(b); found \(found)")
        }
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let t = min(1, max(0, (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(Double(p.x) - (Double(a.x) + t * dx), Double(p.y) - (Double(a.y) + t * dy))
    }

    func testNewSettingsRoundTripAndStaySparse() throws {
        XCTAssertEqual(try DevelopSettings().encoded(), #"{"schemaVersion":3}"#)
        var settings = DevelopSettings()
        settings.profile = .appleNeutral
        settings.lensProfileCorrections = false
        settings.constrainCrop = true
        settings[.lensDistortion] = 12
        settings[.transformScale] = 95
        settings.upright = .init(mode: .guided, pitch: 4, yaw: -1, roll: 0.5,
                                 guides: [.init(start: .init(x: 0.1, y: 0.9), end: .init(x: 0.12, y: 0.1))])
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.isNeutral)
    }

    func testPresetPartsCarryLensAndTransform() {
        var look = DevelopSettings()
        look.profile = .appleNeutral
        look.upright = .init(mode: .vertical, pitch: 6)
        look[.lensVignette] = 30
        let defaults = DevelopPreset(name: "Look", settings: look).applied(to: .neutral)
        XCTAssertEqual(defaults.profile, .cameraMatching)
        XCTAssertNil(defaults.upright)
        let all = DevelopPreset(name: "All", parts: Set(DevelopPreset.Part.allCases), settings: look).applied(to: .neutral)
        XCTAssertEqual(all.profile, .appleNeutral)
        XCTAssertEqual(all.upright?.pitch, 6)
        XCTAssertEqual(all[.lensVignette], 30)
    }

    // MARK: Rendering

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        let pixels = CameraMatch.pixels(image) ?? []
        let i = (y * image.width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    func testWarpFillsEmptyEdgesAndConstrainCropRemovesThem() throws {
        XCTAssertNil(LensGeometry.kernelError)
        let renderer = DevelopRenderer()
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var settings = DevelopSettings()
        settings[.transformRotate] = 10
        let open = LensGeometry(settings: settings, size: red.extent.size, focalLength35: 35).apply(to: red)
        XCTAssertEqual(open.extent, red.extent)
        let openImage = try XCTUnwrap(renderer.cgImage(open, colorSpace: DevelopRenderer.sRGB))
        // Turning leaves the corners empty (gray); the middle is the photo.
        for (x, y) in [(2, 2), (297, 2), (2, 197), (297, 197)] {
            let corner = pixel(openImage, x: x, y: y)
            XCTAssertLessThan(abs(corner.0 - corner.1), 10, "corner \(x),\(y) \(corner)")
        }
        let middle = pixel(openImage, x: 150, y: 100)
        XCTAssertGreaterThan(middle.0, 200)
        XCTAssertLessThan(middle.1, 40)

        settings.constrainCrop = true
        let constrained = LensGeometry(settings: settings, size: red.extent.size, focalLength35: 35).apply(to: red)
        let constrainedImage = try XCTUnwrap(renderer.cgImage(constrained, colorSpace: DevelopRenderer.sRGB))
        for (x, y) in [(2, 2), (297, 2), (2, 197), (297, 197)] {
            let p = pixel(constrainedImage, x: x, y: y)
            XCTAssertGreaterThan(p.0, 200, "corner \(x),\(y) \(p)")
            XCTAssertLessThan(p.1, 40, "corner \(x),\(y) \(p)")
        }
    }

    /// Real camera files, when CI has downloaded some: whether Apple's RAW engine has lens
    /// corrections for them, and Upright Auto's result side by side with the original.
    func testSampleRAWsUpright() throws {
        guard let folder = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_RAWS"] else {
            throw XCTSkip("No sample RAW files")
        }
        let output = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_OUT"].map { URL(fileURLWithPath: $0) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .rawImage) == true }
        if files.isEmpty { throw XCTSkip("No sample RAW files downloaded") }
        for url in files {
            let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: 1200))
            let lines = session.lines(for: .neutral)
            var settings = DevelopSettings()
            settings.upright = UprightSolver.solve(.auto, lines: lines, size: session.sourceSize,
                                                   focalLength35: session.focalLength35)
            settings.constrainCrop = true
            print("UPRIGHT \(url.lastPathComponent): lens \(session.lensName ?? "-") focal35 \(session.focalLength35) lensCorrectionSupported \(session.lensCorrectionSupported) enabledByDefault \(CIRAWFilter(imageURL: url)?.isLensCorrectionEnabled ?? false) lines \(lines.count) upright \(String(describing: settings.upright))")
            let before = try XCTUnwrap(session.render(.neutral))
            let after = try XCTUnwrap(session.render(settings))
            XCTAssertEqual(after.width, before.width)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try writeSideBySide([before, after], lines: lines,
                                    to: output.appendingPathComponent("upright-\(url.deletingPathExtension().lastPathComponent).jpg"))
            }
        }
    }

    /// The images side by side, with the detected lines drawn on the first.
    private func writeSideBySide(_ images: [CGImage], lines: [LineSegment], to url: URL) throws {
        let height = 600
        let widths = images.map { $0.width * height / $0.height }
        let context = try XCTUnwrap(CGContext(data: nil, width: widths.reduce(0, +) + 20 * (images.count - 1),
                                              height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: DevelopRenderer.sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: height))
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width + 20
        }
        context.setStrokeColor(red: 0, green: 0.9, blue: 1, alpha: 1)
        context.setLineWidth(1.5)
        for line in lines {
            // Core Graphics draws with y up.
            context.move(to: CGPoint(x: line.start.x * CGFloat(widths[0]), y: (1 - line.start.y) * CGFloat(height)))
            context.addLine(to: CGPoint(x: line.end.x * CGFloat(widths[0]), y: (1 - line.end.y) * CGFloat(height)))
        }
        context.strokePath()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
