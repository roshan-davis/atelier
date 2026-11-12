import XCTest
@testable import AtelierHDRCore

/// HDR presets (Presets panel, Nov 12, 2026) and the Color sliders they use.
final class HDRPresetTests: XCTestCase {
    func testBuiltInPresetsAreValidUniqueAndGrouped() throws {
        let presets = HDRPreset.builtIn
        XCTAssertGreaterThanOrEqual(presets.count, 15)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.group)), Set(HDRPreset.builtInGroups))
        for preset in presets {
            XCTAssertNoThrow(try preset.settings.validate(), preset.name)
            XCTAssertTrue(preset.isBuiltIn)
        }
        // Each one looks different from the others.
        for (i, a) in presets.enumerated() {
            for b in presets[(i + 1)...] { XCTAssertNotEqual(a.settings, b.settings, "\(a.name) = \(b.name)") }
        }
        // The ids never change, so favorites survive relaunches.
        XCTAssertEqual(presets[0].id.uuidString, "6E3D0000-0000-4000-8000-000000000001")
    }

    func testApplyingKeepsThePhotosExposure() {
        var current = HDRSettings(); current.exposure = 1.25; current.toneEnabled = false
        let preset = HDRPreset.builtIn.first { $0.name == "Dramatic" }!
        let applied = preset.applied(to: current)
        XCTAssertEqual(applied.exposure, 1.25)
        XCTAssertTrue(applied.toneEnabled)
        XCTAssertEqual(applied.microcontrast, preset.settings.microcontrast)
        XCTAssertTrue(preset.matches(applied))
        XCTAssertFalse(preset.matches(current))
    }

    func testUserPresetsSaveRenameDeleteAndSkipDamagedEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HDRPresetStore(fileURL: folder.appendingPathComponent("HDR Presets.json"))
        XCTAssertEqual(store.all().count, HDRPreset.builtIn.count)
        var settings = HDRSettings(); settings.method = .fusion; settings.vibrance = 0.4
        let mine = HDRPreset(name: "Mine", settings: settings)
        try store.save(mine)
        XCTAssertEqual(store.all().first, mine)
        XCTAssertFalse(mine.isBuiltIn)
        try store.rename(mine.id, to: "Ours")
        XCTAssertEqual(store.userPresets().map(\.name), ["Ours"])
        // Built-in presets are never written.
        try store.save(HDRPreset.builtIn[0])
        XCTAssertEqual(store.userPresets().count, 1)
        // An entry this version can't read is skipped, not fatal.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [Any]
        json.append(["id": UUID().uuidString, "name": "Broken", "group": "User Presets", "settings": ["detail": 9]])
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        XCTAssertEqual(store.userPresets().map(\.name), ["Ours"])
        try store.delete(mine.id)
        XCTAssertTrue(store.userPresets().isEmpty)
    }

    func testColorAtZeroChangesNothingAndKeepsLuminance() throws {
        let image = try HDRImage(width: 2, height: 1, rgb: [0.4, 0.2, 0.1, 0.05, 0.3, 0.6])
        let plain = try HDRToneMapper.render(image, settings: HDRSettings())
        var neutral = HDRSettings(); neutral.temperature = 0; neutral.saturation = 0; neutral.vibrance = 0
        XCTAssertEqual(try HDRToneMapper.render(image, settings: neutral).rgb, plain.rgb)
        for (t, s, v) in [(Float(0.8), Float(0), Float(0)), (-0.8, 0, 0), (0, 0.7, 0), (0, -1, 0), (0, 0, 0.9)] {
            let (r, g, b) = HDRToneMapper.color(0.4, 0.2, 0.1, settings: {
                var x = HDRSettings(); x.temperature = t; x.saturation = s; x.vibrance = v; return x
            }())
            XCTAssertEqual(r * 0.2126 + g * 0.7152 + b * 0.0722, 0.4 * 0.2126 + 0.2 * 0.7152 + 0.1 * 0.0722, accuracy: 0.0001)
        }
        var warm = HDRSettings(); warm.temperature = 1
        let warmed = HDRToneMapper.color(0.3, 0.3, 0.3, settings: warm)
        XCTAssertGreaterThan(warmed.0, warmed.2)
        var gray = HDRSettings(); gray.saturation = -1
        let grayed = HDRToneMapper.color(0.4, 0.2, 0.1, settings: gray)
        XCTAssertEqual(grayed.0, grayed.2, accuracy: 0.00001)
        // Vibrance lifts a muted color more than a saturated one.
        var vivid = HDRSettings(); vivid.vibrance = 1
        let muted = HDRToneMapper.color(0.3, 0.28, 0.26, settings: vivid), strong = HDRToneMapper.color(0.4, 0.05, 0.02, settings: vivid)
        XCTAssertGreaterThan((muted.0 - muted.2) / (0.3 - 0.26), (strong.0 - strong.2) / (0.4 - 0.02))
        // Old projects and presets decode with the color sliders at 0.
        let old = try JSONDecoder().decode(HDRSettings.self, from: Data(#"{"compression":0.5}"#.utf8))
        XCTAssertFalse(old.hasColor)
    }
}
