import AgentActions
import AgentMCP
@testable import AtelierActions
import XCTest

/// The Organize tools' schemas come from Swift types and their checks catch an agent's typos.
final class AtelierAgentToolsTests: XCTestCase {
    func testTypedToolSchemasReadCleanly() {
        for (name, schema) in AtelierAgentTools.parameterSchemas {
            XCTAssertEqual(schema.problems, [], name)
        }
        let names = AtelierAgentTools.organizeTools.map(\.name)
        XCTAssertEqual(names, ["show", "set_metadata", "organize", "undo_change", "command_run"])
        XCTAssertEqual(Set(names).count, names.count)
        for tool in AtelierAgentTools.organizeTools { XCTAssertFalse(tool.readOnly, tool.name) }
    }

    /// Models read "so the person sees what you found" as showing the photo in the chat.
    func testShowSaysItOnlyChangesAteliersWindow() {
        XCTAssertTrue(AtelierAgentTools.show.description.contains("Changes only Atelier's window"))
        XCTAssertTrue(AtelierAgentTools.show.description.contains("it doesn't show the photo in a chat (use get_preview for that)"))
    }

    func testSetMetadataSchemaUsesSnakeCaseAndChoices() {
        let properties = AtelierAgentTools.setMetadata.inputSchema["properties"]
        XCTAssertNotNil(properties?["add_keywords"])
        XCTAssertNotNil(properties?["remove_keywords"])
        XCTAssertEqual(properties?["label"]?["enum"],
                       .array(["red", "yellow", "green", "blue", "purple", "none"].map { .string($0) }))
        XCTAssertEqual(properties?["rating"]?["maximum"], .number(5))
        XCTAssertEqual(AtelierAgentTools.setMetadata.inputSchema["required"], .array([]))
        XCTAssertEqual(AtelierAgentTools.show.inputSchema["required"], .array([.string("ids")]))
    }

    func testSetMetadataDecodesAndCatchesTypos() throws {
        let parameters = try ParameterCheck.decode(SetMetadataParameters.self, from: [
            "ids": .array([.int(7), .int(8)]), "rating": .int(3), "flag": .string("picked"),
            "add_keywords": .array([.string("sunset")]),
        ]).get()
        XCTAssertEqual(parameters.ids, [7, 8])
        XCTAssertEqual(parameters.rating, 3)
        XCTAssertEqual(parameters.flag, .picked)
        XCTAssertEqual(parameters.addKeywords, ["sunset"])
        XCTAssertFalse(parameters.changesNothing)
        XCTAssertTrue(SetMetadataParameters(ids: [1]).changesNothing)

        guard case .failure(let problems) = ParameterCheck.decode(SetMetadataParameters.self, from: [
            "ids": .array([.int(7)]), "ratng": .int(3), "flag": .string("pick"),
        ]) else { return XCTFail("expected problems") }
        XCTAssertTrue(problems.text.contains("Did you mean \"rating\"?"), problems.text)
        XCTAssertTrue(problems.text.contains("Did you mean \"picked\"?"), problems.text)
    }

    func testSetMetadataAddsNotes() throws {
        XCTAssertNotNil(AtelierAgentTools.setMetadata.inputSchema["properties"]?["add_note"])
        let parameters = try ParameterCheck.decode(SetMetadataParameters.self, from: [
            "ids": .array([.int(7)]), "add_note": .string("Eyes closed"),
        ]).get()
        XCTAssertEqual(parameters.addNote, "Eyes closed")
        XCTAssertFalse(parameters.changesNothing)
        XCTAssertTrue(SetMetadataParameters(ids: [1], addNote: "  \n ").changesNothing)
    }

    func testDevelopEditsNeedEditAndLibraryEditsOrganize() {
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.setRating.descriptor), .organize)
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.addToCollection.descriptor), .organize)
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.createVirtualCopy.descriptor), .organize)
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.applyPreset.descriptor), .edit)
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.resetSettings.descriptor), .edit)
        XCTAssertEqual(AtelierAgentTools.editProfile(AtelierAction.matchLook.descriptor), .edit)
    }

    /// Both layers agree: every exposed command an Organize client may see in command_list,
    /// command_run accepts (with its example parameters), and nothing else.
    func testCommandRunAgreesWithCommandList() throws {
        for profile in [AgentProfile.organize, .edit] {
            let listed = CommandListTool.list(catalog: AtelierAction.catalog, profile: profile, search: nil,
                                              editProfile: AtelierAgentTools.editProfile, isEnabled: { _ in true })
            let ids = Set(listed["commands"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [])
            XCTAssertFalse(ids.isEmpty)
            for action in AtelierAction.catalog.actions {
                let example = JSONValue(parsing: Data(Self.exampleJSON(action).utf8))?.objectValue ?? [:]
                let result = CommandRunTool.check(["id": .string(action.id.rawValue), "parameters": .object(example)],
                                                  catalog: AtelierAction.catalog, profile: profile,
                                                  ceiling: AtelierAgentTools.runCeiling, editProfile: AtelierAgentTools.editProfile)
                switch result {
                case .success: XCTAssertTrue(ids.contains(action.id.rawValue), "\(profile): \(action.id) runs but isn't listed")
                case .failure(let problems):
                    XCTAssertFalse(ids.contains(action.id.rawValue), "\(profile): \(action.id) listed but refused: \(problems.text)")
                }
            }
        }
        // With Edit, Develop commands run; with Organize they don't.
        let rotate: [String: JSONValue] = ["id": .string(AtelierAction.rotateRight.id.rawValue)]
        for (profile, runs) in [(AgentProfile.organize, false), (.edit, true)] {
            let result = CommandRunTool.check(rotate, catalog: AtelierAction.catalog, profile: profile,
                                              ceiling: AtelierAgentTools.runCeiling, editProfile: AtelierAgentTools.editProfile)
            if case .success = result { XCTAssertTrue(runs, "\(profile)") } else { XCTAssertFalse(runs, "\(profile)") }
        }
        // Deletes are never runnable, whatever the profile.
        for action in AtelierAction.catalog.actions where action.kind == .deletes {
            let result = CommandRunTool.check(["id": .string(action.id.rawValue)], catalog: AtelierAction.catalog,
                                              profile: .everything, ceiling: .everything,
                                              editProfile: AtelierAgentTools.editProfile)
            if case .success = result { XCTFail("\(action.id) is a delete and ran") }
        }
    }

    /// A value of the action's parameters, from the schema: the first choice, 1, true, "x".
    static func exampleJSON(_ action: ActionDescriptor) -> String {
        var members: [String: JSONValue] = [:]
        for field in action.parameters.fields where field.required {
            members[field.name] = value(field.type)
        }
        return JSONValue.object(members).compactText
    }

    static func value(_ type: ParameterSchema.FieldType) -> JSONValue {
        switch type {
        case .boolean: return .bool(true)
        case .integer: return .int(1)
        case .number: return .number(1)
        case .string: return .string("00000000-0000-0000-0000-000000000000")
        case .choice(let choices): return .string(choices[0])
        case .list(let element): return .array([value(element)])
        }
    }
}
