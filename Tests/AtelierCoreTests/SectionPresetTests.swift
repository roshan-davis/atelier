import Foundation
import XCTest
@testable import AtelierCore

/// The Tone Curve and Color Grading panels' own presets.
final class SectionPresetTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierSectionPresets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testBuiltInsCarryOnlyTheirPanelWithFixedUniqueIDs() {
        var ids = Set<UUID>()
        for kind in SectionPresetKind.allCases {
            let presets = kind.builtIn
            XCTAssertFalse(presets.isEmpty)
            XCTAssertEqual(presets.first?.name, kind.neutralName)
            var groups: [String] = []
            for preset in presets where groups.last != preset.group { groups.append(preset.group) }
            XCTAssertEqual(groups, kind.builtInGroups, kind.title)
            for preset in presets {
                XCTAssertEqual(preset.parts, [kind.part], preset.name)
                XCTAssertTrue(preset.isBuiltIn)
                XCTAssertTrue(ids.insert(preset.id).inserted, "\(preset.name) has its own ID")
                // Every value is inside its slider's range.
                for parameter in kind.part.parameters {
                    XCTAssertTrue(parameter.range.contains(preset.settings[parameter]), "\(preset.name) \(parameter)")
                }
            }
            XCTAssertEqual(Set(presets.map(\.name)).count, presets.count, kind.title)
        }
        XCTAssertEqual(SectionPresetKind.toneCurve.builtIn.first { $0.name == "Matte" }?.id.uuidString,
                       "5EC7A0B5-0120-4C5E-9A7E-0A7E11E50120")
        XCTAssertEqual(SectionPresetKind.colorGrading.builtIn.first { $0.name == "Teal & Orange" }?.id.uuidString,
                       "5EC7A0B5-0201-4C5E-9A7E-0A7E11E50201")
    }

    func testToneCurvePresetReplacesTheWholeCurveAndNothingElse() throws {
        var photo = DevelopSettings()
        photo.exposure = 0.5
        photo[.curveShadows] = 40
        photo.setPoints([.init(x: 0, y: 0.2), .init(x: 1, y: 1)], for: .red)
        photo[.gradeShadowsSat] = 30
        let matte = try XCTUnwrap(SectionPresetKind.toneCurve.builtIn.first { $0.name == "Matte" })
        let result = matte.applied(to: photo)
        XCTAssertEqual(result.exposure, 0.5)
        XCTAssertEqual(result[.gradeShadowsSat], 30)
        XCTAssertEqual(result[.curveShadows], 0, "the parametric regions are reset")
        XCTAssertEqual(result.points(for: .red), DevelopSettings.CurvePoint.identity, "other channels are reset")
        XCTAssertGreaterThan(result.points(for: .rgb)[0].y, 0.05, "Matte lifts black")
        XCTAssertTrue(SectionPresetKind.toneCurve.matches(matte, result))
        XCTAssertEqual(SectionPresetKind.toneCurve.matching(result, in: SectionPresetKind.toneCurve.builtIn)?.name, "Matte")

        let linear = SectionPresetKind.toneCurve.builtIn[0]
        let cleared = linear.applied(to: result)
        XCTAssertFalse(DevelopPreset.Part.toneCurve.isChanged(in: cleared))
        XCTAssertEqual(cleared.exposure, 0.5)
        XCTAssertEqual(SectionPresetKind.toneCurve.matching(.neutral, in: SectionPresetKind.toneCurve.builtIn)?.name, "Linear")
    }

    func testColorGradingPresetSetsEveryWheelAndKeepsTheRest() throws {
        var photo = DevelopSettings()
        photo.contrast = 20
        photo[.gradeGlobalSat] = 40
        photo.setPoints([.init(x: 0, y: 0.1), .init(x: 1, y: 1)], for: .rgb)
        let teal = try XCTUnwrap(SectionPresetKind.colorGrading.builtIn.first { $0.name == "Teal & Orange" })
        let result = teal.applied(to: photo)
        XCTAssertEqual(result.contrast, 20)
        XCTAssertEqual(result.points(for: .rgb), photo.points(for: .rgb))
        XCTAssertEqual(result[.gradeGlobalSat], 0, "wheels the preset leaves neutral are reset")
        XCTAssertEqual(result[.gradeShadowsHue], 194)
        XCTAssertEqual(result[.gradeHighlightsHue], 36)
        // Shadows and highlights sit roughly opposite on the wheel.
        let gap = abs(result[.gradeShadowsHue] - result[.gradeHighlightsHue])
        XCTAssertEqual(min(gap, 360 - gap), 180, accuracy: 25)
    }

    func testMatchingIgnoresThePanelSwitchAndCustomHasNoMatch() throws {
        let kind = SectionPresetKind.colorGrading
        let teal = try XCTUnwrap(kind.builtIn.first { $0.name == "Teal & Orange" })
        var graded = teal.applied(to: .neutral)
        graded.setPanel(.colorGrading, on: false)
        XCTAssertEqual(kind.matching(graded, in: kind.builtIn)?.id, teal.id)
        graded[.gradeShadowsSat] += 1
        XCTAssertNil(kind.matching(graded, in: kind.builtIn))
    }

    func testApplyingTurnsAnOffPanelOn() throws {
        var photo = DevelopSettings()
        photo.setPanel(.toneCurve, on: false)
        let strong = try XCTUnwrap(SectionPresetKind.toneCurve.builtIn.first { $0.name == "Strong Contrast" })
        XCTAssertTrue(strong.applied(to: photo).isOn(.toneCurve))
    }

    func testUserPresetKeepsOnlyThePanelAndRoundTrips() throws {
        var photo = DevelopSettings()
        photo.exposure = 1
        photo[.gradeMidtonesHue] = 120
        photo[.gradeMidtonesSat] = 15
        photo[.gradeBlending] = 70
        photo.setPanel(.colorGrading, on: false)
        let kind = SectionPresetKind.colorGrading
        let preset = kind.preset(named: "Mint", from: photo)
        XCTAssertEqual(preset.parts, [.colorGrading])
        XCTAssertEqual(preset.settings.exposure, 0, "only the panel is stored")
        XCTAssertTrue(preset.settings.isOn(.colorGrading), "saved on, so applying it shows")
        XCTAssertFalse(preset.isBuiltIn)

        let store = PresetStore(section: kind, folder: workDir)
        XCTAssertEqual(store.fileURL.lastPathComponent, "Color Grading Presets.json")
        try store.save(preset)
        let loaded = try XCTUnwrap(store.userPresets().first)
        XCTAssertEqual(loaded, preset)
        let onOther = loaded.applied(to: .neutral)
        XCTAssertEqual(onOther[.gradeMidtonesHue], 120)
        XCTAssertEqual(onOther[.gradeBlending], 70)
        XCTAssertTrue(kind.matches(loaded, photo))
        // The two panels keep separate files.
        XCTAssertTrue(PresetStore(section: .toneCurve, folder: workDir).userPresets().isEmpty)
    }
}
