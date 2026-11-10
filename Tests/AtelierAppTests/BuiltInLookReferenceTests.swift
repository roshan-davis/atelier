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
            let target = try XCTUnwrap(LookTarget(image: art, areas: .wholePhoto, skinMode: skinMode))
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

    /// Each study has real blacks (so matching it never fades a photo) and a wide tonal range,
    /// and is built from many flat tones: no single color (after the faint grain) covers a big
    /// share of the drawing.
    func testStudiesHaveRealBlacksAndManyFlatTones() throws {
        for study in BuiltInLookReference.allCases {
            let image = try XCTUnwrap(study.image())
            let sample = try XCTUnwrap(LookSample(image: image))
            let range = sample.lumaPercentiles([0.01, 0.99])
            XCTAssertLessThan(range[0], 0.05, study.name)
            XCTAssertGreaterThan(range[1] - range[0], 0.5, study.name)
            let pixels = try XCTUnwrap(LookSample.pixels(of: image)).pixels
            var counts: [Int: Int] = [:]
            for i in stride(from: 0, to: pixels.count, by: 4) {
                counts[Int(pixels[i]) << 16 | Int(pixels[i + 1]) << 8 | Int(pixels[i + 2]), default: 0] += 1
            }
            let largest = Double(counts.values.max() ?? 0) / Double(pixels.count / 4)
            XCTAssertLessThan(largest, 0.1, study.name)
        }
    }

    func testPortraitStudiesMatchFaceColorWithEditableMasks() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        for study in BuiltInLookReference.allCases {
            let image = try XCTUnwrap(study.image())
            let target = try XCTUnwrap(LookTarget(image: image, areas: .wholePhoto, skinMode: .match,
                                                  authoredSkinRegions: study.skinRegions))
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
            let mask = try XCTUnwrap(result.skinMask, study.name)
            func error(_ settings: DevelopSettings) throws -> Double {
                let sample = try XCTUnwrap(fit.renderSRGB(settings).flatMap { LookSample(image: $0) })
                let face = try XCTUnwrap(LookSkin.hueAndChroma(sample, skin.pixels))
                let angle = LookSkin.hueDifference(face.hue, reference.hue) * .pi / 180
                return hypot(face.chroma * cos(angle) - reference.chroma, face.chroma * sin(angle))
            }
            let start = try error(.neutral), half = try error(result.settings(strength: 0.5))
            let end = try error(result.settings(strength: 1))
            print("SKIN \(study.name) / \(fixture): Oklab color distance \(start) → \(half) → \(end)")
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
            XCTAssertEqual(repeatMatch.matched.masks.map(\.id), [mask.id])
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

}
