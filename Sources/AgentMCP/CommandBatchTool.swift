import AgentActions
import Foundation

/// `command_batch`: several changes in one call, run in order. Each step is a write tool the
/// client may already call (`set_metadata`, `adjust`, …) or a registry command, written like a
/// `command_run` call. With `atomic: true` the batch is all or nothing: one change with one Undo,
/// and if a step fails, the steps before it are put back. The app decides which steps can be
/// atomic (only ones it can roll back) and runs them; this type checks the call's shape.
public enum CommandBatchTool {
    public static let name = "command_batch"
    public static let maxSteps = 50

    public struct Step: Sendable, Hashable {
        public let tool: String
        public let arguments: [String: JSONValue]

        public init(tool: String, arguments: [String: JSONValue]) {
            self.tool = tool
            self.arguments = arguments
        }
    }

    public struct Batch: Sendable, Hashable {
        public let steps: [Step]
        public let atomic: Bool
        /// The batch's name in the notice, the history and undo; "3 changes" when not given.
        public let label: String
    }

    public static func tool(description extra: String) -> MCPTool {
        let step: JSONValue = .object([
            "type": .string("object"),
            "description": .string("One change: {\"tool\": \"set_metadata\", \"arguments\": {…}} for a write tool, or a "
                                   + "command written as for command_run: {\"command\": \"photo.setRating\", "
                                   + "\"parameters\": {…}, \"ids\": […]}."),
            "properties": .object([
                "tool": .object(["type": .string("string"), "description": .string("A write tool, such as set_metadata.")]),
                "arguments": .object(["type": .string("object"), "description": .string("The tool's arguments.")]),
                "command": .object(["type": .string("string"), "description": .string("A command id from command_list.")]),
                "parameters": .object(["type": .string("object"), "description": .string("The command's parameters.")]),
            ]),
        ])
        return MCPTool(
            name: name, title: "Several changes at once",
            description: "Runs up to \(maxSteps) changes in order, each a write tool call or a command from command_list. "
                + "With atomic: true they are all or nothing: one change with one Undo (undo_change takes the batch's "
                + "change id), and if a step fails, the steps before it are put back. Without it, each step is its own "
                + "change, and the batch stops at the first failure unless keep_going is true. " + extra,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "steps": .object(["type": .string("array"), "items": step, "minItems": .int(1),
                                      "maxItems": .int(maxSteps), "description": .string("The changes, in order.")]),
                    "atomic": .object(["type": .string("boolean"),
                                       "description": .string("true: all or nothing, one Undo. Default false.")]),
                    "label": .object(["type": .string("string"),
                                      "description": .string("A short name for the batch, such as \"Best of the burst\".")]),
                    "keep_going": .object(["type": .string("boolean"),
                                           "description": .string("Without atomic: run the later steps after one fails. "
                                                                  + "Default false.")]),
                ]),
                "required": .array([.string("steps")]),
                "additionalProperties": .bool(false),
            ]),
            readOnly: false, destructive: false)
    }

    /// Checks the call: its steps name tools in `tools` (the write tools this client may call,
    /// `command_run` among them for commands), no batch inside a batch, and at most `maxSteps`.
    public static func parse(_ arguments: [String: JSONValue], tools: [String]) -> Result<Batch, ParameterCheck.Problems> {
        var problems: [String] = []
        for key in arguments.keys.sorted() where !["steps", "atomic", "label", "keep_going"].contains(key) {
            let hint = Suggest.closest(to: key, in: ["steps", "atomic", "label", "keep_going"]).map { " Did you mean \"\($0)\"?" } ?? ""
            problems.append("Unknown argument \"\(key)\" for command_batch.\(hint)")
        }
        guard let list = arguments["steps"]?.arrayValue, !list.isEmpty else {
            return .failure(.init(messages: problems + ["steps is required: a list of at least one change."]))
        }
        if list.count > maxSteps { problems.append("steps holds at most \(maxSteps) changes; split the batch.") }
        var atomic = false
        if let value = arguments["atomic"] {
            if let flag = value.boolValue { atomic = flag } else { problems.append("atomic is true or false.") }
        }
        if let value = arguments["keep_going"], value.boolValue == nil { problems.append("keep_going is true or false.") }
        if atomic, arguments["keep_going"]?.boolValue == true {
            problems.append("keep_going doesn't go with atomic: an atomic batch stops and puts everything back at a failure.")
        }
        var label = "\(list.count) change\(list.count == 1 ? "" : "s")"
        if let value = arguments["label"] {
            guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure(.init(messages: problems + ["label is a short text, such as \"Best of the burst\"."]))
            }
            label = String(text.prefix(80))
        }
        var steps: [Step] = []
        for (index, value) in list.enumerated() {
            let number = index + 1
            guard case .object(var members) = value else {
                problems.append("Step \(number) is not an object.")
                continue
            }
            if let command = members["command"] {
                guard members["tool"] == nil, members["arguments"] == nil else {
                    problems.append("Step \(number): give either tool and arguments, or command; not both.")
                    continue
                }
                guard let id = command.stringValue, !id.isEmpty else {
                    problems.append("Step \(number): command is a command id from command_list.")
                    continue
                }
                guard tools.contains(CommandRunTool.name) else {
                    problems.append("Step \(number): commands need command_run, which this app isn't allowed.")
                    continue
                }
                members.removeValue(forKey: "command")
                members["id"] = .string(id)
                steps.append(Step(tool: CommandRunTool.name, arguments: members))
                continue
            }
            guard let tool = members["tool"]?.stringValue, !tool.isEmpty else {
                problems.append("Step \(number) needs \"tool\" (with \"arguments\") or \"command\".")
                continue
            }
            for key in members.keys.sorted() where key != "tool" && key != "arguments" {
                problems.append("Step \(number): unknown key \"\(key)\"; put the tool's arguments inside \"arguments\".")
            }
            guard tool != name else {
                problems.append("Step \(number): a batch can't hold another batch.")
                continue
            }
            guard tools.contains(tool) else {
                let hint = Suggest.closest(to: tool, in: tools).map { " Did you mean \($0)?" } ?? ""
                problems.append("Step \(number): \(tool) can't be in a batch.\(hint) Batches take: \(tools.sorted().joined(separator: ", ")).")
                continue
            }
            let given = members["arguments"] ?? .object([:])
            guard case .object(let toolArguments) = given else {
                problems.append("Step \(number): arguments must be an object.")
                continue
            }
            steps.append(Step(tool: tool, arguments: toolArguments))
        }
        guard problems.isEmpty else { return .failure(.init(messages: problems)) }
        return .success(Batch(steps: steps, atomic: atomic, label: label))
    }
}
