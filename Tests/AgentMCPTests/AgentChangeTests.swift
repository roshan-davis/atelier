import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

/// Undo of an agent's own change, with Easel-shaped items (layers named by string ids), so the
/// change log stays app-neutral.
final class AgentChangeTests: XCTestCase {
    struct LayerState: Equatable, Sendable {
        var opacity: Int
        var name: String
    }

    func testUndoRestoresBeforeStatesWhileLatest() {
        var log = AgentChangeLog<String, LayerState>()
        let change = log.record(clientID: "docent", clientName: "Docent", title: "Fade layers", targets: ["sky", "tree"],
                                before: ["sky": .init(opacity: 100, name: "Sky"), "tree": .init(opacity: 80, name: "Tree")],
                                after: ["sky": .init(opacity: 50, name: "Sky"), "tree": .init(opacity: 50, name: "Tree")])
        XCTAssertEqual(change.id, "c-1")
        let plan = log.undoPlan("c-1", clientID: "docent", current: change.after)
        XCTAssertEqual(try plan.get(), change.before)
        log.markUndone("c-1")
        XCTAssertEqual(log.undoPlan("c-1", clientID: "docent", current: change.before), .failure(.alreadyUndone("c-1")))
    }

    func testOnlyTheOwnerUndoesButThePersonMay() {
        var log = AgentChangeLog<String, LayerState>()
        let change = log.record(clientID: "docent", clientName: "Docent", title: "Rename", targets: ["sky"],
                                before: ["sky": .init(opacity: 100, name: "Sky")], after: ["sky": .init(opacity: 100, name: "Clouds")])
        XCTAssertEqual(log.undoPlan(change.id, clientID: "opencode", current: change.after),
                       .failure(.notYours(change.id, owner: "Docent")))
        // nil is the person, from the notice's Undo button.
        XCTAssertNoThrow(try log.undoPlan(change.id, clientID: nil, current: change.after).get())
    }

    func testALaterManualEditBlocksUndo() {
        var log = AgentChangeLog<String, LayerState>()
        let change = log.record(clientID: "docent", clientName: "Docent", title: "Fade", targets: ["sky", "tree"],
                                before: ["sky": .init(opacity: 100, name: "Sky"), "tree": .init(opacity: 100, name: "Tree")],
                                after: ["sky": .init(opacity: 40, name: "Sky"), "tree": .init(opacity: 40, name: "Tree")])
        var now = change.after
        now["tree"]?.opacity = 70
        let refusal = log.undoPlan(change.id, clientID: "docent", current: now)
        XCTAssertEqual(refusal, .failure(.changedSince(change.id, items: ["tree"])))
        if case .failure(let reason) = refusal { XCTAssertTrue(reason.message.contains("overwrite")) }
    }

    func testALaterAgentChangeOnTheSameItemsComesFirst() {
        var log = AgentChangeLog<String, LayerState>()
        let first = log.record(clientID: "docent", clientName: "Docent", title: "Fade", targets: ["sky"],
                               before: ["sky": .init(opacity: 100, name: "Sky")], after: ["sky": .init(opacity: 50, name: "Sky")])
        let second = log.record(clientID: "opencode", clientName: "Terminal", title: "Fade more", targets: ["sky"],
                                before: ["sky": .init(opacity: 50, name: "Sky")], after: ["sky": .init(opacity: 50, name: "Sky")])
        // Same state as `first` left it, but a later change is on top: undo that one first.
        XCTAssertEqual(log.undoPlan(first.id, clientID: "docent", current: second.after),
                       .failure(.laterChange(first.id, later: second.id)))
        log.markUndone(second.id)
        XCTAssertNoThrow(try log.undoPlan(first.id, clientID: "docent", current: first.after).get())
    }

