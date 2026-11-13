import AgentActions
import AgentMCP
@testable import AtelierActions
import Foundation
import XCTest

final class AtelierBatchToolTests: XCTestCase {
    func testBatchToolsFollowTheProfile() {
        XCTAssertEqual(AtelierAgentTools.batchTools(profile: .look), [])
        let organize = AtelierAgentTools.batchTools(profile: .organize)
        XCTAssertTrue(organize.contains("set_metadata"))
        XCTAssertTrue(organize.contains("command_run"))
        XCTAssertFalse(organize.contains("undo_change"))
        XCTAssertFalse(organize.contains("adjust"))
        XCTAssertFalse(organize.contains("command_batch"))
        XCTAssertTrue(AtelierAgentTools.batchTools(profile: .edit).contains("adjust"))
    }

    func testAtomicTakesOnlyWhatCanBePutBack() {
        func refusal(_ tool: String, _ arguments: [String: JSONValue] = [:]) -> String? {
            AtelierAgentTools.atomicRefusal(.init(tool: tool, arguments: arguments))
        }
        XCTAssertNil(refusal("set_metadata"))
        XCTAssertNil(refusal("adjust"))
        XCTAssertNil(refusal("organize", ["add_to_collection": .int(3)]))
        XCTAssertNotNil(refusal("organize", ["virtual_copy": .bool(true)]))
        XCTAssertNotNil(refusal("show"))
        XCTAssertNil(refusal("command_run", ["id": .string(AtelierAction.setRating.id.rawValue)]))
        XCTAssertNotNil(refusal("command_run", ["id": .string(AtelierAction.createVirtualCopy.id.rawValue)]))
        let develop = AtelierAction.catalog.actions.first { $0.kind == .edit && AtelierAgentTools.editProfile($0) == .edit }
        XCTAssertNotNil(develop)
        if let develop { XCTAssertNotNil(refusal("command_run", ["id": .string(develop.id.rawValue)])) }
        let notEdit = AtelierAction.catalog.actions.first { $0.kind != .edit }
        if let notEdit { XCTAssertNotNil(refusal("command_run", ["id": .string(notEdit.id.rawValue)])) }
        // An unknown command is left for command_run to explain.
        XCTAssertNil(refusal("command_run", ["id": .string("photo.nothing")]))
    }

    func testBatchParsesAtelierSteps() throws {
        let arguments = JSONValue(parsing: Data(#"{"atomic":true,"steps":[{"tool":"set_metadata","arguments":{"ids":[1],"rating":3}},{"command":"photo.setRating","parameters":{"stars":2},"ids":[2]}]}"#.utf8))?.objectValue ?? [:]
        let batch = try CommandBatchTool.parse(arguments, tools: AtelierAgentTools.batchTools(profile: .organize)).get()
        XCTAssertEqual(batch.steps.map(\.tool), ["set_metadata", "command_run"])
        XCTAssertTrue(batch.steps.allSatisfy { AtelierAgentTools.atomicRefusal($0) == nil })
    }
}
