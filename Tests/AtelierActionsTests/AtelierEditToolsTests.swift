import AgentActions
import AgentMCP
@testable import AtelierActions
import XCTest

/// The rules of crop, add_mask, auto and match_look: what a call asks for, ranges and refusals.
final class AtelierEditToolsTests: XCTestCase {
    func decode<P: ActionParameters>(_ type: P.Type, _ json: [String: JSONValue]) throws -> P {
        try ParameterCheck.decode(P.self, from: json).get()
    }

    func problems<T>(_ result: Result<T, ParameterCheck.Problems>, file: StaticString = #filePath,
                     line: UInt = #line) -> String {
        guard case .failure(let problems) = result else {
            XCTFail("expected problems", file: file, line: line)
            return ""
        }
        return problems.text
    }

    func testSchemas() {
        let crop = AtelierAgentTools.crop.inputSchema["properties"]
        XCTAssertEqual(crop?["rotate"]?["enum"], .array([.string("left"), .string("right")]))
        XCTAssertEqual(crop?["box"]?["type"], .string("array"))
        XCTAssertEqual(crop?["angle"]?["minimum"], .number(-45))
        let mask = AtelierAgentTools.addMask.inputSchema
        XCTAssertEqual(mask["required"], .array([.string("kind")]))
        XCTAssertNotNil(mask["properties"]?["to_mask"])
        XCTAssertEqual(mask["properties"]?["parts"]?["items"]?["enum"]?.arrayValue?.count, AgentPeoplePart.allCases.count)
        XCTAssertNotNil(AtelierAgentTools.auto.inputSchema["properties"]?["white_balance"])
        XCTAssertEqual(AtelierAgentTools.matchLook.inputSchema["properties"]?["fit"]?["enum"],
                       .array([.string("same"), .string("each")]))
        XCTAssertEqual(AtelierAgentTools.measuringTools.map(\.name), ["auto", "match_look"])
        for tool in AtelierAgentTools.measuringTools {
            XCTAssertTrue(AtelierAgentTools.editTools.contains(tool))
        }
    }

    // MARK: crop