    func testGoneItemsAndUnknownAndCantUndo() {
        var log = AgentChangeLog<String, LayerState>()
        let change = log.record(clientID: "docent", clientName: "Docent", title: "Fade", targets: ["sky"],
                                before: ["sky": .init(opacity: 100, name: "Sky")], after: ["sky": .init(opacity: 50, name: "Sky")])
        XCTAssertEqual(log.undoPlan(change.id, clientID: "docent", current: [:]), .failure(.gone(change.id, items: ["sky"])))
        XCTAssertEqual(log.undoPlan("c-99", clientID: "docent", current: [:]), .failure(.unknown("c-99")))
        let copy = log.record(clientID: "docent", clientName: "Docent", title: "Duplicate", targets: ["tree"],
                              before: [:], after: [:], cantUndo: "it made new layers.")
        XCTAssertTrue(copy.changedNothing)
        XCTAssertEqual(log.undoPlan(copy.id, clientID: "docent", current: [:]),
                       .failure(.cantUndo(copy.id, reason: "it made new layers.")))
    }

    func testCapacityKeepsTheNewest() {
        var log = AgentChangeLog<String, LayerState>(capacity: 2)
        for index in 1...3 {
            log.record(clientID: "docent", clientName: "Docent", title: "Step \(index)", targets: [], before: [:], after: [:])
        }
        XCTAssertEqual(log.changes.map(\.id), ["c-2", "c-3"])
        XCTAssertNil(log.change("c-1"))
    }
}

/// Parameter checks with "did you mean", on an Easel-shaped parameter type.
final class ParameterCheckTests: XCTestCase {
    enum BlendChoice: String, AgentEnum { case normal, multiply, screen }

    struct LayerParameters: ActionParameters, Hashable {
        var opacity: Int
        var blend: BlendChoice?
        var tags: [String]?
        static let example = LayerParameters(opacity: 50, blend: .multiply, tags: ["sky"])
        static let fieldNotes = ["opacity": FieldNote("Percent.", minimum: 0, maximum: 100)]
    }

    let schema = ParameterSchema.of(LayerParameters.self)

    func testGoodParametersDecode() throws {
        let decoded = try ParameterCheck.decode(LayerParameters.self, from: ["opacity": .int(30), "blend": .string("screen")]).get()
        XCTAssertEqual(decoded, LayerParameters(opacity: 30, blend: .screen, tags: nil))
        // A whole number written as 30.0 is still a whole number; null means "not given".
        XCTAssertNoThrow(try ParameterCheck.decode(LayerParameters.self, from: ["opacity": .number(30), "tags": .null]).get())
    }

    func testUnknownFieldSuggestsTheClosest() {
        let problems = ParameterCheck.problems(["opacity": .int(1), "blnd": .string("normal")], against: schema)
        XCTAssertEqual(problems, ["Unknown parameter \"blnd\". Did you mean \"blend\"?"])
    }

    func testWrongChoiceListsTheChoicesAndSuggests() {
        let problems = ParameterCheck.problems(["opacity": .int(1), "blend": .string("multipy")], against: schema)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("normal, multiply, screen"))
        XCTAssertTrue(problems[0].contains("Did you mean \"multiply\"?"))
    }

    func testMissingTypesAndRanges() {
        XCTAssertEqual(ParameterCheck.problems([:], against: schema), ["\"opacity\" is required."])
        XCTAssertEqual(ParameterCheck.problems(["opacity": .string("half")], against: schema),
                       ["\"opacity\" must be a whole number."])
        XCTAssertEqual(ParameterCheck.problems(["opacity": .int(120)], against: schema),
                       ["\"opacity\" must be at most 100."])
        XCTAssertEqual(ParameterCheck.problems(["opacity": .int(5), "tags": .array([.int(1)])], against: schema),
                       ["\"tags[0]\" must be text."])
    }

    func testNoParametersSaysSo() {
        let problems = ParameterCheck.problems(["x": .int(1)], against: .of(NoParameters.self))
        XCTAssertEqual(problems, ["Unknown parameter \"x\". This takes no parameters."])
    }
}

/// command_run's checks against an Easel-shaped catalog.
final class CommandRunToolTests: XCTestCase {
    struct OpacityParameters: ActionParameters, Hashable {
        var opacity: Int
        static let example = OpacityParameters(opacity: 50)
    }

