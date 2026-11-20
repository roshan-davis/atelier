import CoreGraphics
import CoreImage
import XCTest
@testable import AtelierCore

final class CropGuideTests: XCTestCase {
    typealias Crop = DevelopSettings.Crop

    private func allPoints(_ lines: [[CGPoint]]) -> [CGPoint] { lines.flatMap { $0 } }

    private func assertInsideFrame(_ lines: [[CGPoint]], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for point in allPoints(lines) {
            XCTAssert(point.x >= -1e-9 && point.x <= 1 + 1e-9 && point.y >= -1e-9 && point.y <= 1 + 1e-9,
                      "\(message): \(point) is outside the frame", file: file, line: line)
        }
    }

    func testEveryGuideDrawsInsideTheFrameInEveryOrientation() {
        for guide in CropGuide.allCases {
            for aspect in [0.5, 2.0 / 3, 1, 1.5, 16.0 / 9, 3] {
                for orientation in 0..<guide.orientationCount {
                    let lines = guide.polylines(aspect: aspect, orientation: orientation)
                    XCTAssertFalse(lines.isEmpty, "\(guide) at \(aspect)")
                    XCTAssert(lines.allSatisfy { $0.count >= 2 }, "\(guide) has a line with one point")
                    assertInsideFrame(lines, "\(guide) at \(aspect), orientation \(orientation)")
                }
            }
        }
    }

    func testThirdsAndGoldenRatioLines() {
        let thirds = CropGuide.thirds.polylines(aspect: 1.5)
        XCTAssertEqual(thirds.count, 4)
        XCTAssertEqual(Set(thirds.map { $0[0].x }.filter { $0 > 0 }.map { ($0 * 1000).rounded() }), [333, 667])
        let golden = CropGuide.goldenRatio.polylines(aspect: 1.5)
        XCTAssertEqual(Set(golden.map { $0[0].x }.filter { $0 > 0 }.map { ($0 * 1000).rounded() }), [382, 618])
    }

    /// Grid cells are square on screen, whatever the frame's shape.
    func testGridCellsAreSquare() {
        let aspect = 1.5
        let lines = CropGuide.grid.polylines(aspect: aspect)
        let verticals = lines.filter { $0[0].x == $0[1].x }.map { Double($0[0].x) * aspect }.sorted()
        let horizontals = lines.filter { $0[0].y == $0[1].y }.map { Double($0[0].y) }.sorted()
        XCTAssertEqual(horizontals.count, 5)
        XCTAssertEqual(verticals[1] - verticals[0], horizontals[1] - horizontals[0], accuracy: 1e-9)
    }

    /// Diagonal's lines leave the corners at 45° on screen.
    func testDiagonalLinesAre45Degrees() {
        for aspect in [0.6, 1.5] {
            for line in CropGuide.diagonal.polylines(aspect: aspect) {
                let dx = Double(line[1].x - line[0].x) * aspect, dy = Double(line[1].y - line[0].y)
                XCTAssertEqual(abs(dx), abs(dy), accuracy: 1e-9)
            }
        }
    }

    /// Triangle: the perpendiculars meet the diagonal at right angles on screen; ⇧O mirrors it.
    func testTrianglePerpendiculars() {
        let aspect = 1.5
        for orientation in 0..<2 {
            let lines = CropGuide.triangle.polylines(aspect: aspect, orientation: orientation)
            XCTAssertEqual(lines.count, 3)
            let diagonal = lines[0]
            let ddx = Double(diagonal[1].x - diagonal[0].x) * aspect, ddy = Double(diagonal[1].y - diagonal[0].y)
            for line in lines.dropFirst() {
                let dx = Double(line[1].x - line[0].x) * aspect, dy = Double(line[1].y - line[0].y)
                XCTAssertEqual(dx * ddx + dy * ddy, 0, accuracy: 1e-9)
            }
        }
        XCTAssertNotEqual(CropGuide.triangle.polylines(aspect: aspect, orientation: 0)[0],
                          CropGuide.triangle.polylines(aspect: aspect, orientation: 1)[0])
    }

    /// The spiral is one unbroken curve that winds into a point, and its eight orientations put
    /// that point in four different places (two windings each).
    func testGoldenSpiralWindsIntoAnEye() {
        var eyes = Set<String>()
        var curves = Set<String>()
        for orientation in 0..<8 {
            let curve = CropGuide.goldenSpiral.polylines(aspect: 1.5, orientation: orientation)[0]
            XCTAssertGreaterThan(curve.count, 100)
            for (a, b) in zip(curve, curve.dropFirst()) {
                XCTAssertLessThan(hypot(b.x - a.x, b.y - a.y), 0.11, "the curve jumps")
            }
            let eye = curve.last!
            eyes.insert("\((eye.x * 10).rounded()),\((eye.y * 10).rounded())")
            curves.insert(curve.map { "\(($0.x * 100).rounded()),\(($0.y * 100).rounded())" }.joined(separator: ";"))
        }
        XCTAssertEqual(eyes.count, 4)
        XCTAssertEqual(curves.count, 8)
        // Orientation 0: the eye is right of and below center, near the golden section.
        let eye = CropGuide.goldenSpiral.polylines(aspect: 1.5)[0].last!
        XCTAssertEqual(eye.x, 0.72, accuracy: 0.02)
        XCTAssertEqual(eye.y, 0.72, accuracy: 0.02)
        // Out of range orientations wrap.
        XCTAssertEqual(CropGuide.goldenSpiral.polylines(aspect: 1.5, orientation: 9),
                       CropGuide.goldenSpiral.polylines(aspect: 1.5, orientation: 1))
    }

    func testAspectRatioOutlinesSkipTheFramesOwnShape() {
        let lines = CropGuide.aspectRatios.polylines(aspect: 1.5)
        XCTAssertEqual(lines.count, CropGuide.outlinedRatios.count - 1)
        XCTAssert(lines.allSatisfy { $0.count == 5 && $0.first == $0.last })
    }

    func testCycling() {
        var guide = CropGuide.grid
        var seen: [CropGuide] = []
        for _ in CropGuide.allCases {
            seen.append(guide)
            guide = guide.next
        }
        XCTAssertEqual(seen, CropGuide.allCases)
        XCTAssertEqual(guide, .grid)
    }

    /// The crop tool's render keeps only turns and flips, so dragging the frame or the angle
    /// asks for the same render (Rosh, Nov 20, 2026: the crop drag felt frozen).
    func testCropToolViewIgnoresTheFrameAndAngle() {
        var a = Crop()
        a.quarterTurns = 1
        a.flipHorizontal = true
        a.x = 0.1; a.y = 0.2; a.width = 0.5; a.height = 0.4; a.angle = 3; a.lockedAspect = 1.5
        var b = a
        b.x = 0.3; b.width = 0.6; b.angle = -7; b.lockedAspect = nil
        XCTAssertEqual(a.cropToolView, b.cropToolView)
        XCTAssertEqual(a.cropToolView.quarterTurns, 1)
        XCTAssertTrue(a.cropToolView.flipHorizontal)
        var turned = b
        turned.quarterTurns = 2
        XCTAssertNotEqual(a.cropToolView, turned.cropToolView)

        // And it renders the same picture as the tool did before (angle 0, uncropped).
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        var before = a
        before.angle = 0
        XCTAssertEqual(DevelopRenderer.applyGeometry(a.cropToolView, to: image, cropping: false).extent,
                       DevelopRenderer.applyGeometry(before, to: image, cropping: false).extent)
    }
}
