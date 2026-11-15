import ImageIO
import XCTest
@testable import AtelierApp
@testable import AtelierCore

final class BuiltInLookReferenceTests: XCTestCase {
    /// Use the same artwork, Whole Photo target and Develop renders as the dialog. Optionally
    /// export the actual fits for visual qualification and Atelier Help.
    func testStudiesMoveRealPhotosTowardTheirPalettes() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        let photos: [BuiltInLookReference: String] = [
            .matrixPortrait: "portrait", .matrixCity: "street",
            .thronesPortrait: "portrait-light", .thronesLandscape: "landscape",
            .furyRoadPortrait: "portrait", .furyRoadScene: "landscape",
            .darkKnightPortrait: "portrait-light", .darkKnightCity: "twilight",
        ]
        for reference in BuiltInLookReference.allCases {
            let fixture = try XCTUnwrap(photos[reference])
            let url = fixtures.appendingPathComponent(fixture + ".jpg")
            let art = try XCTUnwrap(reference.image())
            let fit = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size))
            let preview = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: 960))
            let before = try XCTUnwrap(preview.renderSRGB(.neutral))
            let source = try XCTUnwrap(fit.renderSRGB(.neutral).flatMap { LookSample(image: $0) })
            let faces = LookSkin.faces(in: before)
            let skinMode: LookSkinMode = faces.isEmpty ? .off : .protect
            let skin = LookSkin(sample: source, faces: faces)
            if reference.scene == .portrait {
                XCTAssertNotNil(skin, "Expected measurable skin in \(fixture)")
            }
            let target = try XCTUnwrap(LookTarget(image: art, areas: .wholePhoto, skinMode: skinMode, colorStudy: true))
            let match = try XCTUnwrap(LookMatcher.match(session: fit, settings: .neutral, target: target,
                                                       options: .init(skinMode: skinMode), photoFaces: faces))
            let result = try XCTUnwrap(fit.renderSRGB(match.matched).flatMap { LookSample(image: $0) })
            let pixels = skin?.pixels ?? []
            let palette = target.whole.projectedQuantiles()
            let start = LookSample.slicedDistance(source.excluding(pixels).projectedQuantiles(), palette)
            let end = LookSample.slicedDistance(result.excluding(pixels).projectedQuantiles(), palette)
            let drift = skin?.drift(result).map { String(format: ", skin %+.2f°, chroma ×%.3f", $0.hue, $0.ratio) } ?? ""
            print("BUILT-IN \(reference.name) / \(fixture): palette distance \(start) → \(end)\(drift)")
            XCTAssertLessThan(end, start, reference.name)
            XCTAssertNil(match.subjectMask)
            // A study gives color only: brightness and the Tone Curve stay the photo's.
            XCTAssertEqual(match.matched.exposure, 0, reference.name)
            XCTAssertEqual(match.matched.points(for: .rgb), DevelopSettings.neutral.points(for: .rgb), reference.name)
            XCTAssertEqual(match.settings(strength: 0), .neutral)
            if let skin { XCTAssertTrue(skin.isWithin(result), reference.name) }

            if let path = ProcessInfo.processInfo.environment["ATELIER_BUILT_IN_LOOK_OUT"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let after = try XCTUnwrap(preview.renderSRGB(match.matched))
                for (label, image) in [("reference", art), ("before", before), ("after", after)] {
                    let file = folder.appendingPathComponent("\(reference.rawValue)-\(label).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
    }

    /// Each study is read from its SVG (Rosh's drawing) with a wide tonal range, and is marked as
    /// a color study.
    func testStudiesLoadFromTheirDrawings() throws {
        for study in BuiltInLookReference.allCases {
            let drawing = try XCTUnwrap(study.drawing, study.name)
            XCTAssertEqual(drawing.viewBox, CGRect(x: 0, y: 0, width: 280, height: 180), study.name)
            XCTAssertGreaterThan(drawing.shapes.count, 10, study.name)
            let image = try XCTUnwrap(study.image())
            XCTAssertEqual(image.width, 960)
            XCTAssertEqual(image.height, 617)
            let sample = try XCTUnwrap(LookSample(image: image))
            let range = sample.lumaPercentiles([0.01, 0.99])
            XCTAssertGreaterThan(range[1] - range[0], 0.45, study.name)
            let target = try XCTUnwrap(LookTarget(image: image, areas: .wholePhoto, colorStudy: true))
            XCTAssertTrue(target.whole.isColorStudy, study.name)
        }
    }

    /// `LookSkin.studySkinBaseline` is the four portrait studies' mean drawn skin saturation per tone.
    func testStudySkinBaselineMatchesTheDrawings() throws {
        var sums = [0.0, 0.0, 0.0]
        var count = 0.0
        for study in BuiltInLookReference.allCases where study.scene == .portrait {
            let image = try XCTUnwrap(study.image())
            let target = try XCTUnwrap(LookTarget(image: image, areas: .wholePhoto, skinMode: .match,
                                                  authoredSkinTones: study.skinToneRegions, colorStudy: true))
            let tones = try XCTUnwrap(target.skin).relativeToneColors
            XCTAssertEqual(tones.count, 3, study.name)
            for k in 0..<3 { sums[k] += (tones[k] * tones[k]).sum().squareRoot() }
            count += 1
        }
        for k in 0..<3 {
            XCTAssertEqual(sums[k] / count, LookSkin.studySkinBaseline[k], accuracy: 0.004, "tone \(k)")
        }
    }

    func testPortraitStudiesMatchFaceColorWithEditableMasks() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        for study in BuiltInLookReference.allCases {
            let image = try XCTUnwrap(study.image())
            let target = try XCTUnwrap(LookTarget(image: image, areas: .wholePhoto, skinMode: .match,
                                                  authoredSkinTones: study.skinToneRegions, colorStudy: true))
            guard study.scene == .portrait else {
                XCTAssertEqual(target.notices, [.noSkinInReference], study.name)
                continue
            }

            let fixture = study == .matrixPortrait || study == .furyRoadPortrait ? "portrait" : "portrait-light"
            let url = fixtures.appendingPathComponent(fixture + ".jpg")
            let fit = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: LookSample.size))
            let preview = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: 960))
            let before = try XCTUnwrap(preview.renderSRGB(.neutral))
            let faces = LookSkin.faces(in: before)
            let source = try XCTUnwrap(fit.renderSRGB(.neutral).flatMap { LookSample(image: $0) })
            let skin = try XCTUnwrap(LookSkin(sample: source, faces: faces))
            let reference = try XCTUnwrap(target.skin)
            let options = LookMatchOptions(whiteBalance: false, tone: false, color: false, skinMode: .match)
            let result = try XCTUnwrap(LookMatcher.match(session: fit, settings: .neutral, target: target,
                                                        options: options, photoFaces: faces))
            let mask = try XCTUnwrap(result.skinMasks.first, study.name)
            // Skin is compared tone by tone: the photo's darkest, middle and brightest thirds of
            // skin against the study's drawn skin shadows, midtones and highlights, as color
            // relative to brightness (what Match Skin Tone matches).
            // A study's target leans the photo's own skin toward the study (`LookSkin.studyTarget`).
            XCTAssertEqual(reference.relativeToneColors.count, 3, study.name)
            let groups = LookSkin.toneSplit(source, skin.pixels).groups
            let cool = LookSkin.isCool(source, outside: skin.pixels)
            let targets = try (0..<3).map { k in
                LookSkin.studyTarget(study: reference.relativeToneColors[k],
                                     photo: try XCTUnwrap(LookSkin.relativeAB(source, groups[k])), tone: k,
                                     coolBackground: cool)
            }
            func error(_ settings: DevelopSettings) throws -> Double {
                let sample = try XCTUnwrap(fit.renderSRGB(settings).flatMap { LookSample(image: $0) })
                return try zip(groups, targets).reduce(0) { sum, pair in
                    let d = try XCTUnwrap(LookSkin.relativeAB(sample, pair.0)) - pair.1
                    return sum + (d * d).sum().squareRoot()
                }
            }
            let start = try error(.neutral), half = try error(result.settings(strength: 0.5))
            let end = try error(result.settings(strength: 1))
            print("SKIN \(study.name) / \(fixture): Oklab color distance (relative to lightness) \(start) → \(half) → \(end)")
            XCTAssertLessThan(end, half, study.name)
            XCTAssertLessThan(half, start, study.name)
            XCTAssertEqual(result.notices, [])
            XCTAssertEqual(result.settings(strength: 0), .neutral)
            XCTAssertEqual(result.applied(to: .neutral, strength: 1), .neutral)
            XCTAssertEqual(result.matched.exposure, 0)
            XCTAssertEqual(mask[.exposure], 0)

            var base = result.matched
            base.masks[0][.texture] = 8
            let repeatMatch = try XCTUnwrap(LookMatcher.match(session: fit, settings: base, target: target,
                                                             options: options, photoFaces: faces))
            // A second match reuses the same masks (by name) and keeps their other sliders.
            XCTAssertEqual(repeatMatch.matched.masks.map(\.id), base.masks.map(\.id))
            XCTAssertEqual(repeatMatch.matched.masks.first?[.texture], 8)

            if study == .matrixPortrait, let path = ProcessInfo.processInfo.environment["ATELIER_SKIN_LOOK_OUT"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let after = try XCTUnwrap(preview.renderSRGB(result.matched))
                for (label, pixels) in [("reference", image), ("before", before), ("after", after)] {
                    let file = folder.appendingPathComponent("skin-\(label).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, pixels, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
    }

    /// Each portrait's three skin samples sit inside one flat tone each, darkest to brightest,
    /// inside the shapes marked skin, and its drawn person makes a usable subject mask; wide
    /// studies have neither.
    func testPortraitStudiesHaveSkinTonesAndADrawnSubject() throws {
        for study in BuiltInLookReference.allCases {
            let image = try XCTUnwrap(study.image())
            guard study.scene == .portrait else {
                XCTAssertTrue(study.skinToneRegions.isEmpty, study.name)
                XCTAssertNil(study.features(for: image), study.name)
                continue
            }
            let sample = try XCTUnwrap(LookSample(image: image))
            let regions = study.skinToneRegions
            XCTAssertEqual(regions.count, 3, study.name)
            var previous = -1.0
            for region in regions {
                let pixels = LookSkin.pixels(in: region, of: sample)
                XCTAssertGreaterThanOrEqual(pixels.count, 4, study.name)
                let lightness = pixels.map { Double(sample.lightness[$0]) }
                let mean = lightness.reduce(0, +) / Double(lightness.count)
                // One flat tone (the faint grain moves it by about 1%).
                XCTAssertLessThan((lightness.max() ?? 0) - (lightness.min() ?? 0), 0.04, study.name)
                XCTAssertGreaterThan(mean, previous + 0.03, study.name)
                previous = mean
            }
            let features = try XCTUnwrap(study.features(for: image), study.name)
            let subject = try XCTUnwrap(features.subject, study.name)
            let share = subject.reduce(0, +) / Double(subject.count)
            XCTAssertGreaterThan(share, 0.15, study.name)
            XCTAssertLessThan(share, 0.7, study.name)
            XCTAssertEqual(features.faces.count, 1, study.name)
            // Show Skin tints the drawn skin, which holds every skin sample.
            let skin = try XCTUnwrap(study.skinMask(width: image.width))
            let values = try XCTUnwrap(LookSample.focusValues(skin, width: sample.width, height: sample.height))
            for region in regions {
                for i in LookSkin.pixels(in: region, of: sample) { XCTAssertGreaterThan(values[i], 0.5, study.name) }
            }
        }
    }
}
