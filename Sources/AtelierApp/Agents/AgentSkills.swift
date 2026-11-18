import AgentActions
import AgentMCP
import AtelierActions
import Combine
import Foundation
import StudioSkills

/// The person's skills (SL-002c, studio-shared-lib Skills PRD): workflows written in
/// Settings > Agents > Skills, kept by the library's `SkillStore` in
/// `~/Library/Application Support/Atelier/Skills/`. Agents read them with `get_skill`, see the
/// ones that are on in the server's instructions, and chat apps that show prompts (Docent, under
/// `/`) list them through `prompts/list`.
@MainActor
final class AgentSkills {
    let store: SkillStore
    /// What the skill editor offers and what prepared text names: Atelier's actions and tools.
    let catalog = AtelierSkills.catalog
    /// The skills for the MCP sessions, which run on background threads.
    let snapshot: AtelierSkills.Snapshot
    /// Called after a change agents see (a skill added, removed, renamed, turned on or off, or
    /// its title, description or arguments changed).
    var onListingsChange: (() -> Void)?
    private var watching: AnyCancellable?

    init(folder: URL = AtelierSkills.folder) {
        store = SkillStore(folder: folder)
        snapshot = AtelierSkills.Snapshot(skills: store.skills)
        watching = store.$skills.sink { [snapshot] skills in snapshot.set(skills) }
        store.onListingsChange = { [weak self] in self?.onListingsChange?() }
    }
}

/// Atelier's side of skills, without a window: the catalog the library checks skills against,
/// what a client's profile lets it run, and the skills for background threads.
enum AtelierSkills {
    static let appName = "Atelier"
    static let environmentKey = "ATELIER_SKILLS_FOLDER"

    /// `ATELIER_SKILLS_FOLDER` when set; a throwaway folder in tests, the smoke test and layout
    /// snapshots (never the person's skills); otherwise Application Support/Atelier/Skills.
    @MainActor
    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if AgentServer.isThrowawayRun {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Atelier-Skills-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return SkillStore.defaultFolder(appName: AtelierSkills.appName)
    }

    // MARK: The catalog

    /// The typed tools a skill can name, with the profile each needs. `command_run` is how actions
    /// run, so it isn't one; the photo carousel's thumbnails are only for its view.
    static let tools: [(tool: MCPTool, profile: AgentProfile)] = {
        let look = AgentLookTools.tools(options: .init(previews: true, location: true))
            .filter { $0.name != AtelierPhotoCarousel.getThumbnails.name }
            + [CommandListTool.tool, AtelierAgentTools.getSkill]
        let organize = AtelierAgentTools.organizeTools.filter { $0.name != CommandRunTool.name } + [AtelierAgentTools.commandBatch]
        let edit = AtelierAgentTools.editTools
        return look.map { (tool: $0, profile: AgentProfile.look) } + organize.map { (tool: $0, profile: AgentProfile.organize) }
            + edit.map { (tool: $0, profile: AgentProfile.edit) }
    }()

    /// Tools that change only Atelier's window, so they run like a view command.
    static let viewTools: Set<String> = [AtelierAgentTools.show.name]

    static let catalog: SkillCatalog = {
        let actions = AtelierAction.catalog.actions
        var menus: [String] = []
        var entries: [SkillCatalog.Entry] = AtelierSkills.tools.map { listed in
            let tool = listed.tool
            return SkillCatalog.Entry(id: tool.name, kind: .tool, title: tool.title, place: "Tools", summary: tool.description,
                                      tier: tool.readOnly || AtelierSkills.viewTools.contains(tool.name) ? .runs : .undoable,
                                      parameters: AtelierSkills.parameters(of: tool.inputSchema))
        }
        for action in actions {
            let entry = SkillCatalog.Entry(id: action.id.rawValue, title: action.title, place: action.place,
                                           summary: action.summary, tier: AtelierSkills.tier(action.tier),
                                           parameters: action.parameters.fields.map { AtelierSkills.parameter($0) },
                                           shortcut: action.shortcut?.display, version: action.version,
                                           isExposed: action.isExposed)
            if !menus.contains(entry.menu) { menus.append(entry.menu) }
            entries.append(entry)
        }
        return SkillCatalog(appName: AtelierSkills.appName, entries: entries, menuOrder: menus,
                            runTool: CommandRunTool.name, skillTool: AtelierAgentTools.getSkill.name)
    }()

    static func tier(_ tier: AgentTier) -> SkillCatalog.Tier {
        switch tier {
        case .runs: return .runs
        case .undoable: return .undoable
        case .asksFirst: return .asksFirst
        case .never: return .never
        }
    }

    /// A registry parameter in words: "integer, 0 to 5".
    static func parameter(_ field: ParameterSchema.Field) -> SkillCatalog.Parameter {
        var choices: [String] = []
        var type = words(field.type, choices: &choices)
        if let minimum = field.note?.minimum, let maximum = field.note?.maximum {
            type += ", \(number(minimum)) to \(number(maximum))"
        }
        return SkillCatalog.Parameter(name: field.name, type: type, required: field.required, choices: choices)
    }