    func testAspectNames() {
        XCTAssertEqual(CropRules.aspect("original"), .original)
        XCTAssertEqual(CropRules.aspect(" Free "), .free)
        XCTAssertEqual(CropRules.aspect("4x5"), .ratio(0.8, label: "4 × 5"))
        XCTAssertEqual(CropRules.aspect("16:9")?.landscape ?? 0, 16.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(CropRules.aspect("4 × 5")?.landscape ?? 0, 1.25, accuracy: 1e-9)
        XCTAssertEqual(CropRules.aspect("1.5")?.landscape ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertNil(CropRules.aspect("square-ish"))
        XCTAssertNil(CropRules.aspect("0x5"))
    }

    func testCropPlanAndTitle() throws {
        let parameters = try decode(CropParameters.self, [
            "current": .bool(true), "rotate": .string("right"), "angle": .number(2), "aspect": .string("1x1"),
        ])
        let plan = try CropRules.plan(parameters).get()
        XCTAssertEqual(plan.title, "Rotate Right, Straighten 2.0°, Crop 1 × 1")
        XCTAssertEqual(plan.aspect, .ratio(1, label: "1 × 1"))
        XCTAssertFalse(plan.reset)
    }

    func testCropRefusals() {
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true))).contains("at least one"))
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true, angle: 50))).contains("-45 to 45"))
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true, aspect: "wide"))).contains("isn't original"))
        let both = CropRules.plan(CropParameters(current: true, aspect: "1x1", box: [0, 0, 0.5, 0.5]))
        XCTAssertTrue(problems(both).contains("not both"))
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true, box: [0.5, 0, 0.6, 0.5]))).contains("on the photo"))
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true, box: [0, 0, 1]))).contains("4 numbers"))
        XCTAssertTrue(problems(CropRules.plan(CropParameters(current: true, aspect: "free", orientation: .portrait)))
            .contains("locked aspect"))
    }

    // MARK: add_mask

    let maskSliders: [String: ClosedRange<Double>] = ["exposure": -4...4, "clarity": -100...100, "saturation": -100...100]

    func testMaskDefaultsAndTitle() throws {
        let plan = try MaskRules.plan(AddMaskParameters(current: true, kind: .linear), sliders: maskSliders).get()
        XCTAssertEqual(plan.start, [0.5, 0.2])
        XCTAssertEqual(plan.end, [0.5, 0.5])
        XCTAssertEqual(plan.title, "New Mask: Linear Gradient")
        let people = try MaskRules.plan(AddMaskParameters(current: true, kind: .people), sliders: maskSliders).get()
        XCTAssertEqual(people.parts, [.faceSkin, .bodySkin])
        let added = try MaskRules.plan(AddMaskParameters(current: true, kind: .radial, toMask: "Sky", combine: .subtract),
                                       sliders: maskSliders).get()
        XCTAssertEqual(added.title, "Subtract Radial Gradient: Sky")
    }

    func testDepthMaskTakesARangeOfDepths() throws {
        let plan = try MaskRules.plan(AddMaskParameters(current: true, kind: .depth), sliders: maskSliders).get()
        XCTAssertEqual(plan.range, [0, 30], "the nearest part of the photo by default")
        XCTAssertEqual(plan.title, "New Mask: Depth Range")
        let far = try MaskRules.plan(AddMaskParameters(current: true, kind: .depth, range: [60, 100], smoothness: 20),
                                     sliders: maskSliders).get()
        XCTAssertEqual(far.range, [60, 100])
        XCTAssertEqual(far.smoothness, 20)
        let wrong = MaskRules.plan(AddMaskParameters(current: true, kind: .depth, box: [0.1, 0.1, 0.2, 0.2]), sliders: maskSliders)
        guard case .failure = wrong else { return XCTFail("box isn't a depth field") }
    }

    func testMaskSettingsAreChecked() throws {
        let plan = try MaskRules.plan(AddMaskParameters(current: true, kind: .subject,
                                                        settings: ["exposure=+0.5", "Clarity = -20"]),
                                      sliders: maskSliders).get()
        XCTAssertEqual(plan.settings, [.init(name: "exposure", value: 0.5), .init(name: "clarity", value: -20)])
        let typo = MaskRules.plan(AddMaskParameters(current: true, kind: .subject, settings: ["exposre=1"]),
                                  sliders: maskSliders)
        XCTAssertTrue(problems(typo).contains("Did you mean \"exposure\"?"))
        let far = MaskRules.plan(AddMaskParameters(current: true, kind: .subject, settings: ["exposure=6"]),
                                 sliders: maskSliders)
        XCTAssertTrue(problems(far).contains("outside -4 to 4"))
    }

    func testMaskFieldsBelongToTheirKind() {
        let wrong = MaskRules.plan(AddMaskParameters(current: true, kind: .linear, center: [0.5, 0.5]), sliders: maskSliders)
        XCTAssertTrue(problems(wrong).contains("center is for radial, not linear"))
        let noBox = MaskRules.plan(AddMaskParameters(current: true, kind: .object), sliders: maskSliders)
        XCTAssertTrue(problems(noBox).contains("object needs box"))
        let offPhoto = MaskRules.plan(AddMaskParameters(current: true, kind: .object, box: [0.8, 0.8, 0.5, 0.5]),
                                      sliders: maskSliders)
        XCTAssertTrue(problems(offPhoto).contains("box: give"))
        let same = MaskRules.plan(AddMaskParameters(current: true, kind: .linear, start: [0.5, 0.5], end: [0.5, 0.5]),
                                  sliders: maskSliders)
        XCTAssertTrue(problems(same).contains("must differ"))
        let subtractNew = MaskRules.plan(AddMaskParameters(current: true, kind: .subject, combine: .subtract),
                                         sliders: maskSliders)
        XCTAssertTrue(problems(subtractNew).contains("needs to_mask"))
        let sliderOnExisting = MaskRules.plan(AddMaskParameters(current: true, kind: .subject, toMask: "Mask 1",
                                                                settings: ["exposure=1"]), sliders: maskSliders)
        XCTAssertTrue(problems(sliderOnExisting).contains("for a new mask"))
    }

    // MARK: auto and match_look

    func testAutoTitles() {
        XCTAssertEqual(AutoParameters(current: true).title, "Auto Tone")
        XCTAssertEqual(AutoParameters(current: true, whiteBalance: true).title, "Auto White Balance and Tone")
        XCTAssertEqual(AutoParameters(current: true, tone: false, whiteBalance: true).title, "White Balance: Auto")
        XCTAssertNil(AutoParameters(current: true, tone: false).title)
    }

    func testStudyNamesAreFoundLoosely() throws {
        XCTAssertEqual(try MatchLookRules.study(named: "The Matrix — Portrait").get(), 0)
        XCTAssertEqual(try MatchLookRules.study(named: "matrix - portrait").get(), 0)
        XCTAssertEqual(try MatchLookRules.study(named: "Mad Max: Fury Road - Desert Action").get(), 5)
        XCTAssertTrue(problems(MatchLookRules.study(named: "Blade Runner")).contains("The studies are"))
    }

    func testMatchLookChecks() {
        XCTAssertEqual(MatchLookRules.check(MatchLookParameters(current: true, reference: 3)), [])
        XCTAssertTrue(MatchLookRules.check(MatchLookParameters(current: true))[0].contains("needs reference"))
        XCTAssertTrue(MatchLookRules.check(MatchLookParameters(current: true, reference: 3, study: "x"))[0].contains("not both"))
        XCTAssertFalse(MatchLookRules.check(MatchLookParameters(current: true, reference: 3, strength: 120)).isEmpty)
        let nothing = MatchLookParameters(current: true, reference: 3, whiteBalance: false, tone: false, color: false)
        XCTAssertTrue(MatchLookRules.check(nothing)[0].contains("nothing to match"))
        var skinOnly = nothing
        skinOnly.skin = .match
        XCTAssertEqual(MatchLookRules.check(skinOnly), [])
    }
}
