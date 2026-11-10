import CoreGraphics
import Foundation
import XCTest
@testable import AtelierCore

/// Select People's skin from faces and mattes, on a drawn portrait (no Vision needed).
final class PeopleSkinTests: XCTestCase {
    private let width = 200, height = 150

    /// Sky-blue background; a person matte with a face (lit from the left), dark eyes, red lips,
    /// a neck, a gray shirt and a bare arm in shadow; a skin-colored patch on the background
    /// outside the person.
    private func portrait() -> (pixels: [UInt8], face: FaceShape, matte: [Float]) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var matte = [Float](repeating: 0, count: width * height)
        func set(_ x: Int, _ y: Int, _ c: (Int, Int, Int)) {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(c.0); pixels[i + 1] = UInt8(c.1); pixels[i + 2] = UInt8(c.2); pixels[i + 3] = 255
        }
        for y in 0..<height { for x in 0..<width { set(x, y, (110, 160, 215)) } }
        // Background patch the color of skin, away from the person.
        for y in 10..<22 { for x in 170..<185 { set(x, y, (222, 170, 138)) } }
        func person(_ x: Int, _ y: Int) -> Bool {
            let inFace = pow(Double(x - 80) / 22, 2) + pow(Double(y - 45) / 28, 2) <= 1
            let neck = x >= 72 && x < 88 && y >= 68 && y < 85
            let shirt = x >= 50 && x < 110 && y >= 85 && y < 150
            let arm = x >= 110 && x < 125 && y >= 90 && y < 140
            return inFace || neck || shirt || arm
        }
        for y in 0..<height {
            for x in 0..<width where person(x, y) {
                matte[y * width + x] = 1
                let shirt = x >= 50 && x < 110 && y >= 85
                if shirt {
                    set(x, y, (70, 80, 95))
                } else if x >= 110 {
                    set(x, y, (178, 134, 108)) // the arm, in shadow
                } else {
                    // Skin lit from the left: brighter on the left cheek.
                    let light = 1.05 - Double(x - 58) / 44 * 0.15
                    set(x, y, (min(255, Int(222 * light)), Int(170 * light), Int(138 * light)))
                }
            }
        }
        // A small skin-colored print on the shirt, not joined to any skin.
        for y in 128..<134 { for x in 92..<98 { set(x, y, (222, 170, 138)) } }
        // Eyes and lips.
        for y in 38..<42 { for x in 69..<76 { set(x, y, (40, 35, 35)) }; for x in 84..<91 { set(x, y, (40, 35, 35)) } }
        for y in 58..<62 { for x in 74..<87 { set(x, y, (175, 60, 70)) } }
        let outline = (0..<32).map { i -> CGPoint in
            let t = Double(i) / 32 * 2 * .pi
            return CGPoint(x: 80 + 22 * cos(t), y: 45 + 28 * sin(t))
        }
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
        }
        let face = FaceShape(box: CGRect(x: 58, y: 17, width: 44, height: 56), outline: outline,
                             features: [box(69, 38, 76, 42), box(84, 38, 91, 42), box(74, 58, 87, 62)])
        return (pixels, face, matte)
    }

    private func mean(_ values: [Float], _ xs: Range<Int>, _ ys: Range<Int>) -> Float {
        var sum: Float = 0
        for y in ys { for x in xs { sum += values[y * width + x] } }
        return sum / Float(xs.count * ys.count)
    }

    func testFaceSkinLeavesOutEyesAndLips() throws {
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte]))
        let face = found.values(.init(parts: [.faceSkin]))
        XCTAssertGreaterThan(mean(face, 64..<70, 46..<54), 0.8, "left cheek")
        XCTAssertGreaterThan(mean(face, 90..<96, 46..<54), 0.8, "right cheek, darker")
        XCTAssertLessThan(mean(face, 70..<75, 39..<41), 0.3, "eye")
        XCTAssertLessThan(mean(face, 77..<84, 59..<61), 0.3, "lips")
        XCTAssertLessThan(mean(face, 112..<123, 100..<130), 0.1, "the arm is body skin, not face")
    }

    func testBodySkinFollowsThePersonOnly() throws {
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte]))
        let body = found.values(.init(parts: [.bodySkin]))
        XCTAssertGreaterThan(mean(body, 75..<85, 74..<82), 0.7, "neck")
        XCTAssertGreaterThan(mean(body, 113..<122, 100..<130), 0.7, "arm in shadow")
        XCTAssertLessThan(mean(body, 60..<90, 100..<140), 0.1, "shirt")
        XCTAssertLessThan(mean(body, 93..<97, 129..<133), 0.1, "skin-colored speck on the shirt")
        XCTAssertLessThan(mean(body, 172..<183, 12..<20), 0.05, "skin-colored background")
        XCTAssertLessThan(mean(body, 64..<70, 46..<54), 0.2, "the face is Face Skin")
        // Both parts together cover face and arm.
        let both = found.values(.init())
        XCTAssertGreaterThan(mean(both, 64..<70, 46..<54), 0.8)
        XCTAssertGreaterThan(mean(both, 113..<122, 100..<130), 0.7)
    }

    func testNoMatteMeansNoBodySkin() throws {
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: []))
        XCTAssertEqual(mean(found.values(.init(parts: [.bodySkin])), 0..<width, 0..<height), 0, accuracy: 0.001)
        XCTAssertNil(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height, faces: [], mattes: []))
    }

    func testOtherPersonIsLeftOut() throws {
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte]))
        XCTAssertEqual(found.people.count, 1)
        let nobody = found.values(.init(person: 1))
        XCTAssertEqual(nobody.max() ?? 0, 0)
        XCTAssertNotNil(found.mask(.init()))
    }

    func testOutlineReachesAboveTheBrows() {
        let jaw = (0...16).map { i -> CGPoint in
            let t = Double(i) / 16 * .pi
            return CGPoint(x: 100 - 40 * cos(t), y: 100 + 50 * sin(t))
        }
        let brows = [CGPoint(x: 80, y: 80), CGPoint(x: 120, y: 80)]
        let outline = FaceShape.outline(jaw: jaw, brows: brows, box: CGRect(x: 60, y: 60, width: 80, height: 100))
        // Above the brows (y 80) by an eighth of the face's height: 80 - 12 = 68.
        XCTAssertEqual(outline.map(\.y).min()!, 68, accuracy: 0.5)
        XCTAssertEqual(outline.count, jaw.count + 15)
        // Jaw drawn right to left closes over the top too.
        let reversed = FaceShape.outline(jaw: jaw.reversed(), brows: brows, box: CGRect(x: 60, y: 60, width: 80, height: 100))
        XCTAssertEqual(reversed.map(\.y).min()!, 68, accuracy: 0.5)
    }

    func testPeopleSelectionCodingAndDefaults() throws {
        let component = DevelopSettings.MaskComponent(.people(.init(person: 2, parts: [.bodySkin, .faceSkin], feather: 30)))
        let data = try JSONEncoder().encode(component)
        let decoded = try JSONDecoder().decode(DevelopSettings.MaskComponent.self, from: data)
        XCTAssertEqual(decoded, component)
        XCTAssertEqual(decoded.kind, .people)
        guard case .people(let selection) = decoded.shape else { return XCTFail() }
        XCTAssertEqual(selection.parts, [.faceSkin, .bodySkin], "parts keep one order")
        // A part saved with nothing but its kind selects everyone's skin.
        let bare = try JSONDecoder().decode(DevelopSettings.MaskComponent.self, from: Data(#"{"kind":"people"}"#.utf8))
        XCTAssertEqual(bare.shape, .people(.init()))
    }
}
