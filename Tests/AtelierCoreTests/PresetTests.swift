import Foundation
import XCTest
@testable import AtelierCore

final class PresetTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierPresets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Built-in packs

    func testBuiltInPacksAreInOrderWithFixedIDs() {
        let presets = DevelopPreset.builtIn
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        var groups: [String] = []
        for preset in presets where groups.last != preset.group { groups.append(preset.group) }
        XCTAssertEqual(groups, DevelopPreset.builtInGroups)
        // The original five keep the IDs photos and import settings already point at.
        XCTAssertEqual(presets.first { $0.name == "Punchy" }?.id.uuidString, "6E2B6B5A-0002-4C5E-9A7E-0A7E11E50002")
        XCTAssertEqual(presets.first { $0.name == "Gold 200" }?.id.uuidString, "6E2B6B5A-0202-4C5E-9A7E-0A7E11E50202")
        for group in DevelopPreset.builtInGroups {
            let count = presets.filter { $0.group == group }.count
            XCTAssertTrue((4...9).contains(count), "\(group) has \(count) presets")
        }
        XCTAssertTrue(presets.allSatisfy(\.isBuiltIn))
    }

    func testPackPresetsCarryOnlyTheLook() {
        let photoParts: Set<DevelopPreset.Part> = [.profile, .whiteBalance, .lensCorrections, .transform, .crop, .masks]
        for preset in DevelopPreset.builtIn {
            XCTAssertTrue(preset.parts.isDisjoint(with: photoParts), preset.name)
            XCTAssertTrue(preset.parts.contains(.treatment), preset.name)
            // A pack preset never resets the photo's exposure.
            XCTAssertFalse(preset.parts.contains(.exposure), preset.name)
        }
        var base = DevelopSettings()
        base.exposure = 0.7
        base.sharpening = 60
        base.monochrome = true
        let teal = DevelopPreset.builtIn.first { $0.name == "Teal & Orange" }!
        let result = teal.applied(to: base)
        XCTAssertEqual(result.exposure, 0.7)
        XCTAssertEqual(result.sharpening, 60)
        XCTAssertFalse(result.monochrome)
        XCTAssertEqual(result.contrast, 28)
        let noir = DevelopPreset.builtIn.first { $0.name == "Noir" }!
        XCTAssertTrue(noir.applied(to: .neutral).monochrome)
    }

    func testBuiltInNamesAreUniqueWithinEachPack() {
        for group in DevelopPreset.builtInGroups {
            let names = DevelopPreset.builtIn.filter { $0.group == group }.map(\.name)
            XCTAssertEqual(Set(names).count, names.count, group)
        }
        // Presets that moved packs or were added keep IDs from their own pack's numbers.
        XCTAssertEqual(DevelopPreset.builtIn.first { $0.name == "Muted Chrome" }?.id.uuidString,
                       "6E2B6B5A-0801-4C5E-9A7E-0A7E11E50801")
        XCTAssertEqual(DevelopPreset.builtIn.first { $0.name == "Teal & Orange" }?.id.uuidString,
                       "6E2B6B5A-0701-4C5E-9A7E-0A7E11E50701")
    }

    // MARK: Recent

    func testRecentPresetsAreNewestFirstWithoutRepeats() {
        let a = UUID(), b = UUID(), c = UUID()
        var ids: [UUID] = []
        ids = RecentPresets.adding(a, to: ids)
        ids = RecentPresets.adding(b, to: ids)
        ids = RecentPresets.adding(a, to: ids)
        XCTAssertEqual(ids, [a, b])
        ids = RecentPresets.adding(c, to: ids, limit: 2)
        XCTAssertEqual(ids, [c, a])
        for _ in 0..<10 { ids = RecentPresets.adding(UUID(), to: ids) }
        XCTAssertEqual(ids.count, RecentPresets.limit)
    }

    func testRecentPresetsSkipMissingOnes() {
        let kept = DevelopPreset.builtIn[3], other = DevelopPreset.builtIn[0]
        let found = RecentPresets.presets([UUID(), kept.id, other.id], in: [other, kept])
        XCTAssertEqual(found.map(\.id), [kept.id, other.id])
    }

    func testBuiltInGroupNamesAreReserved() {
        XCTAssertTrue(DevelopPreset.isBuiltInGroup("film"))
        XCTAssertTrue(DevelopPreset.isBuiltInGroup("Black & White"))
        XCTAssertFalse(DevelopPreset.isBuiltInGroup(DevelopPreset.defaultGroup))
        XCTAssertFalse(DevelopPreset.isBuiltInGroup("Weddings"))
    }

    // MARK: Parts and coding

    func testOldPresetsKeepExposureWithTone() throws {
        let settings = try DevelopSettings().encoded()
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Old","group":"User Presets","parts":["tone","presence","futurePart"],"settings":\#(settings),"isBuiltIn":false}]"#
        let decoded = try JSONDecoder().decode([DevelopPreset].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.first?.parts, [.tone, .exposure, .presence])

        let current = DevelopPreset(name: "New", parts: [.tone], settings: DevelopSettings())
        let roundTrip = try JSONDecoder().decode(DevelopPreset.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip, current)
    }

    func testChangedParts() {
        var settings = DevelopSettings()
        XCTAssertTrue(DevelopPreset.Part.changed(in: settings).isEmpty)
        settings.contrast = 10
        settings.monochrome = true
        settings.setPoints([.init(x: 0, y: 0.1), .init(x: 1, y: 1)], for: .rgb)
        XCTAssertEqual(DevelopPreset.Part.changed(in: settings), [.tone, .treatment, .toneCurve])
    }

    // MARK: Amount

    func testAmountScalesWhatThePresetMoves() {
        var look = DevelopSettings()
        look.contrast = 40
        look[.gradeShadowsHue] = 200
        look[.gradeShadowsSat] = 20
        let preset = DevelopPreset(name: "Look", parts: [.tone, .colorGrading], settings: look)
        var base = DevelopSettings()
        base.contrast = 10
        base.exposure = 0.5

        XCTAssertEqual(preset.applied(to: base, amount: 1), preset.applied(to: base))
        XCTAssertEqual(preset.applied(to: base, amount: 0), base)
        let half = preset.applied(to: base, amount: 0.5)
        XCTAssertEqual(half.contrast, 25, accuracy: 1e-9)
        XCTAssertEqual(half[.gradeShadowsSat], 10, accuracy: 1e-9)
        XCTAssertEqual(half[.gradeShadowsHue], 200)
        XCTAssertEqual(half.exposure, 0.5)
        let double = preset.applied(to: base, amount: 2)
        XCTAssertEqual(double.contrast, 70, accuracy: 1e-9)
        XCTAssertEqual(preset.applied(to: base, amount: 4).contrast, 100)
    }

    func testAmountBlendsCurves() {
        var look = DevelopSettings()
        look.setPoints([.init(x: 0, y: 0.2), .init(x: 1, y: 1)], for: .rgb)
        let preset = DevelopPreset(name: "Lift", parts: [.toneCurve], settings: look)
        let half = preset.applied(to: .neutral, amount: 0.5)
        XCTAssertEqual(DevelopRenderer.pointCurveValue(half.points(for: .rgb), at: 0), 0.1, accuracy: 0.001)
        XCTAssertEqual(DevelopRenderer.pointCurveValue(half.points(for: .rgb), at: 1), 1, accuracy: 0.001)
    }

    // MARK: Store

    func testStoreOrdersAndManagesGroups() throws {
        let store = PresetStore(fileURL: workDir.appendingPathComponent("Presets.json"))
        let settings = DevelopSettings()
        try store.save([
            DevelopPreset(name: "b", group: "Weddings", settings: settings),
            DevelopPreset(name: "a", group: "Weddings", settings: settings),
            DevelopPreset(name: "z", group: DevelopPreset.defaultGroup, settings: settings),
            DevelopPreset(name: "m", group: "Art", settings: settings),
        ])
        let all = store.all()
        XCTAssertEqual(all.prefix(4).map(\.name), ["z", "m", "a", "b"])
        XCTAssertEqual(Array(all.dropFirst(4)), DevelopPreset.builtIn)

        try store.renameGroup("Weddings", to: "Events")
        XCTAssertEqual(store.userPresets().filter { $0.group == "Events" }.count, 2)
        XCTAssertEqual(try store.deleteGroup("Events"), 2)
        XCTAssertEqual(store.userPresets().map(\.name).sorted(), ["m", "z"])
        // Built-in presets are never written.
        try store.save(DevelopPreset.builtIn[0])
        XCTAssertEqual(store.userPresets().count, 2)
    }

    func testStoreNeverOverwritesAFileItCantRead() throws {
        let url = workDir.appendingPathComponent("Presets.json")
        try Data("not json".utf8).write(to: url)
        let store = PresetStore(fileURL: url)
        XCTAssertTrue(store.userPresets().isEmpty)
        XCTAssertThrowsError(try store.save(DevelopPreset(name: "New", settings: DevelopSettings())))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    // MARK: Black & White

    func testMonochromeIsStoredAndApplied() throws {
        var settings = DevelopSettings()
        settings.monochrome = true
        settings[.gray(.blue)] = -40
        XCTAssertFalse(settings.isNeutral)
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        XCTAssertEqual(DevelopSettings.Parameter.gray(.blue).panel, .hsl)
        XCTAssertEqual(DevelopSettings.Parameter.gray(.blue).label, "Blue")
        XCTAssertNil(DevelopSettings.Parameter.gray(.blue).hslBand)

        let preset = DevelopPreset(name: "BW", parts: [.treatment], settings: settings)
        let applied = preset.applied(to: .neutral)
        XCTAssertTrue(applied.monochrome)
        XCTAssertEqual(applied[.gray(.blue)], -40)
    }

    func testBWMixMakesGraysAndMovesColors() {
        let sky: RGB = (0.3, 0.45, 0.9)
        var settings = DevelopSettings()
        settings.monochrome = true
        let plain = BWMix(settings).apply(sky)
        XCTAssertEqual(plain.0, plain.1, accuracy: 1e-9)
        XCTAssertEqual(plain.1, plain.2, accuracy: 1e-9)
        XCTAssertEqual(plain.0, luma(sky), accuracy: 1e-9)

        settings[.gray(.blue)] = -100
        XCTAssertLessThan(BWMix(settings).apply(sky).0, plain.0 - 0.1)
        settings[.gray(.blue)] = 100
        XCTAssertGreaterThan(BWMix(settings).apply(sky).0, plain.0 + 0.1)
        // Grays don't move.
        XCTAssertEqual(BWMix(settings).apply((0.4, 0.4, 0.4)).0, 0.4, accuracy: 1e-9)

        var color = DevelopSettings()
        XCTAssertNil(ColorLUT.cube(for: color))
        color.monochrome = true
        XCTAssertNotNil(ColorLUT.cube(for: color))
    }
}
