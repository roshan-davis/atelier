import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AtelierCore

/// The built-in MediaPipe parts model behind Select People: its resampling, and the model itself
/// on a real portrait.
final class PeoplePartsTests: XCTestCase {
    func testSampleAndPlaceKeepUniformValues() {
        let width = 40, height = 30
        let pixels: [UInt8] = (0..<(width * height * 4)).map { $0 % 4 == 0 ? 255 : 51 }
        let region = CGRect(x: 10, y: 5, width: 20, height: 20)
        let input = PeopleParts.sample(pixels: pixels, width: width, height: height, region: region)
        XCTAssertEqual(input.count, PeopleParts.size * PeopleParts.size * 3)
        XCTAssertEqual(input[0], 1, accuracy: 1e-5)
        XCTAssertEqual(input[1], 0.2, accuracy: 1e-5)

        let classes = PeopleParts.Class.allCases.count
        var chances = [Float](repeating: 0, count: PeopleParts.size * PeopleParts.size * classes)
        for i in 0..<(PeopleParts.size * PeopleParts.size) { chances[i * classes + PeopleParts.Class.clothes.rawValue] = 0.75 }
        let maps = PeopleParts.place(chances, region: region, width: width, height: height)
        XCTAssertEqual(maps.count, classes)
        let clothes = maps[PeopleParts.Class.clothes.rawValue]
        XCTAssertEqual(clothes[15 * width + 20], 0.75, accuracy: 1e-5, "inside the region")
        XCTAssertEqual(clothes[2 * width + 2], 0, "outside the region")
        XCTAssertEqual(maps[PeopleParts.Class.hair.rawValue].max() ?? 1, 0)
    }

    /// The model ships inside AtelierCore's resources and finds the person in a Help portrait
    /// (shares as Google's own TFLite runtime finds them: clothes 39%, face skin 6%, body skin
    /// 5%, hair 4%).
    func testBuiltInModelOnAPortrait() throws {
        XCTAssertNotNil(PeopleParts.packageURL(), "PeopleParts.mlpackage is missing from AtelierCore's resources")
        XCTAssertTrue(PeopleParts.isAvailable, "the parts model doesn't load")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/AtelierApp/Help/images/look-before-portrait.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = 256, height = 256
        let pixels = try XCTUnwrap(LookSample.pixels(of: image, width: width, height: height)).pixels
        let maps = try XCTUnwrap(PeopleParts.segment(pixels: pixels, width: width, height: height,
                                                     region: CGRect(x: 0, y: 0, width: width, height: height)))
        var counts = [Int](repeating: 0, count: maps.count)
        for i in 0..<(width * height) {
            let best = (0..<maps.count).max { maps[$0][i] < maps[$1][i] }!
            counts[best] += 1
        }
        func share(_ c: PeopleParts.Class) -> Double { Double(counts[c.rawValue]) / Double(width * height) }
        XCTAssertEqual(share(.clothes), 0.39, accuracy: 0.06)
        XCTAssertEqual(share(.faceSkin), 0.06, accuracy: 0.025)
        XCTAssertEqual(share(.bodySkin), 0.05, accuracy: 0.025)
        XCTAssertEqual(share(.hair), 0.04, accuracy: 0.02)
        // Chances add up to 1 (the model ends in a softmax).
        let total = maps.reduce(Float(0)) { $0 + $1[128 * width + 128] }
        XCTAssertEqual(total, 1, accuracy: 0.01)
    }
}
