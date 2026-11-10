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
            let protectSkin = !faces.isEmpty
            let skin = LookSkin(sample: source, faces: faces)
            if reference.scene == .portrait {
                XCTAssertNotNil(skin, "Expected measurable skin in \(fixture)")
            }
            let target = try XCTUnwrap(LookTarget(image: art, areas: .wholePhoto, protectSkin: protectSkin))
            let match = try XCTUnwrap(LookMatcher.match(session: fit, settings: .neutral, target: target,
                                                       options: .init(protectSkin: protectSkin), photoFaces: faces))
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
}
