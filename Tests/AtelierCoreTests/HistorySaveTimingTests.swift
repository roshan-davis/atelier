import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// AT-076 P1, measure first: how long Develop's save of the open photo (settings and whole
/// history, encoded and written; today on the main thread) takes as the history grows, for a
/// slider-only edit and for edits with brush masks and spots. Prints HISTORYBENCH lines.
/// Opt-in (a minute or two on a Mac): `ATELIER_HISTORY_BENCH=1 swift test --filter HistorySaveTimingTests`.
final class HistorySaveTimingTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierHistoryBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testHistorySaveTime() async throws {
        guard ProcessInfo.processInfo.environment["ATELIER_HISTORY_BENCH"] == "1" else {
            throw XCTSkip("Set ATELIER_HISTORY_BENCH=1 to time history saves.")
        }
        let (catalog, id) = try await makePhoto()
        for edit in Edit.allCases {
            for steps in [50, 200, 500] {
                var settings = edit.settings
                var history = DevelopHistory()
                for step in 0..<steps {
                    let previous = settings
                    settings.exposure = Double(step % 400) / 100 - 2
                    history.record("Exposure", settings: settings, previous: previous)
                }
                var encodes: [Double] = [], saves: [Double] = [], decodes: [Double] = []
                var bytes = 0
                for _ in 0..<5 {
                    var began = Date()
                    let json = try history.encoded()
                    encodes.append(Date().timeIntervalSince(began) * 1000)
                    bytes = json.utf8.count
                    began = Date()
                    try catalog.saveDevelop(settings, history: history, for: id)
                    saves.append(Date().timeIntervalSince(began) * 1000)
                    began = Date()
                    let read = try catalog.developHistory(for: id)
                    decodes.append(Date().timeIntervalSince(began) * 1000)
                    XCTAssertEqual(read.steps.count, history.steps.count)
                }
                print("HISTORYBENCH edit=\(edit) steps=\(history.steps.count) json_mb=\(String(format: "%.2f", Double(bytes) / 1_048_576)) "
                    + "encode_ms=\(Self.median(encodes)) save_ms=\(Self.median(saves)) read_ms=\(Self.median(decodes))")
            }
        }
    }

    /// What each step holds: Basic sliders only, a portrait retouch (one brush mask, a few spots),
    /// and a heavy local edit (three brush masks of long strokes, twenty spots).
    private enum Edit: CaseIterable, CustomStringConvertible {
        case sliders, retouch, heavyMasks

        var description: String {
            switch self {
            case .sliders: return "sliders"
            case .retouch: return "retouch"
            case .heavyMasks: return "heavy-masks"
            }
        }

        var settings: DevelopSettings {
            var settings = DevelopSettings.neutral
            settings.contrast = 12
            settings.highlights = -40
            settings.shadows = 35
            let (masks, strokes, points, spots) = switch self {
            case .sliders: (0, 0, 0, 0)
            case .retouch: (1, 5, 40, 5)
            case .heavyMasks: (3, 20, 60, 20)
            }
            settings.masks = (0..<masks).map { index in
                let lines = (0..<strokes).map { line in
                    DevelopSettings.MaskStroke(points: (0..<points).map { point in
                        DevelopSettings.MaskPoint(x: Double(point) / Double(points), y: Double(line) / Double(strokes) + 0.0123)
                    }, size: 0.05)
                }
                return DevelopSettings.Mask(name: "Mask \(index + 1)",
                                            components: [DevelopSettings.MaskComponent(.brush(lines))])
            }
            settings.spots = (0..<spots).map { index in
                DevelopSettings.Spot(mode: .heal, points: [DevelopSettings.MaskPoint(x: Double(index) / 25, y: 0.4)])
            }
            return settings
        }
    }

    private static func median(_ values: [Double]) -> Int {
        Int(values.sorted()[values.count / 2].rounded())
    }

    private func makePhoto() async throws -> (Catalog, Int64) {
        let shoot = workDir.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let url = shoot.appendingPathComponent("DSC_1.JPG")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [shoot], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.failures, [])
        return (catalog, try XCTUnwrap(result.assetIDsBySource.values.first))
    }
}
