import CoreGraphics
import XCTest
@testable import AtelierCore

final class FlatSVGTests: XCTestCase {
    private let svg = """
    <svg viewBox="0 0 20 10" fill="none" xmlns="http://www.w3.org/2000/svg">
        <!-- A comment -->
        <rect width="20" height="10" fill="#204060"/>
        <path data-part="skin" d="M0 0H10V10H0Z" fill="#F00"/>
        <g transform="translate(10, 0)" data-part="hair">
            <polygon points="0,0 10,0 10,5 0,5" fill="#00ff00"/>
        </g>
        <circle cx="15" cy="7.5" r="1" fill="#0000FF" opacity="0.5"/>
        <path d="M0 9L20 9" stroke="#FFFFFF" stroke-width="0.5"/>
    </svg>
    """

    private func rgb(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let data = try XCTUnwrap(LookSample.pixels(of: image, width: image.width, height: image.height))
        let i = (y * data.width + x) * 4
        return (0..<3).map { Int(data.pixels[i + $0]) }
    }

    func testReadsShapesGroupsAndParts() throws {
        let drawing = try XCTUnwrap(FlatSVG(data: Data(svg.utf8)))
        XCTAssertEqual(drawing.viewBox, CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(drawing.shapes.count, 5)
        XCTAssertEqual(drawing.parts, ["skin", "hair"])
        // The stroked path inherits the drawing's fill="none", so it isn't filled.
        XCTAssertNil(drawing.shapes[4].fill)
        XCTAssertNotNil(drawing.shapes[4].stroke)
        // The group's translate moves the polygon to the right half.
        XCTAssertEqual(drawing.shapes[2].path.boundingBoxOfPath, CGRect(x: 10, y: 0, width: 10, height: 5))
    }

    func testDrawsInSVGOrientation() throws {
        let image = try XCTUnwrap(FlatSVG(data: Data(svg.utf8))?.image(width: 200))
        XCTAssertEqual(image.height, 100)
        XCTAssertEqual(try rgb(image, 50, 20), [255, 0, 0])
        XCTAssertEqual(try rgb(image, 150, 20), [0, 255, 0])
        XCTAssertEqual(try rgb(image, 120, 70), [0x20, 0x40, 0x60])
    }

    func testMaskShowsOnlyTheNamedParts() throws {
        let drawing = try XCTUnwrap(FlatSVG(data: Data(svg.utf8)))
        let mask = try XCTUnwrap(drawing.mask(parts: ["skin"], width: 200))
        let values = try XCTUnwrap(LookSample.focusValues(mask, width: 200, height: 100))
        XCTAssertEqual(values[20 * 200 + 50], 1, accuracy: 0.01)
        XCTAssertEqual(values[20 * 200 + 150], 0, accuracy: 0.01)
        // The white line across is not skin, so it covers the skin underneath.
        XCTAssertEqual(values[90 * 200 + 50], 0, accuracy: 0.01)
    }

    func testPathDataReadsRelativeAndCurveCommands() throws {
        let path = try XCTUnwrap(FlatSVG.pathData("m2 2h4v4c-1 1-3 1-4 0z"))
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 2, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 6, accuracy: 0.01)
        XCTAssertEqual(box.minY, 2, accuracy: 0.01)
        XCTAssertGreaterThan(box.maxY, 6)
        XCTAssertNil(FlatSVG.pathData("M0 0A5 5 0 0 1 10 10"))
    }
}
