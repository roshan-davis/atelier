import AgentActions
import AgentMCP
@testable import AtelierActions
import XCTest

/// The Develop tools' rules: slider names, set and add, clamping and refusals.
final class AtelierDevelopToolsTests: XCTestCase {
    let sliders: [String: AgentSlider] = Dictionary(uniqueKeysWithValues: [
        ("exposure", -5.0...5.0), ("contrast", -100.0...100.0), ("temperature", 2000.0...50000.0),
        ("hue_red", -100.0...100.0), ("grade_shadows_hue", 0.0...360.0), ("point_1_hue", 0.0...360.0),
    ].map { ($0.0, AgentSlider(name: $0.0, range: $0.1)) })

    func testSchemasReadCleanlyAndNeedEdit() {
        for (name, schema) in AtelierAgentTools.developParameterSchemas {
            XCTAssertEqual(schema.problems, [], name)
        }
        XCTAssertEqual(AtelierAgentTools.editTools.map(\.name),
                       ["adjust", "auto", "apply_preset", "sync", "reset", "crop", "add_mask", "match_look"])
        let all = (AtelierAgentTools.organizeTools + AtelierAgentTools.editTools).map(\.name)
        XCTAssertEqual(Set(all).count, all.count)
        let properties = AtelierAgentTools.adjust.inputSchema["properties"]
        XCTAssertEqual(properties?["exposure"]?["type"], .string("number"))
        XCTAssertEqual(properties?["mode"]?["enum"], .array([.string("set"), .string("add")]))
        XCTAssertEqual(AtelierAgentTools.sync.inputSchema["required"], .array([.string("from")]))
        XCTAssertEqual(AtelierAgentTools.sync.inputSchema["properties"]?["parts"]?["items"]?["enum"]?.arrayValue?.count,
                       DevelopPart.allCases.count)
        XCTAssertEqual(AtelierAgentTools.runCeiling, .edit)
    }

    func testSnakeNames() {
        XCTAssertEqual(AdjustRules.snakeName("exposure"), "exposure")
        XCTAssertEqual(AdjustRules.snakeName("hueRed"), "hue_red")
        XCTAssertEqual(AdjustRules.snakeName("gradeShadowsHue"), "grade_shadows_hue")
        XCTAssertEqual(AdjustRules.snakeName("point1Hue"), "point_1_hue")
        XCTAssertEqual(AdjustRules.snakeName("lensDefringePurpleHueLow"), "lens_defringe_purple_hue_low")
    }

    func testChangesReadNamedSlidersAndOther() throws {
        let parameters = try ParameterCheck.decode(AdjustParameters.self, from: [
            "selection": .bool(true), "exposure": .number(0.5), "mode": .string("add"),
            "other": .array([.string("hue_red=+10"), .string(" grade_shadows_hue = 210 ")]),
        ]).get()
        let changes = try AdjustRules.changes(parameters, sliders: sliders).get()
        XCTAssertEqual(changes.map(\.0.name), ["exposure", "hue_red", "grade_shadows_hue"])
        XCTAssertEqual(changes.map(\.1), [0.5, 10, 210])
        XCTAssertEqual(AdjustRules.title(changes, mode: .add), "Exposure +0.50, Hue Red +10, Grade Shadows Hue +210")
    }

    func testChangesRefuseTyposAndTwice() {
        let typo = AdjustParameters(current: true, exposure: 1, other: ["hue_rd=10", "contrast", "contrast=abc"])
        guard case .failure(let problems) = AdjustRules.changes(typo, sliders: sliders) else { return XCTFail("expected problems") }
        XCTAssertTrue(problems.text.contains("Did you mean \"hue_red\"?"), problems.text)
        XCTAssertTrue(problems.text.contains("isn't \"name=value\""), problems.text)
        XCTAssertTrue(problems.text.contains("abc isn't a number"), problems.text)

        let twice = AdjustParameters(current: true, exposure: 1, other: ["exposure=2"])
        guard case .failure(let again) = AdjustRules.changes(twice, sliders: sliders) else { return XCTFail("expected problems") }
        XCTAssertTrue(again.text.contains("exposure is given twice"), again.text)

        guard case .failure(let none) = AdjustRules.changes(AdjustParameters(current: true), sliders: sliders) else {
            return XCTFail("expected problems")
        }
        XCTAssertTrue(none.text.contains("at least one slider"), none.text)
    }

    func testSetAddAndClamp() {
        XCTAssertEqual(AdjustRules.value(current: 1, asked: 0.5, mode: .add, range: -5...5).value, 1.5)
        XCTAssertEqual(AdjustRules.value(current: 1, asked: 0.5, mode: .set, range: -5...5).value, 0.5)
        let clamped = AdjustRules.value(current: 4, asked: 3, mode: .add, range: -5...5)
        XCTAssertEqual(clamped.value, 5)
        XCTAssertTrue(clamped.clamped)
        XCTAssertFalse(AdjustRules.value(current: 0, asked: -100, mode: .set, range: -100...100).clamped)
        let slider = AgentSlider(name: "temperature", range: 2000...50000)
        XCTAssertEqual(AdjustRules.title([(slider, 6500)], mode: .set), "Temperature to 6500 K")
    }

    func testSyncDefaultLeavesCropAndMasks() {
        XCTAssertFalse(DevelopPart.syncDefault.contains(.crop))
        XCTAssertFalse(DevelopPart.syncDefault.contains(.masks))
        XCTAssertEqual(DevelopPart.syncDefault.count, DevelopPart.allCases.count - 2)
    }
}
