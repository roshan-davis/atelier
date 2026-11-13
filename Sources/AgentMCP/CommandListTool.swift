import AgentActions
import Foundation

/// `command_list`: every registry command this client's profile may use, generated from the
/// app's catalog, so new menu commands show up with no porting. Never actions are left out.
public enum CommandListTool {
    public static let name = "command_list"

    public static let tool = MCPTool(
        name: name, title: "List commands",
        description: "Lists the app's menu and key commands this client may use, with their id, menu place, "
            + "parameters (JSON Schema), kind, what an agent may do with it (tier) and whether it applies right now. "
            + "Filter with `search` (words in the title, place or summary).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "search": .object(["type": .string("string"),
                                   "description": .string("Only commands whose title, place, id or summary contain these words.")]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: true, idempotent: true)

    /// The commands `profile` may see, as JSON.
    public static func list(catalog: ActionCatalog, profile: AgentProfile, search: String?,
                            editProfile: (ActionDescriptor) -> AgentProfile,
                            isEnabled: (ActionID) -> Bool) -> JSONValue {
        let words = (search ?? "").lowercased().split(separator: " ").map(String.init)
        let visible = catalog.actions
            .filter { action in
                guard let minimum = AgentProfile.minimum(for: action, editProfile: editProfile) else { return false }
                return minimum <= profile
            }
            .filter { action in
                let text = [action.id.rawValue, action.title, action.place, action.summary].joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { $0.id < $1.id }
        let commands: [JSONValue] = visible.map { action in
            var members: [String: JSONValue] = [
                "id": .string(action.id.rawValue),
                "title": .string(action.title),
                "place": .string(action.place),
                "summary": .string(action.summary),
                "kind": .string(action.kind.rawValue),
                "tier": .string(action.tier.rawValue),
                "parameters": action.parameters.json,
                "enabledNow": .bool(isEnabled(action.id)),
                "version": .int(action.version),
            ]
            if let targets = action.targets { members["targets"] = .string(targets.rawValue) }
            if let shortcut = action.shortcut { members["shortcut"] = .string(shortcut.display) }
            return .object(members)
        }
        return .object([
            "app": .string(catalog.app),
            "profile": .string(profile.rawValue),
            "commands": .array(commands),
            "note": .string("Running commands arrives in a later version; this list is for reading."),
        ])
    }
}