    private static func words(_ type: ParameterSchema.FieldType, choices: inout [String]) -> String {
        switch type {
        case .boolean: return "true or false"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "text"
        case .choice(let values):
            choices = values
            return "choice"
        case .list(let element):
            var ignored: [String] = []
            return "list of " + words(element, choices: &ignored)
        }
    }

    /// A tool's parameters from its JSON schema: required ones first, then by name.
    static func parameters(of schema: JSONValue) -> [SkillCatalog.Parameter] {
        guard let properties = schema["properties"]?.objectValue else { return [] }
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }.map { name in
            let property = properties[name] ?? .object([:])
            var type: String
            switch property["type"]?.stringValue {
            case "boolean": type = "true or false"
            case "string": type = "text"
            case "array": type = "list of " + (property["items"]?["type"]?.stringValue.map { $0 == "string" ? "text" : $0 } ?? "values")
            case let other?: type = other
            case nil: type = "value"
            }
            if let minimum = property["minimum"]?.doubleValue, let maximum = property["maximum"]?.doubleValue {
                type += ", \(number(minimum)) to \(number(maximum))"
            }
            let choices = property["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !choices.isEmpty, type == "text" { type = "choice" }
            return SkillCatalog.Parameter(name: name, type: type, required: required.contains(name), choices: choices)
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Grants

    /// Why a client can't run an entry a skill names, or nil when it can (Skills PRD: "Grants
    /// still decide"): "Set Rating needs the Organize profile; Docent has Look."
    static func grantNote(_ entry: SkillCatalog.Entry, profile: AgentProfile, clientName: String) -> String? {
        let minimum: AgentProfile?
        switch entry.kind {
        case .action:
            minimum = AtelierAction.catalog.descriptor(ActionID(entry.id))
                .flatMap { AgentProfile.minimum(for: $0, editProfile: AtelierAgentTools.editProfile) }
        case .tool:
            minimum = tools.first { $0.tool.name == entry.id }?.profile
        }
        guard let minimum else { return nil }
        if minimum > profile {
            return "\(entry.title) needs the \(minimum.title) profile; \(clientName) has \(profile.title)."
        }
        if entry.kind == .action, minimum > AtelierAgentTools.runCeiling {
            return "Agents can't run \(entry.title) in this version of \(AtelierSkills.appName)."
        }
        return nil
    }

    /// The prepared text's maker for one client.
    static func prompt(profile: AgentProfile, clientName: String) -> SkillPrompt {
        SkillPrompt(catalog: catalog) { grantNote($0, profile: profile, clientName: clientName) }
    }

    // MARK: Answers

    /// `get_skill`'s answer.
    static func getSkill(_ arguments: [String: JSONValue], skills: [Skill], profile: AgentProfile,
                         clientName: String) -> MCPToolResult {
        let parameters: GetSkillParameters
        switch ParameterCheck.decode(GetSkillParameters.self, from: arguments) {
        case .failure(let problems): return .error(problems.text)
        case .success(let value): parameters = value
        }
        do {
            return .text(try prompt(profile: profile, clientName: clientName)
                .getSkill(named: parameters.name, file: parameters.file, in: skills))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let names = SkillPrompt.listings(skills).map(\.name)
            if case .noFile? = error as? SkillPrompt.Failure, let skill = skills.first(where: { $0.name == parameters.name }) {
                return .error(message + " Its files: " + skill.fileNames.joined(separator: ", ") + ".")
            }
            let hint = Suggest.closest(to: parameters.name, in: names).map { " Did you mean \($0)?" } ?? ""
            let list = names.isEmpty ? " The person has no skills turned on in Atelier." : " Skills that are on: " + names.joined(separator: ", ") + "."
            return .error(message + hint + list)
        }
    }

    /// `prompts/list`: the skills that are on.
    static func prompts(_ skills: [Skill]) -> [MCPPrompt] {
        SkillPrompt.listings(skills).map { listing in
            MCPPrompt(name: listing.name, title: listing.title, description: listing.description,
                      arguments: listing.arguments.map { .init(name: $0.name, description: $0.description, required: $0.required) })
        }
    }

    /// `prompts/get`'s text, or nil when no skill that is on has the name.
    static func promptText(_ name: String, arguments: [String: String], skills: [Skill], profile: AgentProfile,
                           clientName: String) -> String? {
        guard let skill = skills.first(where: { $0.name == name && $0.isEnabled }) else { return nil }
        return prompt(profile: profile, clientName: clientName).promptMessage(for: skill, arguments: arguments)
    }

    /// The server's instructions with the skills that are on.
    static func instructions(_ base: String, skills: [Skill]) -> String {
        guard let paragraph = SkillPrompt(catalog: catalog).instructionsParagraph(skills) else { return base }
        return base + "\n\n" + paragraph
    }

    /// The skills, for the MCP sessions' threads.
    final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Skill]

        init(skills: [Skill]) { stored = skills }

        var skills: [Skill] { lock.withLock { stored } }
        func set(_ skills: [Skill]) { lock.withLock { stored = skills } }
    }
}
