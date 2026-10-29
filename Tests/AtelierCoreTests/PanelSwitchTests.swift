import CoreGraphics
import XCTest
@testable import AtelierCore

final class PanelSwitchTests: XCTestCase {
    private func edited() -> DevelopSettings {
        var settings = DevelopSettings()
        settings.exposure = 0.5
        settings.setPoints([.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)], for: .rgb)
        settings[.curveLights] = 20
        settings[.hsl(.saturation, .blue)] = -30
        settings[.gradeShadowsSat] = 40
        settings.sharpening = 60
        settings[.lensDistortion] = 10
        settings.removeChromaticAberration = true
        settings[.transformVertical] = 15
        settings.upright = DevelopSettings.Upright(mode: .level, roll: 2)
        settings.grain = 25
        return settings
    }

    /// Off takes away everything the panel does and keeps what it holds.
    func testOffRemovesEffectAndKeepsSettings() {
        var settings = edited()
        for panel in DevelopSettings.Panel.allCases where panel.hasSwitch {
            settings.setPanel(panel, on: false)
        }
        XCTAssertFalse(settings.isOn(.toneCurve))
        XCTAssertEqual(settings[.curveLights], 20)
        XCTAssertTrue(settings.hasPointCurve)

        let effective = settings.applyingPanelSwitches()
        XCTAssertEqual(effective.exposure, 0.5, "Basic has no switch")
        XCTAssertFalse(effective.hasPointCurve)
        XCTAssertEqual(effective[.curveLights], 0)
        XCTAssertEqual(effective[.hsl(.saturation, .blue)], 0)
        XCTAssertEqual(effective[.gradeShadowsSat], 0)
        XCTAssertEqual(effective.sharpening, 0)
        XCTAssertEqual(effective[.lensDistortion], 0)
        XCTAssertFalse(effective.removeChromaticAberration)
        XCTAssertFalse(effective.lensProfileCorrections)
        XCTAssertNil(effective.upright)
        XCTAssertEqual(effective[.transformVertical], 0)
        XCTAssertEqual(effective.grain, 0)
        XCTAssertFalse(effective.hasLensGeometry)
        XCTAssertTrue(effective.disabledPanels.isEmpty)
        XCTAssertEqual(effective.applyingPanelSwitches(), effective)
    }

    func testBasicHasNoSwitch() {
        var settings = edited()
        settings.setPanel(.basic, on: false)
        XCTAssertTrue(settings.isOn(.basic))
        XCTAssertEqual(settings.applyingPanelSwitches(), settings)
    }

    /// The lens geometry follows the switches, so the crop tool and Guided Upright match the photo.
    func testGeometryFollowsSwitches() {
        var settings = edited()
        let on = settings.lensGeometryKey
        settings.setPanel(.transform, on: false)
        XCTAssertNotEqual(settings.lensGeometryKey, on)
        XCTAssertNil(settings.lensGeometryKey.upright)
        XCTAssertEqual(settings.lensGeometryKey[.lensDistortion], 10)
        let size = CGSize(width: 600, height: 400)
        let off = LensGeometry(settings: settings, size: size, focalLength35: 50)
        var plain = settings
        plain.setPanel(.transform, on: true)
        plain.upright = nil
        plain[.transformVertical] = 0
        let expected = LensGeometry(settings: plain, size: size, focalLength35: 50)
        XCTAssertEqual(off.matrix, expected.matrix)
    }

    func testSwitchesAreSavedAndCompared() throws {
        var settings = edited()
        settings.setPanel(.detail, on: false)
        settings.setPanel(.effects, on: false)
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.isOn(.detail))
        XCTAssertNotEqual(decoded, edited())
        var neutral = DevelopSettings()
        neutral.setPanel(.hsl, on: false)
        XCTAssertFalse(neutral.isNeutral)
    }

    /// Color Grading's switch was first saved as a "gradeDisabled" value.
    func testReadsTheOldColorGradingSwitch() throws {
        let settings = try DevelopSettings.decoded(from: #"{"gradeDisabled":1,"gradeShadowsSat":40}"#)
        XCTAssertFalse(settings.isOn(.colorGrading))
        XCTAssertEqual(settings[.gradeShadowsSat], 40)
        XCTAssertFalse(try settings.encoded().contains("gradeDisabled"))
        XCTAssertTrue(try DevelopSettings.decoded(from: #"{"gradeShadowsSat":40}"#).isOn(.colorGrading))
    }

    func testContentsTellWhichPanelChanged() {
        let before = edited()
        var after = before
        after[.gradeShadowsSat] = 50
        XCTAssertNotEqual(before.contents(of: .colorGrading), after.contents(of: .colorGrading))
        XCTAssertEqual(before.contents(of: .detail), after.contents(of: .detail))
        after.setPoints([], for: .rgb)
        XCTAssertNotEqual(before.contents(of: .toneCurve), after.contents(of: .toneCurve))
        after.upright = nil
        XCTAssertNotEqual(before.contents(of: .transform), after.contents(of: .transform))
        after.setPanel(.effects, on: false)
        XCTAssertEqual(before.contents(of: .effects), after.contents(of: .effects), "the switch isn't the contents")
    }

    /// A preset carries the switch of each panel it covers.
    func testPresetsCarryTheirPanelsSwitches() {
        var saved = DevelopSettings()
        saved[.gradeShadowsSat] = 30
        saved.setPanel(.colorGrading, on: false)
        let preset = DevelopPreset(name: "Off", parts: [.colorGrading], settings: saved)
        var base = DevelopSettings()
        base.setPanel(.detail, on: false)
        let result = preset.applied(to: base)
        XCTAssertFalse(result.isOn(.colorGrading))
        XCTAssertFalse(result.isOn(.detail), "a part the preset leaves out keeps its switch")
        XCTAssertTrue(DevelopPreset.Part.colorGrading.isChanged(in: saved))
        var onlyOff = DevelopSettings()
        onlyOff.setPanel(.effects, on: false)
        XCTAssertTrue(DevelopPreset.Part.effects.isChanged(in: onlyOff))
    }
}