    let catalog = ActionCatalog(app: "Sketch", actions: [
        Action<NoParameters>("document.list", "List", place: "Window", summary: "Lists documents.", kind: .reads).descriptor,
        Action<NoParameters>("view.zoomIn", "Zoom In", place: "View > Zoom In", summary: "Zooms in.", kind: .view).descriptor,
        Action<OpacityParameters>("layer.setOpacity", "Set Opacity", place: "Layer > Opacity", summary: "Sets opacity.",
                                  kind: .edit, targets: TargetKind("layers")).descriptor,
        Action<NoParameters>("filter.blur", "Blur", place: "Filter > Blur", summary: "Blurs.", kind: .edit).descriptor,
        Action<NoParameters>("layer.delete", "Delete Layer", place: "Layer > Delete", summary: "Deletes.", kind: .deletes).descriptor,
        Action<NoParameters>("file.export", "Export…", place: "File > Export…", summary: "Exports.", kind: .writesFiles).descriptor,
        Action<NoParameters>("help.tips", "Tips", place: "Help > Tips", summary: "Shows tips.", kind: .view,
                             hidden: "A cheat sheet for the person.").descriptor,
    ])

    /// Layers are organizing; filters are editing.
    func editProfile(_ action: ActionDescriptor) -> AgentProfile {
        action.id.rawValue.hasPrefix("filter.") ? .edit : .organize
    }

    func check(_ arguments: [String: JSONValue], profile: AgentProfile = .organize, ceiling: AgentProfile = .organize)
        -> Result<CommandRunTool.Checked, ParameterCheck.Problems> {
        CommandRunTool.check(arguments, catalog: catalog, profile: profile, ceiling: ceiling, editProfile: editProfile)
    }

    func message(_ result: Result<CommandRunTool.Checked, ParameterCheck.Problems>) -> String? {
        if case .failure(let problems) = result { return problems.text }
        return nil
    }

    func testRunsAnExposedCommandWithCheckedParameters() throws {
        let checked = try check(["id": .string("layer.setOpacity"), "parameters": .object(["opacity": .int(30)])]).get()
        XCTAssertEqual(checked.action.id, "layer.setOpacity")
        XCTAssertEqual(try JSONDecoder().decode(OpacityParameters.self, from: checked.parameters).opacity, 30)
        XCTAssertNoThrow(try check(["id": .string("view.zoomIn")]).get())
    }

    func testUnknownIdSuggests() {
        XCTAssertEqual(message(check(["id": .string("layer.setOpacty")])),
                       "There is no command \"layer.setOpacty\". Did you mean \"layer.setOpacity\"? Use command_list to see the commands.")
    }

    func testNeverHiddenProfileAndCeiling() {
        XCTAssertTrue(message(check(["id": .string("layer.delete")]))?.contains("isn't available to agents") == true)
        XCTAssertTrue(message(check(["id": .string("help.tips")]))?.contains("A cheat sheet") == true)
        XCTAssertTrue(message(check(["id": .string("view.zoomIn")], profile: .look))?.contains("needs the Organize profile") == true)
        // Allowed Edit, but this version runs only up to Organize.
        XCTAssertTrue(message(check(["id": .string("filter.blur")], profile: .edit))?.contains("later version") == true)
        XCTAssertNoThrow(try check(["id": .string("filter.blur")], profile: .edit, ceiling: .edit).get())
        XCTAssertTrue(message(check(["id": .string("file.export")], profile: .everything, ceiling: .everything)) == nil)
    }

    func testBadParametersNameTheCommand() {
        let text = message(check(["id": .string("layer.setOpacity"), "parameters": .object(["opactiy": .int(3)])]))
        XCTAssertEqual(text, "layer.setOpacity: Unknown parameter \"opactiy\". Did you mean \"opacity\"? "
                       + "layer.setOpacity: \"opacity\" is required.")
        XCTAssertTrue(message(check(["id": .string("view.zoomIn"), "parameters": .int(3)]))?.contains("must be an object") == true)
        XCTAssertTrue(message(check([:]))?.contains("needs \"id\"") == true)
    }

    func testToolSchemaHasTheAppsTargets() {
        let tool = CommandRunTool.tool(targetProperties: ["layers": .object(["type": .string("array")])], description: "")
        XCTAssertEqual(tool.name, "command_run")
        XCTAssertNotNil(tool.inputSchema["properties"]?["layers"])
        XCTAssertEqual(tool.inputSchema["required"], .array([.string("id")]))
        XCTAssertFalse(tool.readOnly)
    }
}
