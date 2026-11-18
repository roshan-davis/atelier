import AgentActions
import AgentMCP
import Foundation

// `get_skill` (SL-002c, studio-shared-lib Skills PRD "How agents get skills"): reads one of the
// person's skills, written in Settings > Agents > Skills. Every profile has it; it only reads,
// and only skills that are on. The app answers it from its skill store (Agents/AgentSkills.swift).

public struct GetSkillParameters: ActionParameters, Hashable {
    public var name: String
    public var file: String?

    public init(name: String, file: String? = nil) {
        self.name = name
        self.file = file
    }

    public static let example = GetSkillParameters(name: "cull-import", file: "sharpness.md")
    public static let fieldNotes: [String: FieldNote] = [
        "name": FieldNote("The skill's name, as the server's instructions or prompts/list name it, such as \"cull-import\"."),
        "file": FieldNote("Another file of the skill, such as \"sharpness.md\". Leave out for the skill's steps (SKILL.md), "
                          + "which name its other files."),
    ]
}

extension AtelierAgentTools {
    public static let getSkill = MCPTool(
        name: "get_skill", title: "Read a skill",
        description: "Reads one of the person's skills: a workflow they wrote for Atelier, with the commands to run "
            + "written out. Call it first when a request matches a skill the server's instructions list, then follow "
            + "its steps. Grants still apply: a step this app isn't allowed says so.",
        inputSchema: ParameterSchema.of(GetSkillParameters.self).json, readOnly: true, idempotent: true)
}
