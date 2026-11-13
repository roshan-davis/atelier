import AgentActions
import Foundation

/// `command_run`: runs one registry command by id, after the same checks every typed tool goes
/// through: the command exists and is exposed, this client's profile reaches it, this version of
/// the app runs that tier for agents, and the parameters fit its schema. The app supplies how
/// targets are named (`targetProperties`) and runs the command.
public enum CommandRunTool {
    public static let name = "command_run"

    /// `targetProperties`: the app's own target fields (Atelier: `ids`, `selection`, `current`),
    /// merged into the tool's input schema next to `id` and `parameters`.
    public static func tool(targetProperties: [String: JSONValue], description extra: String) -> MCPTool {
        var properties: [String: JSONValue] = [
            "id": .object(["type": .string("string"),
                           "description": .string("The command id from command_list, such as \"photo.setRating\".")]),
            "parameters": .object(["type": .string("object"),
                                   "description": .string("The command's parameters, as command_list shows them. Omit when it takes none.")]),
        ]
        for (key, value) in targetProperties { properties[key] = value }
        return MCPTool(
            name: name, title: "Run a command",
            description: "Runs one menu command from command_list, with its parameters. Each command keeps its own rules: "
                + "changes run as one undo step and return a change id for undo_change. " + extra,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false),
            ]),
            readOnly: false, destructive: false)
    }

    /// A command that passed every check, ready to run.
    public struct Checked: Sendable {
        public let action: ActionDescriptor
        /// The parameters, checked, as JSON for the registry's decoder.
        public let parameters: Data
    }

    /// Checks a `command_run` call. `ceiling` is the highest profile whose commands this version
    /// of the app runs for agents (later versions raise it); `editProfile` is the app's rule for
    /// which profile its edit commands need.
    public static func check(_ arguments: [String: JSONValue], catalog: ActionCatalog, profile: AgentProfile,
                             ceiling: AgentProfile, editProfile: (ActionDescriptor) -> AgentProfile) -> Result<Checked, ParameterCheck.Problems> {
        func fail(_ message: String) -> Result<Checked, ParameterCheck.Problems> {
            .failure(ParameterCheck.Problems(messages: [message]))
        }
        guard let raw = arguments["id"]?.stringValue, !raw.isEmpty else {
            return fail("command_run needs \"id\", a command id from command_list.")
        }
        let visible = catalog.actions.filter { action in
            AgentProfile.minimum(for: action, editProfile: editProfile).map { $0 <= profile } ?? false
        }
        guard let action = catalog.descriptor(ActionID(raw)) else {
            let hint = Suggest.closest(to: raw, in: visible.map(\.id.rawValue)).map { " Did you mean \"\($0)\"?" } ?? ""
            return fail("There is no command \"\(raw)\".\(hint) Use command_list to see the commands.")
        }
        guard action.isExposed, let minimum = AgentProfile.minimum(for: action, editProfile: editProfile) else {
            let reason = action.hiddenReason ?? "only the person can do this, from the menus (\(action.place))."
            return fail("\(action.title) isn't available to agents: \(reason)")
        }
        guard minimum <= profile else {
            return fail("\(action.title) needs the \(minimum.title) profile, and this app is allowed \(profile.title). "
                        + "The person can change that in \(catalog.app) > Settings… > Agents.")
        }
        guard minimum <= ceiling else {
            return fail("Running \(minimum.title) commands such as \(action.title) arrives in a later version of \(catalog.app).")
        }
        let given = arguments["parameters"] ?? .object([:])
        guard case .object(let parameters) = given else {
            return fail("\"parameters\" must be an object, such as {\"stars\": 3}.")
        }
        switch ParameterCheck.decodable(parameters, against: action.parameters) {
        case .failure(let problems):
            return .failure(ParameterCheck.Problems(messages: problems.messages.map { "\(action.id): \($0)" }))
        case .success(let data):
            return .success(Checked(action: action, parameters: data))
        }
    }
}
