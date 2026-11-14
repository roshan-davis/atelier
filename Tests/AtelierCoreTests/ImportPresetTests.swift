import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Import Presets and the Apply During Import stack (AT-057).
final class ImportPresetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImportPresets-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var store: ImportPresetStore { ImportPresetStore(fileURL: directory.appendingPathComponent("Import Presets.json")) }

    func testStoreSavesReplacesByNameRenamesAndDeletes() throws {
        let store = self.store
        let beach = ImportPreset(name: "Beach", copyFiles: true, destinationPath: "/Volumes/Photos", keywords: "beach, sea")
        try store.save(beach)
        try store.save(ImportPreset(name: "Airshow", cullFirst: true))
        XCTAssertEqual(store.all().map(\.name), ["Airshow", "Beach"])

        // The same name, another id: the old one goes (the dialog asked first).
        try store.save(ImportPreset(name: "beach", keywords: "sand"))
        XCTAssertEqual(store.all().map(\.name), ["Airshow", "beach"])
        XCTAssertEqual(store.all().last?.keywords, "sand")

        let airshow = try XCTUnwrap(store.all().first)
        try store.rename(airshow.id, to: "Zf Airshow")
        XCTAssertEqual(store.all().map(\.name), ["beach", "Zf Airshow"])
        try store.delete(airshow.id)
        XCTAssertEqual(store.all().map(\.name), ["beach"])
    }

    func testOlderOrDamagedEntriesStillLoad() throws {
        let id = UUID()
        let json = """
        [{"id": "\(id.uuidString)", "name": "Old"}, {"name": "No id"}, {"id": "\(UUID().uuidString)", "name": "Curve",
          "toneCurvePresetID": "\(UUID().uuidString)", "cullFirst": true}]
        """
        try Data(json.utf8).write(to: store.fileURL)
        let presets = store.all()
        XCTAssertEqual(presets.map(\.name), ["Old", "Curve"])
        XCTAssertEqual(presets[0], ImportPreset(id: id, name: "Old"))
        XCTAssertNotNil(presets[1].toneCurvePresetID)
        XCTAssertTrue(presets[1].cullFirst)
    }

    func testSaveNeverOverwritesAFileItCouldNotRead() throws {
        try Data("not presets".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(ImportPreset(name: "New")))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "not presets")
    }

    func testSameSettingsIgnoresNameAndID() {
        let a = ImportPreset(name: "Beach", keywords: "sea")
        var b = ImportPreset(name: "", keywords: "sea")
        XCTAssertTrue(a.sameSettings(as: b))
        b.cullFirst = true
        XCTAssertFalse(a.sameSettings(as: b))
    }

    private var stack: (DevelopPreset, DevelopPreset, DevelopPreset) {
        get throws {
            var look = DevelopSettings()
            look.exposure = 0.3
            look.contrast = 20
            let develop = DevelopPreset(name: "Punch", parts: [.exposure, .tone], settings: look)
            let matte = try XCTUnwrap(SectionPresetKind.toneCurve.builtIn.first { $0.name == "Matte" })
            let teal = try XCTUnwrap(SectionPresetKind.colorGrading.builtIn.first { $0.name == "Teal & Orange" })
            return (develop, matte, teal)
        }
    }

    func testStackAppliesInOrderWithOneHistoryStepEach() throws {
        let (develop, matte, teal) = try stack
        let options = ImportOptions(developPreset: develop, toneCurvePreset: matte, colorGradingPreset: teal)
        XCTAssertEqual(options.developSteps.map(\.name),
                       ["Import Preset: Punch", "Import Tone Curve Preset: Matte", "Import Color Grading Preset: Teal & Orange"])
        let initial = try XCTUnwrap(options.initialDevelop())
        XCTAssertEqual(initial.settings, teal.applied(to: matte.applied(to: develop.applied(to: .neutral))))
        XCTAssertEqual(initial.history.steps.map(\.name),
                       ["Import", "Import Preset: Punch", "Import Tone Curve Preset: Matte",
                        "Import Color Grading Preset: Teal & Orange"])
        XCTAssertEqual(initial.history.position, 3)
        // A panel preset changes only its panel.
        XCTAssertEqual(initial.settings.exposure, 0.3)
        XCTAssertEqual(initial.settings.contrast, 20)

        XCTAssertNil(ImportOptions().initialDevelop())
        let curveOnly = try XCTUnwrap(ImportOptions(toneCurvePreset: matte).initialDevelop())
        XCTAssertEqual(curveOnly.history.steps.map(\.name), ["Import", "Import Tone Curve Preset: Matte"])
    }

    func testImportedPhotoGetsTheStack() async throws {
        let file = directory.appendingPathComponent("Photo.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let (develop, matte, teal) = try stack
        let catalog = try Catalog()
        let options = ImportOptions(buildPreviews: false, developPreset: develop, toneCurvePreset: matte,
                                    colorGradingPreset: teal)
        let result = await Importer(catalog: catalog, previews: nil).run(sources: [file], options: options)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let id = try XCTUnwrap(result.importedAssetIDs.first)
        XCTAssertEqual(result.developedAssetIDs, [id])
        XCTAssertEqual(try catalog.developSettings(for: id), try XCTUnwrap(options.initialDevelop()).settings)
        XCTAssertEqual(try catalog.developHistory(for: id).steps.map(\.name),
                       ["Import", "Import Preset: Punch", "Import Tone Curve Preset: Matte",
                        "Import Color Grading Preset: Teal & Orange"])
    }
}
