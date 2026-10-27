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
}
