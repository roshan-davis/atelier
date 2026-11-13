import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

final class CommandBatchTests: XCTestCase {
    let tools = ["rename_layer", "set_opacity", "command_run"]

    func parse(_ text: String, tools: [String]? = nil) -> Result<CommandBatchTool.Batch, ParameterCheck.Problems> {
        CommandBatchTool.parse(JSONValue(parsing: Data(text.utf8))?.objectValue ?? [:], tools: tools ?? self.tools)
    }

    func testToolStepsAndCommandShorthand() throws {
        let batch = try parse(#"{"atomic":true,"label":" Tidy layers ","steps":[{"tool":"rename_layer","arguments":{"name":"Sky"}},{"command":"layer.hide","parameters":{"on":true},"ids":[3]}]}"#).get()
        XCTAssertTrue(batch.atomic)
        XCTAssertEqual(batch.label, "Tidy layers")
        XCTAssertEqual(batch.steps[0], .init(tool: "rename_layer", arguments: ["name": .string("Sky")]))
        XCTAssertEqual(batch.steps[1].tool, "command_run")
        XCTAssertEqual(batch.steps[1].arguments["id"], .string("layer.hide"))
        XCTAssertEqual(batch.steps[1].arguments["ids"], .array([.int(3)]))
        XCTAssertNil(batch.steps[1].arguments["command"])
    }

    func testDefaultLabelAndNotAtomic() throws {
        let batch = try parse(#"{"steps":[{"tool":"set_opacity"}]}"#).get()
        XCTAssertFalse(batch.atomic)
        XCTAssertEqual(batch.label, "1 change")
        XCTAssertEqual(batch.steps[0].arguments, [:])
    }

    func testProblemsAreAllReported() {
        guard case .failure(let problems) = parse(#"{"step":1,"steps":[{"tool":"command_batch"},{"tool":"rename_layr"},{"tool":"set_opacity","name":"x"},3]}"#) else {
            return XCTFail("expected problems")
        }
        let text = problems.text
        XCTAssertTrue(text.contains("Did you mean \"steps\"?"), text)
        XCTAssertTrue(text.contains("can't hold another batch"), text)
        XCTAssertTrue(text.contains("Did you mean rename_layer?"), text)
        XCTAssertTrue(text.contains("unknown key \"name\""), text)
        XCTAssertTrue(text.contains("Step 4 is not an object"), text)
    }

    func testLimitsAndConflicts() {
        let many = Array(repeating: #"{"tool":"set_opacity"}"#, count: 51).joined(separator: ",")
        XCTAssertThrowsError(try parse("{\"steps\":[\(many)]}").get())
        XCTAssertThrowsError(try parse(#"{"steps":[]}"#).get())
        XCTAssertThrowsError(try parse(#"{"atomic":true,"keep_going":true,"steps":[{"tool":"set_opacity"}]}"#).get())
        XCTAssertThrowsError(try parse(#"{"steps":[{"command":"layer.hide","tool":"set_opacity"}]}"#).get())
        // Commands need command_run among the client's tools.
        XCTAssertThrowsError(try parse(#"{"steps":[{"command":"layer.hide"}]}"#, tools: ["set_opacity"]).get())
    }

    func testSchemaListsTheFields() {
        let schema = CommandBatchTool.tool(description: "").inputSchema
        XCTAssertEqual(schema["properties"]?["steps"]?["maxItems"], .int(CommandBatchTool.maxSteps))
        XCTAssertEqual(schema["required"], .array([.string("steps")]))
    }
}
