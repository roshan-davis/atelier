import CoreGraphics
import Foundation
import XCTest
@testable import AtelierCore

/// Match Look's fast stand-in must give the same colors as the real renderer, or the fit it
/// guides goes somewhere the real photo doesn't.
final class LookEmulatorTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures/\(name).jpg")
    }

    private func sample(_ session: DevelopSession, _ settings: DevelopSettings) throws -> LookSample {
        try XCTUnwrap(session.renderSRGB(settings).flatMap { LookSample(image: $0) })
    }

    /// Mean Oklab difference per pixel between two samples of the same size.
    private func meanDifference(_ x: LookSample, _ y: LookSample) -> Double {
        XCTAssertEqual(x.count, y.count)
        var total = 0.0
        for i in 0..<min(x.count, y.count) {
            let d = SIMD3<Double>(Double(x.lightness[i] - y.lightness[i]), Double(x.a[i] - y.a[i]), Double(x.b[i] - y.b[i]))
            total += (d * d).sum().squareRoot()
        }
        return total / Double(max(1, min(x.count, y.count)))
    }

    private func emulator(_ session: DevelopSession, _ settings: DevelopSettings,
                          weigh: @escaping (DevelopSettings, DevelopSettings.Mask) -> [Float]? = { _, _ in nil }) throws -> LookEmulator {
        let stage = LookEmulator.neutralStage(settings)
        let image = try XCTUnwrap(session.renderSRGB(stage))
        return try XCTUnwrap(LookEmulator(stage: image, stageSettings: stage, weigh: weigh))
    }

    func testStandInFollowsCurveSaturationHSLAndGrading() throws {
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: fixture("landscape"), maxPixelSize: LookSample.size))
        let stand = try emulator(session, .neutral)
        var look = DevelopSettings.neutral
        look.contrast = 30
        look.blacks = -20
        look[.curveLights] = 25
        look.setPoints([.init(x: 0, y: 0.04), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.96)], for: .rgb)
        look.saturation = -25
        look[.hsl(.hue, .orange)] = 20
        look[.hsl(.saturation, .blue)] = -40
        look[.gradeShadowsHue] = 200
        look[.gradeShadowsSat] = 30
        look[.gradeHighlightsHue] = 45
        look[.gradeHighlightsSat] = 25
        XCTAssertTrue(stand.follows(look))
        let guess = try XCTUnwrap(stand.sample(look))
        let real = try sample(session, look)
        XCTAssertLessThan(meanDifference(guess, real), 0.012)
        XCTAssertLessThan(guess.distance(to: real), 0.01)

        // Exposure after decode is close to a gain.
        look.exposure = 0.3
        XCTAssertLessThan(meanDifference(try XCTUnwrap(stand.sample(look)), try sample(session, look)), 0.02)

        // Another white balance is rendered for real.
        look.tint = 20
        XCTAssertFalse(stand.follows(look))
    }

    func testStandInBlendsMatchLookMasksByTheirMeasuredWeight() throws {
        let url = fixture("portrait")
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size))
        let plain = try XCTUnwrap(session.renderSRGB(.neutral))
        let size = CGSize(width: plain.width, height: plain.height)
        let space = MaskSpace(sourceSize: session.sourceSize, crop: .init(), rect: CGRect(origin: .zero, size: size),
                              outputSize: size)
        let gradient = space.radial(center: CGPoint(x: size.width / 2, y: size.height * 0.4), width: size.width * 0.25,
                                    height: size.height * 0.3, feather: 45)
        var mask = DevelopSettings.Mask(name: LookMatch.skinMaskName, components: [.init(.radial(gradient))])
        // The weight as the match measures it: the photo with only the mask at Exposure -4.
        func luma(_ settings: DevelopSettings) -> [Float]? {
            guard let image = session.renderSRGB(settings), let data = LookSample.pixels(of: image) else { return nil }
            let linear = LookSample.linearTable
            let pixels = data.pixels
            var out = [Float](repeating: 0, count: data.width * data.height)
            for i in out.indices {
                let r: Double = linear[Int(pixels[i * 4])]
                let g: Double = linear[Int(pixels[i * 4 + 1])]
                let b: Double = linear[Int(pixels[i * 4 + 2])]
                out[i] = Float(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            return out
        }
        var weighed = 0
        let stand = try emulator(session, .neutral) { settings, mask in
            weighed += 1
            var dimmed = mask
            dimmed.resetAdjustments()
            dimmed[.exposure] = -4
            var probe = settings
            probe.masks = [dimmed]
            var bare = settings
            bare.masks = []
            guard let before = luma(bare), let after = luma(probe) else { return nil }
            var weights = [Float](repeating: 0, count: before.count)
            for i in weights.indices where before[i] >= 0.002 {
                let ratio: Float = after[i] / before[i]
                weights[i] = min(1, max(0, (1 - ratio) / Float(15.0 / 16)))
            }
            return weights
        }
        mask[.temperature] = 35
        mask[.tint] = -20
        mask[.saturation] = -30
        mask[.exposure] = 0.4
        var settings = DevelopSettings.neutral
        settings.contrast = 20
        settings.masks = [mask]
        XCTAssertTrue(stand.follows(settings))
        let guess = try XCTUnwrap(stand.sample(settings))
        let real = try sample(session, settings)
        XCTAssertLessThan(meanDifference(guess, real), 0.012)
        // Moving the mask's sliders again reuses the weight.
        settings.masks[0][.temperature] = 10
        _ = stand.sample(settings)
        XCTAssertEqual(weighed, 1)
    }

    /// The whole match with skin masks now renders the photo only a few dozen times.
    func testSkinMatchRendersLittle() throws {
        let url = fixture("portrait")
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size))
        let preview = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: 1400))
        let faces = LookSkin.faces(in: try XCTUnwrap(preview.renderSRGB(.neutral)))
        XCTAssertFalse(faces.isEmpty)
        var look = DevelopSettings.neutral
        look.exposure = 0.6
        look.saturation = 30
        look[.gradeMidtonesHue] = 30
        look[.gradeMidtonesSat] = 25
        let reference = try XCTUnwrap(LookTarget(image: try XCTUnwrap(session.renderSRGB(look)), areas: .wholePhoto,
                                                 skinMode: .protect))
        let options = LookMatchOptions(skinMode: .protect)
        let match = try XCTUnwrap(LookMatcher.match(session: session, settings: .neutral, target: reference,
                                                    options: options, photoFaces: faces))
        XCTAssertLessThanOrEqual(LookMatcher.lastMatchRenders, 40)
        XCTAssertNotEqual(match.matched, .neutral)
    }
}
