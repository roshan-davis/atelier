import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AtelierCore

final class LookMatchTests: XCTestCase {
    /// A 900 x 600 photo-like JPEG: a sky-to-ground gradient with colored patches and a gray ramp.
    private func samplePhoto() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("look-match-\(UUID().uuidString).jpg")
        let width = 900, height = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(srgbRed: 0.35, green: 0.55, blue: 0.8, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.5, blue: 0.35, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        let patches: [(Double, Double, Double)] = [(0.8, 0.25, 0.2), (0.9, 0.7, 0.3), (0.25, 0.6, 0.3),
                                                   (0.2, 0.3, 0.7), (0.85, 0.6, 0.5), (0.5, 0.3, 0.6)]
        for (i, color) in patches.enumerated() {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(x: 60 + i * 135, y: 330, width: 110, height: 110))
        }
        for i in 0..<12 {
            context.setFillColor(CGColor(gray: Double(i) / 11, alpha: 1))
            context.fill(CGRect(x: 60 + i * 65, y: 80, width: 60, height: 120))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sample(_ session: DevelopSession, _ settings: DevelopSettings) throws -> LookSample {
        try XCTUnwrap(session.renderSRGB(settings).flatMap { LookSample(image: $0) })
    }

    func testRecoversAKnownLook() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        var look = DevelopSettings()
        look.temperature = 5200
        look.tint = 12
        look.exposure = 0.5
        look.saturation = 30
        look.setPoints([.init(x: 0, y: 0.06), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.95)], for: .rgb)
        let reference = try sample(session, look)
        let plain = try sample(session, .neutral)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, reference: reference))
        let result = try sample(session, match.matched)
        let before = plain.distance(to: reference), after = result.distance(to: reference)
        print("LOOK MATCH known look: distance \(before) -> \(after); \(try match.matched.encoded())")
        XCTAssertLessThan(after, before * 0.4)
        XCTAssertGreaterThan(match.matched.exposure, 0)
        XCTAssertGreaterThan(match.matched.saturation, 0)
    }

    func testSameLookChangesLittle() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        let reference = try sample(session, .neutral)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, reference: reference))
        print("LOOK MATCH same look: \(try match.matched.encoded())")
        XCTAssertEqual(match.matched.exposure, 0, accuracy: 0.1)
        XCTAssertEqual(match.matched.saturation, 0, accuracy: 4)
        XCTAssertEqual(match.matched.tint, 0, accuracy: 4)
        XCTAssertEqual(match.matched.temperature ?? session.asShotTemperature, session.asShotTemperature,
                       accuracy: 250)
        XCTAssertLessThan(try sample(session, match.matched).distance(to: reference), 0.012)
    }

    func testSplitToningGoesToTheGradingWheels() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        var look = DevelopSettings()
        look[.gradeShadowsHue] = 200
        look[.gradeShadowsSat] = 40
        look[.gradeHighlightsHue] = 40
        look[.gradeHighlightsSat] = 35
        let reference = try sample(session, look)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, reference: reference,
                                                    options: LookMatchOptions(whiteBalance: false, tone: false)))
        print("LOOK MATCH split toning: \(try match.matched.encoded())")
        XCTAssertGreaterThan(match.matched[.gradeShadowsSat], 10)
        XCTAssertGreaterThan(match.matched[.gradeHighlightsSat], 10)
        func gap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        XCTAssertLessThan(gap(match.matched[.gradeShadowsHue], 200), 45)
        XCTAssertLessThan(gap(match.matched[.gradeHighlightsHue], 40), 45)
    }

    func testMidtoneTintGoesToTheMidtonesWheel() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        var look = DevelopSettings()
        look[.gradeShadowsHue] = 200
        look[.gradeShadowsSat] = 30
        look[.gradeMidtonesHue] = 45
        look[.gradeMidtonesSat] = 30
        let reference = try sample(session, look)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, reference: reference,
                                                    options: LookMatchOptions(whiteBalance: false, tone: false)))
        print("LOOK MATCH three-way: \(try match.matched.encoded())")
        XCTAssertGreaterThan(match.matched[.gradeMidtonesSat], 8)
        XCTAssertGreaterThan(match.matched[.gradeShadowsSat], 8)
        func gap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        XCTAssertLessThan(gap(match.matched[.gradeMidtonesHue], 45), 60)
        XCTAssertLessThan(gap(match.matched[.gradeShadowsHue], 200), 60)
    }

    /// A gray ramp from `low` to `high` (0 to 255), 256 steps wide.
    private func ramp(_ low: Double, _ high: Double) -> LookSample {
        var pixels: [UInt8] = []
        for _ in 0..<4 {
            for x in 0..<256 {
                let v = UInt8((low + (high - low) * Double(x) / 255).rounded())
                pixels += [v, v, v, 255]
            }
        }
        return LookSample(pixels: pixels, width: 256, height: 4)
    }

    func testToneCurveKeepsBlackAndWhiteUnlessTheReferenceIsFaded() throws {
        let photo = ramp(0, 255)
        let same = try XCTUnwrap(LookMatcher.toneCurve(photo: photo, reference: photo))
        for (i, y) in same.enumerated() { XCTAssertEqual(Double(y), Double(i) / 255, accuracy: 0.02) }

        // A bright reference with no dark tones is content, not a fade: black stays black.
        let bright = try XCTUnwrap(LookMatcher.toneCurve(photo: photo, reference: ramp(100, 255)))
        XCTAssertEqual(bright[0], 0)
        XCTAssertEqual(bright[255], 1)

        // A matte reference (lifted blacks, dimmed whites, dark tones present) is copied, within limits.
        let matte = try XCTUnwrap(LookMatcher.toneCurve(photo: photo, reference: ramp(30, 228)))
        XCTAssertGreaterThan(matte[0], 0.08)
        XCTAssertLessThanOrEqual(matte[0], 0.15)
        XCTAssertGreaterThanOrEqual(Double(matte[255]), 0.92 - 1e-6)
        XCTAssertLessThan(matte[255], 1)
        XCTAssertEqual(LookMatcher.curveXs.count, 7)
    }

    func testNeutralCastIgnoresColorfulAreas() {
        // 60% green foliage, 40% a slightly warm gray wall.
        var pixels: [UInt8] = []
        for i in 0..<100 { pixels += i < 60 ? [60, 160, 60, 255] : [140, 128, 116, 255] }
        let scene = LookSample(pixels: pixels, width: 10, height: 10)
        let wall = LookSample(pixels: [140, 128, 116, 255], width: 1, height: 1)
        XCTAssertEqual(scene.neutralAB.x, wall.midtoneAB.x, accuracy: 0.002)
        XCTAssertEqual(scene.neutralAB.y, wall.midtoneAB.y, accuracy: 0.002)
        XCTAssertLessThan(scene.midtoneAB.x, scene.neutralAB.x - 0.02)
    }

    func testHSLBandsFollowTheReference() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        var look = DevelopSettings()
        look[.hsl(.saturation, .green)] = 60
        look[.hsl(.luminance, .blue)] = -40
        look[.hsl(.hue, .red)] = 30
        let reference = try sample(session, look)
        let plain = try sample(session, .neutral)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, reference: reference,
                                                    options: LookMatchOptions(whiteBalance: false, tone: false)))
        let result = try sample(session, match.matched)
        let before = plain.distance(to: reference), after = result.distance(to: reference)
        print("LOOK MATCH HSL: distance \(before) -> \(after); \(try match.matched.encoded())")
        XCTAssertLessThan(after, before * 0.6)
        XCTAssertGreaterThan(match.matched[.hsl(.saturation, .green)], 10)
        XCTAssertLessThan(match.matched[.hsl(.luminance, .blue)], -5)
        XCTAssertGreaterThan(match.matched[.hsl(.hue, .red)], 5)
    }

    func testSlicedDistanceSeesColorNotLayout() {
        let width = 32, height = 16
        var left = [UInt8](), right = [UInt8](), warm = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                left += x < width / 2 ? [200, 60, 40, 255] : [40, 80, 200, 255]
                right += x < width / 2 ? [40, 80, 200, 255] : [200, 60, 40, 255]
                warm += x < width / 2 ? [230, 90, 30, 255] : [70, 90, 170, 255]
            }
        }
        let a = LookSample(pixels: left, width: width, height: height).projectedQuantiles()
        let b = LookSample(pixels: right, width: width, height: height).projectedQuantiles()
        let c = LookSample(pixels: warm, width: width, height: height).projectedQuantiles()
        // The same colors in other places are the same distribution.
        XCTAssertEqual(LookSample.slicedDistance(a, b), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(LookSample.slicedDistance(a, c), 0.01)
    }

    func testStrengthBlends() {
        var matched = DevelopSettings()
        matched.temperature = 4000
        matched.exposure = 1
        matched.saturation = 40
        matched.setPoints([.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)], for: .rgb)
        matched[.gradeShadowsHue] = 200
        matched[.gradeShadowsSat] = 40
        let match = LookMatch(base: .neutral, matched: matched, asShotTemperature: 6000)
        XCTAssertEqual(match.settings(strength: 0), .neutral)
        XCTAssertEqual(match.settings(strength: 1), matched)
        let half = match.settings(strength: 0.5)
        XCTAssertEqual(half.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.saturation, 20, accuracy: 1e-9)
        // Halfway in mireds: 1e6 / ((166.67 + 250) / 2) = 4800 K.
        XCTAssertEqual(half.temperature ?? 0, 4800, accuracy: 1)
        XCTAssertEqual(half.points(for: .rgb)[1].y, 0.55, accuracy: 1e-9)
        XCTAssertEqual(half[.gradeShadowsSat], 20, accuracy: 0.01)
        XCTAssertEqual(half[.gradeShadowsHue], 200, accuracy: 0.01)
        var withHSL = matched
        withHSL[.hsl(.saturation, .green)] = 40
        XCTAssertEqual(LookMatch(base: .neutral, matched: withHSL, asShotTemperature: 6000)
            .settings(strength: 0.25)[.hsl(.saturation, .green)], 10, accuracy: 1e-9)
    }

    func testAreaCarriesMostOfTheWeight() {
        // Left half red, right half blue.
        let width = 40, height = 20
        var pixels = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width { pixels += x < width / 2 ? [200, 40, 40, 255] : [40, 60, 200, 255] }
        }
        let whole = LookSample(pixels: pixels, width: width, height: height)
        let left = LookSample(pixels: pixels, width: width, height: height, area: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertGreaterThan(left.midtoneAB.x, whole.midtoneAB.x + 0.03)
        XCTAssertEqual(left.weight.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testGradeHueFollowsItsDirection() {
        for hue in [0, 45, 120, 200, 300] {
            let angle = LookMatcher.gradeDirections[hue]
            XCTAssertEqual(LookMatcher.gradeHue(towards: SIMD2(cos(angle), sin(angle))), Double(hue), accuracy: 3)
        }
    }

    // MARK: Phase 3: Protect Skin Tones and Subject & Background

    /// The sample photo's skin-colored patch (the fifth), as a face box: 0 to 1 from the top left.
    private let skinPatch = CGRect(x: 600.0 / 900, y: 160.0 / 600, width: 110.0 / 900, height: 110.0 / 600)

    func testSkinIsFoundInsideTheFace() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        let plain = try sample(session, .neutral)
        let skin = try XCTUnwrap(LookSkin(sample: plain, faces: [skinPatch]))
        XCTAssertGreaterThan(skin.pixels.count, 100)
        XCTAssertTrue(skin.isWithin(plain))
        XCTAssertTrue(skin.holds(plain))
        // A brighter render of the same skin is not held, though its hue and saturation barely move.
        var brighter = DevelopSettings()
        brighter.exposure = 0.5
        XCTAssertFalse(skin.holds(try sample(session, brighter)))
        XCTAssertNil(LookSkin(sample: plain, faces: []))
        // A face box over the blue sky finds no skin.
        XCTAssertNil(LookSkin(sample: plain, faces: [CGRect(x: 0.05, y: 0.02, width: 0.1, height: 0.1)]))
    }

    /// The skin masks are the Entire Face in one piece, softly edged: one base color with no
    /// holes, and the neck and hands with it when the parts model gives Body Skin.
    func testSkinMasksCoverTheEntireFaceAndBody() {
        XCTAssertEqual(LookSkin.maskSelection(bodySkin: false).parts, [.entireFace])
        XCTAssertEqual(LookSkin.maskSelection(bodySkin: true).parts, [.bodySkin, .entireFace])
        XCTAssertGreaterThan(LookSkin.maskSelection(bodySkin: true).feather, 0)
        XCTAssertEqual(LookSkin.eyesSelection.parts, [.eyeSclera, .iris])
    }

    /// Skin color is matched relative to brightness: a/b over lightness, per tone.
    func testSkinColorIsMeasuredRelativeToBrightness() throws {
        let width = 30, height = 10
        // Fury Road's drawn skin: shadows, midtones, highlights, side by side.
        let tones: [(UInt8, UInt8, UInt8)] = [(0x8F, 0x5E, 0x37), (0xCF, 0x99, 0x67), (0xF0, 0xC4, 0x96)]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let tone = tones[x / 10], i = (y * width + x) * 4
                pixels[i] = tone.0
                pixels[i + 1] = tone.1
                pixels[i + 2] = tone.2
            }
        }
        let sample = LookSample(pixels: pixels, width: width, height: height)
        let thirds = (0..<3).map { CGRect(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
        let skin = try XCTUnwrap(LookSkin(sample: sample, toneRegions: thirds))
        let relative = skin.relativeToneColors
        XCTAssertEqual(relative.count, 3)
        for k in 0..<3 {
            XCTAssertEqual(relative[k].x, skin.toneColors[k].x / skin.toneLightness[k], accuracy: 1e-9)
            XCTAssertEqual(relative[k].y, skin.toneColors[k].y / skin.toneLightness[k], accuracy: 1e-9)
            let measured = try XCTUnwrap(LookSkin.relativeAB(sample, LookSkin.pixels(in: thirds[k], of: sample)))
            XCTAssertEqual(measured.x, relative[k].x, accuracy: 1e-6)
            XCTAssertEqual(measured.y, relative[k].y, accuracy: 1e-6)
        }
        // The darker shadow looks more saturated than its absolute chroma says.
        let shadow = relative[0], mid = relative[1]
        XCTAssertGreaterThan((shadow * shadow).sum(), (mid * mid).sum())
    }

    /// The skin tone thirds are cut on the brightness a mask's Luminance Range reads: for a gray
    /// that is the gray's own encoded value.
    func testSkinToneCutsUseTheLuminanceRangeBrightness() {
        let width = 3, height = 1
        let grays: [UInt8] = [60, 128, 200]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for (x, gray) in grays.enumerated() {
            pixels[x * 4] = gray
            pixels[x * 4 + 1] = gray
            pixels[x * 4 + 2] = gray
        }
        let sample = LookSample(pixels: pixels, width: width, height: height)
        for (i, gray) in grays.enumerated() {
            XCTAssertEqual(LookSkin.rangeLuma(sample, i), Double(gray) / 255, accuracy: 0.003)
        }
        let split = LookSkin.toneSplit(sample, [2, 0, 1])
        XCTAssertEqual(split.groups, [[0], [1], [2]])
        XCTAssertEqual(split.cuts.0, 128.0 / 255, accuracy: 0.003)
        XCTAssertEqual(split.cuts.1, 200.0 / 255, accuracy: 0.003)
    }

    /// The joint skin fit's solver: exact on a well-posed system, and damped least squares shares
    /// a move between two sliders that do the same thing instead of fighting.
    func testSkinSolverSolvesTogether() throws {
        let x = try XCTUnwrap(SkinSolver.solve([[2, 1, 0], [1, 3, 1], [0, 1, 4]], [3, 5, 5]))
        XCTAssertEqual(x[0], 1, accuracy: 1e-9)
        XCTAssertEqual(x[1], 1, accuracy: 1e-9)
        XCTAssertEqual(x[2], 1, accuracy: 1e-9)
        XCTAssertNil(SkinSolver.solve([[1, 1], [1, 1]], [1, 2]))

        var solver = SkinSolver(masks: ["A"], tones: [SkinSolver.Tone(pixels: [], target: .zero, relative: true)],
                                limit: 35, settings: .neutral)
        // Temp and Tint move a and b separately; Saturation moves a like Temp does.
        solver.jacobian = [[0.001, 0, 0.001], [0, 0.002, 0]]
        let step = try XCTUnwrap(solver.step([0.01, 0.01]))
        XCTAssertEqual(step[0], step[2], accuracy: 0.5)
        XCTAssertGreaterThan(step[0], 3)
        XCTAssertEqual(step[1], 5, accuracy: 0.5)
        // Moves are capped per step.
        let big = try XCTUnwrap(solver.step([1, 1]))
        XCTAssertTrue(big.allSatisfy { abs($0) <= 30 })
    }

    /// A built-in study's skin target leans the photo's own skin toward the study: half way in
    /// hue inside the skin band, a mild saturation scale inside natural limits, a touch of warmth.
    func testStudySkinTargetLeansThePhotosOwnSkin() {
        func hue(_ v: SIMD2<Double>) -> Double { atan2(v.y, v.x) * 180 / .pi }
        func length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
        func vector(_ hue: Double, _ length: Double) -> SIMD2<Double> {
            SIMD2(cos(hue * .pi / 180), sin(hue * .pi / 180)) * length
        }
        let photo = vector(56, 0.12)
        // An olive study (Matrix, hue about 101°) never turns the face green.
        let olive = LookSkin.studyTarget(study: vector(101, 0.08), photo: photo, tone: 1)
        XCTAssertEqual(hue(olive), LookSkin.skinHueRange.upperBound, accuracy: 1e-9)
        // A study hue inside the band: half way, then a little warmer.
        let orange = LookSkin.studyTarget(study: vector(64, 0.091), photo: photo, tone: 1)
        XCTAssertEqual(hue(orange), 60 + (52 - 60) * 0.075, accuracy: 1e-9)
        XCTAssertEqual(length(orange), 0.12 * 1.03, accuracy: 1e-9)
        // A rich study scales by at most 1.2 and stays below the natural ceiling.
        let rich = LookSkin.studyTarget(study: vector(60, 0.4), photo: vector(56, 0.15), tone: 1)
        XCTAssertEqual(length(rich), LookSkin.skinSaturationRange.upperBound, accuracy: 1e-9)
        let richPale = LookSkin.studyTarget(study: vector(60, 0.4), photo: vector(56, 0.08), tone: 1)
        XCTAssertEqual(length(richPale), 0.08 * 1.2 * 1.03, accuracy: 1e-9)
        // A pale study (Thrones) scales by no less than 0.85, and never below the floor.
        let pale = LookSkin.studyTarget(study: vector(60, 0.03), photo: photo, tone: 1)
        XCTAssertEqual(length(pale), 0.12 * 0.85 * 1.03, accuracy: 1e-9)
        let gray = LookSkin.studyTarget(study: vector(60, 0.03), photo: SIMD2(0.001, 0), tone: 1)
        XCTAssertEqual(length(gray), LookSkin.skinSaturationRange.lowerBound, accuracy: 1e-9)
        // Against a cool background the skin is a little warmer and richer.
        let cool = LookSkin.studyTarget(study: vector(64, 0.091), photo: photo, tone: 1, coolBackground: true)
        XCTAssertLessThan(hue(cool), hue(orange))
        XCTAssertEqual(length(cool), 0.12 * 1.06, accuracy: 1e-9)
    }

    func testProtectSkinTonesKeepsSkinInsideItsLimits() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        // A strong teal look that turns orange skin green and grey.
        var look = DevelopSettings()
        look.temperature = 3800
        look.tint = -25
        look[.hsl(.hue, .orange)] = 60
        look[.hsl(.saturation, .orange)] = -50
        let reference = try XCTUnwrap(LookTarget(image: try XCTUnwrap(session.renderSRGB(look)), areas: .wholePhoto,
                                                 skinMode: .off))
        let plain = try sample(session, .neutral)
        let skin = try XCTUnwrap(LookSkin(sample: plain, faces: [skinPatch]))

        let free = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference))
        let freeDrift = try XCTUnwrap(skin.drift(try sample(session, free.matched)))
        let guarded = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference,
                                                      options: LookMatchOptions(skinMode: .protect),
                                                      photoFaces: [skinPatch]))
        let guardedDrift = try XCTUnwrap(skin.drift(try sample(session, guarded.matched)))
        print("LOOK MATCH skin: free \(freeDrift), protected \(guardedDrift); \(try guarded.matched.encoded())")
        XCTAssertFalse(guarded.notices.contains(.noFaces))
        XCTAssertLessThanOrEqual(abs(guardedDrift.hue), LookSkin.maxHueShift + 0.5)
        XCTAssertLessThanOrEqual(abs(guardedDrift.ratio - 1), LookSkin.maxChromaChange + 0.02)
        // The rest of the photo still takes the look.
        XCTAssertNotEqual(guarded.matched, DevelopSettings.neutral)
    }

    func testProtectSkinTonesWithoutFacesSaysSo() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: try samplePhoto(), maxPixelSize: LookSample.size))
        let reference = try XCTUnwrap(LookTarget(image: try XCTUnwrap(session.renderSRGB(.neutral)), areas: .wholePhoto,
                                                 skinMode: .off))
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference,
                                                    options: LookMatchOptions(skinMode: .protect), photoFaces: []))
        XCTAssertTrue(match.notices.contains(.noFaces))
    }

    func testFocusMaskCarriesItsShare() {
        let width = 40, height = 20
        var pixels = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width { pixels += x < width / 2 ? [200, 40, 40, 255] : [40, 60, 200, 255] }
        }
        let focus = (0..<(width * height)).map { Double($0 % width < width / 2 ? 1 : 0) }
        var subject = LookSample(pixels: pixels, width: width, height: height)
        subject.focusWeights(focus, share: 1)
        XCTAssertEqual(subject.weight.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(subject.weight[width - 1], 0, accuracy: 1e-12)
        var background = LookSample(pixels: pixels, width: width, height: height)
        background.focusWeights(focus.map { 1 - $0 }, share: 0.75)
        XCTAssertLessThan(background.midtoneAB.x, subject.midtoneAB.x - 0.05)
        // Leaving pixels out moves their weight to the rest.
        let without = subject.excluding([0, 1, 2])
        XCTAssertEqual(without.weight[0], 0)
        XCTAssertEqual(without.weight.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testSubjectMaskBlendsAndReplacesAnEarlierOne() {
        var mask = DevelopSettings.Mask(name: LookMatch.subjectMaskName,
                                        components: [.init(.subject(.init(feather: LookMatcher.subjectFeather)))])
        mask[.temperature] = 20
        mask[.exposure] = 0.5
        var matched = DevelopSettings()
        matched.masks = [mask]
        let match = LookMatch(base: .neutral, matched: matched, asShotTemperature: 6000)
        XCTAssertEqual(match.subjectMask?[.temperature], 20)
        let half = match.settings(strength: 0.5)
        XCTAssertEqual(half.masks.count, 1)
        XCTAssertEqual(half.masks[0][.temperature], 10)
        XCTAssertEqual(half.masks[0][.exposure], 0.25, accuracy: 1e-9)
        // Same settings on a photo that already has an earlier match's subject mask: it is replaced.
        var earlier = DevelopSettings.Mask(name: LookMatch.subjectMaskName, components: mask.components)
        earlier[.temperature] = -40
        var other = DevelopSettings()
        other.masks = [earlier]
        let synced = match.applied(to: other, strength: 1)
        XCTAssertEqual(synced.masks.count, 1)
        XCTAssertEqual(synced.masks[0].id, earlier.id)
        XCTAssertEqual(synced.masks[0][.temperature], 20)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures/\(name).jpg")
    }

    /// Protect Skin Tones keeps the look at full strength and holds the skin with the skin masks,
    /// instead of pulling the whole match back (which used to leave the photo nearly unchanged).
    func testToneOnlyPortraitMatchKeepsTheLookAndHoldsSkinWithMasks() throws {
        let url = fixture("portrait")
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size))
        let preview = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: 1400))
        let faces = LookSkin.faces(in: try XCTUnwrap(preview.renderSRGB(.neutral)))
        let skin = try XCTUnwrap(LookSkin(sample: try sample(session, .neutral), faces: faces))
        var look = DevelopSettings.neutral
        look[.exposure] = 2
        let reference = try XCTUnwrap(LookTarget(image: try XCTUnwrap(session.renderSRGB(look)), areas: .wholePhoto,
                                                 skinMode: .off))
        var options = LookMatchOptions(whiteBalance: false, color: false)
        let free = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference, options: options))
        XCTAssertFalse(skin.isWithin(try sample(session, free.settings(strength: 1))))

        options.skinMode = .protect
        let guarded = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference,
                                                       options: options, photoFaces: faces))
        let applied = guarded.settings(strength: 1)
        XCTAssertTrue(skin.isWithin(try sample(session, applied)))
        XCTAssertGreaterThan(applied.exposure, free.matched.exposure * 0.8)
        XCTAssertEqual(applied.saturation, 0)
        XCTAssertFalse(guarded.skinMasks.isEmpty)
    }

    func testGraySkinFailsChromaLimit() throws {
        let pixels = Array(repeating: [185, 129, 108, 255] as [UInt8], count: 400).flatMap { $0 }
        let gray = Array(repeating: [145, 145, 145, 255] as [UInt8], count: 400).flatMap { $0 }
        let plain = LookSample(pixels: pixels, width: 20, height: 20)
        let skin = try XCTUnwrap(LookSkin(sample: plain, faces: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        XCTAssertFalse(skin.isWithin(LookSample(pixels: gray, width: 20, height: 20)))
    }

    func testLandscapeMatchesWithoutFaceProtection() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: fixture("landscape"), maxPixelSize: LookSample.size))
        var look = DevelopSettings.neutral
        look[.exposure] = -0.7
        let image = try XCTUnwrap(session.renderSRGB(look))
        let reference = try XCTUnwrap(LookTarget(image: image, areas: .wholePhoto, skinMode: .protect))
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference,
                                                    options: .init(whiteBalance: false, color: false, skinMode: .protect)))
        XCTAssertTrue(match.notices.contains(.noFaces))
        XCTAssertTrue(match.matched.masks.isEmpty)
        let expected = try XCTUnwrap(LookSample(image: image))
        XCTAssertLessThan(try sample(session, match.settings(strength: 1)).distance(to: expected),
                          try sample(session, .neutral).distance(to: expected))
    }

    func testProductRepeatMatchKeepsUncheckedSubjectSlidersOnEachPhoto() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: fixture("product"), maxPixelSize: LookSample.size))
        var earlier = DevelopSettings.Mask(name: LookMatch.subjectMaskName,
                                           components: [.init(.subject(.init(feather: LookMatcher.subjectFeather)))])
        earlier[.temperature] = 20
        earlier[.exposure] = 0.45
        earlier[.clarity] = 12
        var base = DevelopSettings.neutral
        base.masks = [earlier]
        var look = base
        look.masks[0][.temperature] = -45
        let reference = try XCTUnwrap(LookTarget(image: try XCTUnwrap(session.renderSRGB(look)), areas: .subject,
                                                 skinMode: .off))
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: base, target: reference,
                                                    options: .init(tone: false, color: false)))
        XCTAssertTrue(match.notices.isEmpty)
        let updated = try XCTUnwrap(match.subjectMask)
        XCTAssertNotEqual(updated[.temperature], earlier[.temperature])
        let applied = match.settings(strength: 1)
        XCTAssertEqual(applied.masks, [updated])
        XCTAssertEqual(updated.id, earlier.id)
        XCTAssertEqual(updated[.exposure], 0.45)
        XCTAssertEqual(updated[.clarity], 12)

        var other = base
        other.masks[0][.exposure] = -0.7
        let synced = match.applied(to: other, strength: 0.5)
        XCTAssertEqual(synced.masks[0][.exposure], -0.7)
        XCTAssertEqual(synced.masks[0][.temperature], ((earlier[.temperature] + updated[.temperature]) / 2).rounded())
        XCTAssertEqual(synced.masks[0][.clarity], 12)
        XCTAssertEqual(match.applied(to: .neutral, strength: 1).masks.first?[.exposure], 0)
    }

    func testStudySubjectIsANudgeNotACopy() throws {
        // A built-in study's person is drawn: its color leans the photo's subject a third of the
        // way, with Temp, Tint and Saturation kept within ±20 (Rosh, Nov 14, 2026: a denim
        // jacket copied to Fury Road's brown one pinned Temp at +60 and turned the hair maroon).
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: fixture("product"), maxPixelSize: LookSample.size))
        var look = DevelopSettings.neutral
        var subject = DevelopSettings.Mask(name: "Look", components: [.init(.subject(.init(feather: LookMatcher.subjectFeather)))])
        subject[.temperature] = -90
        subject[.saturation] = 80
        look.masks = [subject]
        let image = try XCTUnwrap(session.renderSRGB(look))
        let photo = try XCTUnwrap(LookTarget(image: image, areas: .subject, skinMode: .off))
        let study = try XCTUnwrap(LookTarget(image: image, areas: .subject, skinMode: .off, colorStudy: true))
        let options = LookMatchOptions(tone: false)
        let copied = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: photo, options: options))
        let nudged = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: study, options: options))
        let full = try XCTUnwrap(copied.subjectMask)
        let gentle = try XCTUnwrap(nudged.subjectMask)
        for parameter in [DevelopSettings.LocalParameter.temperature, .tint, .saturation] {
            XCTAssertLessThanOrEqual(abs(gentle[parameter]), LookMatcher.maxStudySubjectShift, "\(parameter)")
        }
        XCTAssertLessThan(gentle[.temperature], 0)
        XCTAssertLessThan(abs(gentle[.temperature]), abs(full[.temperature]))
    }

    func testSubjectAreasFallBackWhenTheReferenceHasNoSubject() throws {
        // A plain gradient: Vision finds no subject, so the whole reference is matched.
        let width = 300, height = 200
        var pixels = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width { pixels += [UInt8(x * 255 / width), 120, 160, 255] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let target = try XCTUnwrap(LookTarget(image: image, areas: .subject, skinMode: .off))
        XCTAssertTrue(target.notices.contains(.noSubjectInReference))
        XCTAssertNil(target.subject)
    }
}
