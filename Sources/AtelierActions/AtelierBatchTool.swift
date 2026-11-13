import AgentActions
import AgentMCP
import Foundation

// command_batch for Atelier (AT-050j): which tools a batch may hold, and which steps can be in
// an atomic (all or nothing) batch. The app runs it (Agents/AgentBatch.swift).
extension AtelierAgentTools {
    public static let commandBatch = CommandBatchTool.tool(
        description: "A batch takes show, set_metadata, organize and command_run, plus adjust, apply_preset, sync, reset "
            + "and the other Develop tools with the Edit profile. An atomic batch takes changes Atelier can put back: "
            + "set_metadata, organize into collections, the Develop tools and library commands (not Develop menu "
            + "commands, virtual copies or show). Asking before many photos counts the whole batch.")

    /// The tools a batch may hold for a profile: the write tools it already has, without undo
    /// and without a batch inside a batch.
    public static func batchTools(profile: AgentProfile) -> [String] {
        var tools: [MCPTool] = []
        if profile >= .organize { tools += organizeTools.filter { $0.name != undoChange.name } }
        if profile >= .edit { tools += editTools }
        return tools.map(\.name)
    }

    /// Why a step can't be in an atomic batch, or nil when it can: only changes Atelier can put
    /// back if a later step fails.
    public static func atomicRefusal(_ step: CommandBatchTool.Step) -> String? {
        switch step.tool {
        case show.name:
            return "show changes only what's on screen; leave it out of an atomic batch or use atomic: false."
        case organize.name:
            if step.arguments["virtual_copy"]?.boolValue == true {
                return "virtual copies are new photos, which can't be put back; use atomic: false."
            }
            return nil
        case commandRun.name:
            guard let id = step.arguments["id"]?.stringValue,
                  let action = AtelierAction.catalog.descriptor(ActionID(id)) else { return nil }   // command_run says why
            guard action.kind == .edit else {
                return "\(action.title) isn't a change to photos; use atomic: false."
            }
            if action.id == AtelierAction.createVirtualCopy.id {
                return "virtual copies are new photos, which can't be put back; use atomic: false."
            }
            if editProfile(action) == .edit {
                return "\(action.title) is a Develop command, which can't be put back with the rest; use adjust, "
                    + "apply_preset, sync or reset instead, or atomic: false."
            }
            return nil
        default:
            return nil
        }
    }
}
