import AgentActions
import AgentMCP
import AppKit
import AtelierActions
import AtelierCore
import Foundation

/// Settings > Agents, as user defaults.
enum AgentSettings {
    static let enabledKey = "agents.enabled"
    static let previewsKey = "agents.previews"
    static let locationKey = "agents.location"
    static let confirmAboveKey = "agents.confirmAbove"

    /// On unless turned off: every app still has to be allowed the first time it connects.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// One agent change touching more photos than this asks the person first (0: never asks).
    static var confirmAbove: Int { UserDefaults.standard.object(forKey: confirmAboveKey) as? Int ?? 50 }
    static var options: AgentLookTools.Options {
        AgentLookTools.Options(previews: UserDefaults.standard.bool(forKey: previewsKey),
                               location: UserDefaults.standard.bool(forKey: locationKey))
    }
}

/// Atelier's MCP server (AT-050b): the private socket the bundled `atelier-mcp` helper connects
/// to, the grants (one per checked client), the activity log, the Look tools (AT-050b) and the
/// Organize tools (AT-050c, Agents/AgentOrganizeTools.swift). Settings > Agents shows and edits it.
@MainActor
final class AgentServer: ObservableObject {
    static let appName = "Atelier"

    let grants = AgentGrantStore()
    let socketPath = AgentSocketPath.path(app: "Atelier")
    @Published private(set) var grantList: [AgentGrant] = []
    @Published private(set) var activity = AgentActivityLog()
    @Published private(set) var connected: [AgentClient] = []
    @Published private(set) var isRunning = false
    /// Why the server couldn't start, for Settings.
    @Published private(set) var problem: String?
    /// The line at the bottom of the photo after an agent changed something.
    @Published var notice: AgentNotice?
    /// Agents' changes while Atelier runs, for undo_change and the notice's Undo.
    var changes = PhotoChangeLog()
    /// The batch running now (AT-050j), so its steps record into it instead of one change each.
    var batchRun: AgentBatchRun?

    private(set) weak var model: LibraryModel?
    /// Docking beside a chat app (AT-050h, Agents/AgentDocking.swift).
    private(set) lazy var dock = AgentDock(server: self)
    private var server: MCPSocketServer?
    /// The host the socket and the phone listener share (one set of tools, one log).
    private(set) var host: AtelierMCPHost?
    /// Paired phones over Tailscale (AT-050f, Agents/AgentPhone.swift).
    private(set) lazy var phone = AgentPhone(server: self)
    /// The person's skills (SL-002c, Agents/AgentSkills.swift), read by agents with get_skill and
    /// listed as prompts. A change agents see is sent to every connected chat app.
    private(set) lazy var skills: AgentSkills = {
        let skills = AgentSkills()
        skills.onListingsChange = { [weak self] in self?.server?.promptsChanged() }
        return skills
    }()
    /// One approval question per client at a time, however many requests are waiting on it.
    private var questions: [String: Task<AgentProfile?, Never>] = [:]

    init(model: LibraryModel) {
        self.model = model
        grantList = grants.all
    }

