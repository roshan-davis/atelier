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

    func testFacialFeaturePartsFromTheFaceOutline() throws {
        let drawn = portrait()
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
        }
        var face = drawn.face
        face.eyes = [FaceShape.Eye(outline: box(69, 38, 76, 42), pupil: CGPoint(x: 72.5, y: 40)),
                     FaceShape.Eye(outline: box(84, 38, 91, 42), pupil: CGPoint(x: 87.5, y: 40))]
        face.outerLips = box(74, 58, 87, 62)
        face.brows = [[CGPoint(x: 68, y: 34), CGPoint(x: 72, y: 33), CGPoint(x: 77, y: 34)]]
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [face], mattes: [drawn.matte]))
        let lips = found.values(.init(parts: [.lips]))
        XCTAssertGreaterThan(mean(lips, 76..<85, 59..<61), 0.6, "lips")
        XCTAssertLessThan(mean(lips, 64..<70, 46..<54), 0.05, "cheek is not lips")
        XCTAssertLessThan(mean(lips, 113..<122, 100..<130), 0.01, "arm is not lips")
        let iris = found.values(.init(parts: [.iris]))
        XCTAssertGreaterThan(iris[40 * width + 72], 0.2, "iris at the pupil")
        XCTAssertLessThan(mean(iris, 64..<70, 46..<54), 0.05, "cheek is not iris")
        // The drawn eyes are dark all over: no white of the eye to select.
        XCTAssertLessThan(mean(found.values(.init(parts: [.eyeSclera])), 69..<76, 38..<42), 0.1)
        XCTAssertGreaterThan(mean(found.values(.init(parts: [.eyebrows])), 69..<76, 33..<35), 0.4, "brow")
        // Face Skin and Lips ticked together cover the mouth with the face.
        let both = found.values(.init(parts: [.faceSkin, .lips]))
        XCTAssertGreaterThan(mean(both, 76..<85, 59..<61), 0.6)
        XCTAssertGreaterThan(mean(both, 64..<70, 46..<54), 0.8)
        // Nothing ticked selects nothing.
        XCTAssertEqual(found.values(.init(parts: [])).max() ?? 0, 0)
    }

    func testBodySkinFollowsThePersonOnly() throws {
        let drawn = portrait()
        // The wrist seed stands in for Vision's body pose.
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte],
                                                   seeds: [CGPoint(x: 117, y: 115)]))
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

    func testWarmClothesTouchingTheNeckAreLeftOut() throws {
        var drawn = portrait()
        // A knit scarf close to skin color across the top of the shirt, touching the neck.
        var noise: UInt32 = 12345
        for y in 85..<97 {
            for x in 55..<105 {
                noise = noise &* 1_103_515_245 &+ 12345
                let n = Int((noise >> 16) % 29) - 14
                let i = (y * width + x) * 4
                drawn.pixels[i] = UInt8(196 + n); drawn.pixels[i + 1] = UInt8(146 + n); drawn.pixels[i + 2] = UInt8(112 + n)
            }
        }
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte],
                                                   seeds: [CGPoint(x: 117, y: 115)]))
        let body = found.values(.init(parts: [.bodySkin]))
        XCTAssertGreaterThan(mean(body, 75..<85, 74..<82), 0.7, "neck")
        XCTAssertGreaterThan(mean(body, 113..<122, 100..<130), 0.7, "arm")
        XCTAssertLessThan(mean(body, 60..<100, 88..<95), 0.1, "scarf")
    }

    func testArmWithoutASeedIsLeftOut() throws {
        // Without a pose seed, a bare arm that doesn't touch the neck isn't guessed from color alone.
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte]))
        let body = found.values(.init(parts: [.bodySkin]))
        XCTAssertGreaterThan(mean(body, 75..<85, 74..<82), 0.7, "neck")
        XCTAssertLessThan(mean(body, 113..<122, 100..<130), 0.1, "arm")
    }

    func testNoMatteMeansNoBodySkin() throws {
        let drawn = portrait()
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: []))
        XCTAssertEqual(mean(found.values(.init(parts: [.bodySkin])), 0..<width, 0..<height), 0, accuracy: 0.001)
        XCTAssertNil(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height, faces: [], mattes: []))
    }

    /// With the parts model, skin comes from its classes, not from color: a skin-colored shirt the
    /// model calls clothes stays out of Body Skin, and Hair, Clothes and Entire Person are parts.
    func testModelPartsKeepClothesOutOfBodySkin() throws {
        var drawn = portrait()
        // A beige shirt, the color of the skin, touching the neck.
        for y in 85..<150 {
            for x in 50..<110 {
                let i = (y * width + x) * 4
                drawn.pixels[i] = 222; drawn.pixels[i + 1] = 170; drawn.pixels[i + 2] = 138
            }
        }
        var regions: [CGRect] = []
        let segment: (CGRect) -> [[Float]]? = { region in
            regions.append(region)
            var maps = [[Float]](repeating: [Float](repeating: 0, count: self.width * self.height),
                                 count: PeopleParts.Class.allCases.count)
            for y in 0..<self.height {
                for x in 0..<self.width {
                    let i = y * self.width + x
                    let c: PeopleParts.Class
                    if pow(Double(x - 80) / 22, 2) + pow(Double(y - 45) / 28, 2) <= 1 {
                        c = y < 24 ? .hair : .faceSkin
                    } else if (x >= 72 && x < 88 && y >= 68 && y < 85) || (x >= 110 && x < 125 && y >= 90 && y < 140) {
                        c = .bodySkin
                    } else if x >= 50 && x < 110 && y >= 85 {
                        c = .clothes
                    } else {
                        c = .background
                    }
                    maps[c.rawValue][i] = 1
                }
            }
            return maps
        }
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [drawn.face], mattes: [drawn.matte], segment: segment))
        XCTAssertEqual(regions.count, 1)
        XCTAssertTrue(regions[0].contains(CGPoint(x: 117, y: 130)), "the region covers the whole person")
        let body = found.values(.init(parts: [.bodySkin]))
        XCTAssertGreaterThan(mean(body, 75..<85, 74..<82), 0.7, "neck")
        XCTAssertGreaterThan(mean(body, 113..<122, 100..<130), 0.7, "arm")
        XCTAssertLessThan(mean(body, 60..<100, 95..<140), 0.1, "skin-colored shirt")
        XCTAssertGreaterThan(mean(found.values(.init(parts: [.clothes])), 60..<100, 95..<140), 0.8, "shirt is clothes")
        XCTAssertGreaterThan(mean(found.values(.init(parts: [.hair])), 74..<86, 19..<23), 0.5, "hair")
        let face = found.values(.init(parts: [.faceSkin]))
        XCTAssertGreaterThan(mean(face, 64..<70, 46..<54), 0.8, "cheek")
        XCTAssertLessThan(mean(face, 70..<75, 39..<41), 0.3, "eye still cut out")
        let whole = found.values(.init(parts: [.entirePerson]))
        XCTAssertGreaterThan(mean(whole, 60..<100, 95..<140), 0.8, "entire person")
        XCTAssertLessThan(mean(whole, 172..<183, 12..<20), 0.05, "not the background")
    }

    func testFaceMostlyCoveredIsStillFound() throws {
        // Big sunglasses and a scarf leave almost no clean skin inside the outline.
        let drawn = portrait()
        var face = drawn.face
        face.features = [[CGPoint(x: 56, y: 15), CGPoint(x: 104, y: 15), CGPoint(x: 104, y: 75), CGPoint(x: 56, y: 75)]]
        let found = try XCTUnwrap(PeopleSkin.build(pixels: drawn.pixels, width: width, height: height,
                                                   faces: [face], mattes: [drawn.matte]),
                                  "a face with too little clean skin is still a person")
        XCTAssertEqual(found.people.count, 1)
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
        XCTAssertEqual(selection.refine, 0)
        XCTAssertEqual(selection.grow, 0)
        // Ticking and unticking keeps one order and may leave nothing ticked.
        let none = DevelopSettings.PeopleSelection().setting(.faceSkin, false).setting(.bodySkin, false)
        XCTAssertEqual(none.parts, [])
        XCTAssertEqual(none.setting(.teeth, true).setting(.lips, true).parts, [.lips, .teeth])
        // Edge controls round-trip, and older parts decode with them off.
        let refined = DevelopSettings.MaskComponent(.subject(.init(box: nil, feather: 5, refine: 40, grow: -20)))
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.MaskComponent.self, from: JSONEncoder().encode(refined)), refined)
        let old = try JSONDecoder().decode(DevelopSettings.MaskComponent.self,
                                           from: Data(#"{"kind":"subject","selection":{"feather":20}}"#.utf8))
        XCTAssertEqual(old.shape, .subject(.init(feather: 20, refine: 0, grow: 0)))
    }

    func testPersonWithoutAFoundFaceGetsAHeadFromTheirOutline() {
        let width = 100, height = 100
        // Two people: one whose face was found, one (right) whose face wasn't.
        var found = [Float](repeating: 0, count: width * height)
        var missed = [Float](repeating: 0, count: width * height)
        for y in 20..<90 {
            for x in 10..<30 { found[y * width + x] = 1 }
            for x in 60..<80 { missed[y * width + x] = 1 }
        }
        let face = FaceShape(box: CGRect(x: 14, y: 20, width: 12, height: 14), outline: [])
        let people = PeopleSkin.facelessPeople(mattes: [found, missed], faces: [face], width: width, height: height)
        XCTAssertEqual(people.count, 1)
        guard let person = people.first else { return }
        XCTAssertEqual(person.extent, CGRect(x: 60, y: 20, width: 20, height: 70))
        XCTAssertEqual(person.head.midX, 69.5, accuracy: 0.5)
        XCTAssertEqual(person.head.minY, 20)
        XCTAssertTrue(person.extent.contains(CGPoint(x: person.head.midX, y: person.head.midY)))
    }

    func testTinyOutlinesAreNotPeople() {
        var speck = [Float](repeating: 0, count: 100 * 100)
        for y in 0..<5 { for x in 0..<5 { speck[y * 100 + x] = 1 } }
        XCTAssertTrue(PeopleSkin.facelessPeople(mattes: [speck], faces: [], width: 100, height: 100).isEmpty)
    }
}