    /// Tests, the smoke test and layout snapshots open throwaway catalogs: they must never take
    /// the socket of the Atelier the person is using, or read and write the person's skills.
    static var isThrowawayRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil || environment["XCTestConfigurationFilePath"] != nil
            || environment["ATELIER_UI_SMOKE"] == "1" || LayoutSnapshots.outputFolder != nil
    }

    func startIfEnabled() {
        if AgentSettings.isEnabled, !Self.isThrowawayRun { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AgentSettings.enabledKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard server == nil, let model else { return }
        let host = AtelierMCPHost(server: self, tools: AgentLookTools(catalog: model.catalog, previews: model.previews),
                                  docking: dock.coordinator, skills: skills.snapshot)
        let socket = MCPSocketServer(path: socketPath, host: host)
        socket.onConnect = { [weak self] client in
            Task { @MainActor in self?.clientConnected(client) }
        }
        socket.onDisconnect = { [weak self] client in
            Task { @MainActor in self?.clientDisconnected(client) }
        }
        do {
            try socket.start()
            server = socket
            self.host = host
            isRunning = true
            problem = nil
            phone.refresh()
        } catch is MCPSocketServer.InUse {
            problem = "Another copy of Atelier is already connected to chat apps. Quit it, then turn agents off and on here."
            isRunning = false
        } catch {
            problem = "Couldn't open the agent connection: \(error)"
            isRunning = false
        }
    }

    /// Closes the socket and every connection (turning access off, quitting). A chat app that
    /// docked Atelier's window is told first when Atelier quits.
    // The socket's accept thread holds its server until `stop()`, so an agent server let go of
    // closes it here (AT-076 M4).
    deinit { server?.stop() }

    func stop(quitting: Bool = false) {
        if quitting { dock.quitting() }
        server?.stop()
        server = nil
        host = nil
        isRunning = false
        problem = nil
        connected = []
        phone.refresh()
    }

    // MARK: Grants

    /// Changes what a client may do. Its open connections are dropped, so the change is clear
    /// to the chat app (it reconnects and gets the new tool list).
    func setProfile(_ profile: AgentProfile?, for clientID: String) {
        guard var grant = grants.grant(for: clientID) else { return }
        grant.profile = profile
        grant.decidedAt = Date()
        grants.save(grant)
        server?.disconnect(clientID: clientID)
        log(grant.name, profile == nil ? .denied : .allowed, profile.map { "Allowed as \($0.title)" } ?? "Not allowed")
        grantList = grants.all
    }

    /// A setting added or removed tools (Let agents see photo previews): connected chat apps are
    /// told to list them again (`notifications/tools/list_changed`), without reconnecting.
    func toolsChanged() {
        server?.toolsChanged()
    }

    /// Forgets a client: it is asked about again the next time it connects.
    func forget(clientID: String) {
        guard let grant = grants.grant(for: clientID) else { return }
        grants.remove(clientID: clientID)
        server?.disconnect(clientID: clientID)
        grantList = grants.all
        DeleteFeedback.play(.remove)
        log(grant.name, .denied, "Removed from Settings")
    }

    func clearActivity() {
        activity.clear()
        DeleteFeedback.play(.remove)
    }

    // MARK: Host (called by AtelierMCPHost)

    func authorize(_ client: AgentClient) async -> AgentAuthorization {
        guard AgentSettings.isEnabled else {
            return .denied("Agents are turned off in \(Self.appName) > Settings… > Agents.")
        }
        // A paired phone has its own grant and is never asked about at the Mac (nobody may be there).
        if client.isRemote { return phone.authorization(for: client) }
        if let grant = grants.grant(for: client.id) {
            return grant.authorization(for: client, appName: Self.appName)
        }
        let question: Task<AgentProfile?, Never>
        if let asking = questions[client.id] {
            question = asking
        } else {
            question = Task { @MainActor in AgentApproval.ask(client) }
            questions[client.id] = question
        }
        let choice = await question.value
        questions[client.id] = nil
        if grants.grant(for: client.id) == nil {
            grants.save(AgentGrant(clientID: client.id, name: client.name, path: client.path, profile: choice, lastSeen: Date()))
            grantList = grants.all
            log(client.name, choice == nil ? .denied : .allowed, choice.map { "Allowed as \($0.title)" } ?? "Not allowed")
        }
        return grants.grant(for: client.id)?.authorization(for: client, appName: Self.appName)
            ?? .denied("Not allowed.")
    }

    func tools(profile: AgentProfile) -> [MCPTool] {
        var tools = AgentLookTools.tools(options: AgentSettings.options) + [CommandListTool.tool, AtelierAgentTools.getSkill]
        if profile >= .organize { tools += AtelierAgentTools.organizeTools + [AtelierAgentTools.commandBatch] }
        if profile >= .edit { tools += AtelierAgentTools.editTools }
        return tools
    }

    /// The tools that read the window or the app's lists, and every write, on the main thread.
    func callOnMain(_ tool: String, _ arguments: [String: JSONValue], client: AgentClient,
                    profile: AgentProfile) -> MCPToolResult? {
        guard let model else { return .error("\(Self.appName) is closing.") }
        if let result = callWrite(tool, arguments, client: client, profile: profile) { return result }
        switch tool {
        case CommandListTool.name:
            let registry = model.actions
            let runs = profile >= .organize
            return .json(CommandListTool.list(catalog: registry.catalog, profile: profile,
                                              search: arguments["search"]?.stringValue,
                                              editProfile: Self.editProfile,
                                              isEnabled: { registry.isEnabled($0) },
                                              note: runs
                                                ? (profile >= .edit
                                                    ? "Run a command with command_run. Exports and other apps arrive in a "
                                                        + "later version."
                                                    : "Run a command with command_run. Develop commands need the Edit "
                                                        + "profile; exports and other apps arrive in a later version.")
                                                : "This app is allowed Look, so these are for reading. The person can "
                                                    + "allow more in Atelier > Settings… > Agents."))
        case AgentLookTools.getContext.name:
            return context(model)
        case AgentLookTools.listItems.name:
            switch arguments["kind"]?.stringValue {
            case "presets":
                let presets: [JSONValue] = Self.agentPresets(model).map { preset, kind -> JSONValue in
                    .object(["id": .string(preset.id.uuidString), "name": .string(preset.name),
                             "group": .string(preset.group), "built_in": .bool(preset.isBuiltIn),
                             "kind": .string(kind.rawValue)])
                }
                return .json(.object(["kind": .string("presets"), "items": .array(presets)]))
            case "editors":
                let editors: [JSONValue] = model.externalEditors.map { editor -> JSONValue in
                    .object(["name": .string(editor.name), "app_path": .string(editor.appPath),
                             "format": .string(editor.format.rawValue)])
                }
                return .json(.object(["kind": .string("editors"), "items": .array(editors)]))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Library edits (ratings, flags, collections) need Organize; Develop edits need Edit.
    nonisolated static func editProfile(_ action: ActionDescriptor) -> AgentProfile {
        AtelierAgentTools.editProfile(action)
    }

    private func context(_ model: LibraryModel) -> MCPToolResult {
        let modeName: String
        switch model.mode {
        case .grid: modeName = "grid"
        case .loupe: modeName = "loupe"
        case .develop: modeName = "develop"
        case .hdr: modeName = "hdr"
        }
        // Private photos may be on screen (View > Show Private Photos); agents never see them.
        let candidates = Array(model.selection.prefix(500)) + (model.focusedID.map { [$0] } ?? [])
        let hidden = (try? model.catalog.privatePhotoIDs(among: candidates)) ?? Set(candidates)
        var members: [String: JSONValue] = ["mode": .string(modeName)]
        let selected = model.selection.filter { !hidden.contains($0) }.sorted()
        // File names, so the model names the photo in front instead of guessing one from an earlier list.
        let named = Array(selected.prefix(Self.namedSelectionCount))
        let focused = model.focusedID.flatMap { hidden.contains($0) ? nil : $0 }
        let names = filenames(model, (focused.map { [$0] } ?? []) + named)
        if let focused {
            members["photo_in_front"] = .int(Int(focused))
            members["photo_in_front_filename"] = AgentLookTools.text(names[focused])
        }
        members["selected_ids"] = .array(selected.prefix(200).map { .int(Int($0)) })
        members["selected_photos"] = .array(named.map { id -> JSONValue in
            .object(["id": .int(Int(id)), "filename": AgentLookTools.text(names[id])])
        })
        members["selected_count"] = .int(selected.count)
        members["source"] = source(model)
        members["filter"] = .array(model.filter.summary.map { .string($0) })
        members["sort"] = .string(model.filter.sort.agentName)
        if model.filter.privacy == .hidden { members["photos_shown"] = .int(model.rows.count) }
        // Live, unlike the server's instructions: whether get_preview can show photos in the chat.
        let previews = AgentSettings.options.previews
        members["previews"] = .bool(previews)
        if !previews { members["previews_note"] = .string(Self.previewsOffNote) }
        return .json(.object(members))
    }

    static let previewsOffNote = "Photo previews are off in Atelier > Settings > Agents, so photos can't be shown in the chat."

    /// How many selected photos get_context names (the rest are only ids).
    static let namedSelectionCount = 5

    /// The file names of a few photos (at most namedSelectionCount + 1), from the catalog.
    private func filenames(_ model: LibraryModel, _ ids: [Int64]) -> [Int64: String] {
        var names: [Int64: String] = [:]
        for id in Set(ids) {
            if let filename = try? model.catalog.detail(for: id)?.asset.filename { names[id] = filename }
        }
        return names
    }

    private func source(_ model: LibraryModel) -> JSONValue {
        let sidebar = model.sidebar
        switch model.filter.scope {
        case .all:
            return .object(["kind": .string("all")])
        case .volume(let id):
            let name = sidebar.volumes.first { $0.id == id }?.name
            return .object(["kind": .string("volume"), "id": .int(Int(id)), "name": AgentLookTools.text(name)])
        case .folder(let id):
            guard let folder = sidebar.folders.first(where: { $0.id == id }) else { return .object(["kind": .string("private")]) }
            return .object(["kind": .string("folder"), "id": .int(Int(id)), "path": .string(folder.displayName)])
        case .collection(let id):
            guard let collection = sidebar.collections.first(where: { $0.id == id }), !collection.isPrivate else {
                return .object(["kind": .string("private")])
            }
            return .object(["kind": .string("collection"), "id": .int(Int(id)), "name": .string(collection.name)])
        case .importGroup(let id):
            guard let entry = sidebar.imports.first(where: { $0.id == id }), !entry.isPrivate else {
                return .object(["kind": .string("private")])
            }
            return .object(["kind": .string("import"), "id": .int(Int(id)), "name": .string(entry.name)])
        }
    }

    // MARK: Activity

    /// `text`: what the log says for a call that worked, instead of the tool's name ("Read the
    /// skill cull-import").
    func logCall(_ client: AgentClient, _ tool: String, _ result: MCPToolResult, text: String? = nil) {
        grants.touch(clientID: client.id)
        log(client.name, result.isError ? .failed : .call, result.isError ? "\(tool): \(result.text)" : text ?? tool)
    }

    private func clientConnected(_ client: AgentClient) {
        connected.append(client)
        var text = "Connected"
        if let info = client.clientInfo { text += " (\(info))" }
        log(client.name, .connected, text)
    }

    private func clientDisconnected(_ client: AgentClient) {
        if let index = connected.firstIndex(where: { $0.pid == client.pid && $0.id == client.id }) {
            connected.remove(at: index)
        }
        log(client.name, .disconnected, "Disconnected")
        grantList = grants.all
    }

    func log(_ name: String, _ kind: AgentActivity.Kind, _ text: String) {
        activity.add(AgentActivity(clientName: name, kind: kind, text: text))
    }
}

/// The bridge from the socket's sessions (background threads) to `AgentServer` (main thread).
/// Catalog reads run off the main thread; only the window's state is read on it.
final class AtelierMCPHost: MCPDockingHost, MCPResourceHost, MCPPromptHost, @unchecked Sendable {
    private weak var server: AgentServer?
    private let lookTools: AgentLookTools
    /// The docking protocol: only a chat app's window code sends it, never a model.
    let docking: DockingCoordinator?
    /// The person's skills, kept current by `AgentSkills`.
    private let skills: AtelierSkills.Snapshot

    init(server: AgentServer, tools: AgentLookTools, docking: DockingCoordinator, skills: AtelierSkills.Snapshot) {
        self.server = server
        self.lookTools = tools
        self.docking = docking
        self.skills = skills
    }

    var serverInfo: MCPServerInfo {
        MCPServerInfo(
            name: "atelier", title: "Atelier",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
            instructions: AtelierSkills.instructions(Self.instructions, skills: skills.skills))
    }

    /// The server's instructions, read once at `initialize`, so nothing in them follows a setting
    /// (get_context says whether previews are on). Chat apps that show images show get_preview's
    /// JPEG to the person; models read `show` as doing that unless told otherwise. The skills
    /// that are on follow, as a paragraph (`AtelierSkills.instructions`).
    static let instructions = """
                Atelier is a Lightroom-style photo catalog and editor on this Mac. Use get_context to see what the \
                person is looking at, search_photos and get_photo to answer questions about the library, and \
                command_list to see the menu commands. With the Organize profile, show selects photos in Atelier, \
                set_metadata rates, flags, labels and adds keywords, organize adds to collections, and command_run \
                runs library commands. With the Edit profile, adjust sets or nudges Develop sliders, apply_preset applies \
                a Develop preset, sync copies settings from one photo to others, reset resets them, crop crops, \
                straightens, rotates and flips, add_mask adds a mask (subject, object, people, gradients, luminance), \
                auto runs Auto tone and white balance, match_look matches a reference photo or built-in study, and \
                command_run also runs Develop commands; each is one step in the photo's Develop history. command_batch \
                runs several of these changes in one call; with atomic: true they are all or nothing, with one Undo. Each change returns a change id; undo_change undoes your own change while it \
                is still the latest on those photos. Name photos by id when you can. Private photos are never shown \
                to agents, and nothing an agent calls deletes anything. When the person asks to see a photo in the \
                chat, call get_preview if it's offered; show only changes Atelier's window.
                """

    func authorize(_ client: AgentClient) async -> AgentAuthorization {
        guard let server else { return .denied("Atelier is closing.") }
        return await server.authorize(client)
    }

    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] {
        guard let server else { return [] }
        return await server.tools(profile: profile)
    }

    /// The photo carousel (AT-050i), for chat apps that show MCP Apps views.
    func resources(for client: AgentClient, profile: AgentProfile) async -> [MCPResource] {
        [AtelierPhotoCarousel.resource]
    }

    /// The skills that are on, for chat apps that show prompts (Docent, under `/`).
    func prompts(for client: AgentClient, profile: AgentProfile) async -> [MCPPrompt] {
        AtelierSkills.prompts(skills.skills)
    }

    func prompt(_ name: String, arguments: [String: String], client: AgentClient, profile: AgentProfile) async -> String? {
        let text = AtelierSkills.promptText(name, arguments: arguments, skills: skills.skills, profile: profile,
                                            clientName: client.name)
        if let text, let server {
            await server.logCall(client, "prompts/get", .text(text), text: "Read the skill \(name)")
        }
        return text
    }

    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        guard let server else { return .error("Atelier is closing.") }
        if tool == AtelierAgentTools.getSkill.name {
            let result = AtelierSkills.getSkill(arguments, skills: skills.skills, profile: profile, clientName: client.name)
            let name = arguments["name"]?.stringValue ?? ""
            let file = arguments["file"]?.stringValue.map { " (\($0))" } ?? ""
            await server.logCall(client, tool, result, text: "Read the skill \(name)\(file)")
            return result
        }
        let result: MCPToolResult
        if Self.editsDevelop(tool, arguments), !(await server.waitForDevelopIdle()) {
            result = .error("The person is still dragging in Develop. Nothing was changed; try again in a moment.")
        } else if let measured = await server.callMeasuring(tool, arguments, client: client, profile: profile) {
            result = measured
        } else if let onMain = await server.callOnMain(tool, arguments, client: client, profile: profile) {
            result = onMain
        } else {
            result = lookTools.call(tool, arguments, options: AgentSettings.options)
        }
        await server.logCall(client, tool, result)
        return result
    }

    /// Develop edits wait for a drag in progress to end (AT-050d).
    static func editsDevelop(_ tool: String, _ arguments: [String: JSONValue]) -> Bool {
        if AtelierAgentTools.editTools.contains(where: { $0.name == tool }) { return true }
        // A batch may hold Develop steps: it waits too, so no step lands inside a drag.
        if tool == AtelierAgentTools.commandBatch.name { return true }
        guard tool == AtelierAgentTools.commandRun.name, let id = arguments["id"]?.stringValue,
              let action = AtelierAction.catalog.actions.first(where: { $0.id.rawValue == id }) else { return false }
        return action.kind == .edit && AtelierAgentTools.editProfile(action) == .edit
    }
}
