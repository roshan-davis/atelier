import AgentMCP
import AppKit
import SwiftUI

/// Where the `atelier-mcp` helper is: next to Atelier's own executable (Contents/MacOS in a
/// built app; Xcode's Products folder once the atelier-mcp scheme is built).
enum AgentHelper {
    static var url: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("atelier-mcp")
    }

    static var isBuilt: Bool { url.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    /// The helper's path, quoted for Terminal when it has spaces.
    static func shellPath(_ path: String) -> String {
        path.contains(" ") ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }

    /// A chat app's setup, ready to paste, for Copy Setup.
    enum Client: String, CaseIterable, Identifiable {
        case openCode, cherry, ollmcp, lmStudio, claudeDesktop, claudeCode, codex

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openCode: return "OpenCode"
            case .cherry: return "Cherry Studio"
            case .ollmcp: return "Ollama (ollmcp)"
            case .lmStudio: return "LM Studio"
            case .claudeDesktop: return "Claude Desktop"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// Where the copied text goes.
        var hint: String {
            switch self {
            case .openCode: return "Paste in Terminal. It adds Atelier to ~/.config/opencode/opencode.json; check with opencode mcp list."
            case .cherry: return "Paste as the Command in Settings > MCP Server > Add server (Type STDIO)."
            case .ollmcp: return "Paste in Terminal, then run ollmcp."
            case .lmStudio: return "Paste inside \"mcpServers\" in Program > Install > Edit mcp.json."
            case .claudeDesktop: return "Paste inside \"mcpServers\" in Claude > Settings… > Developer > Edit Config, then reopen Claude."
            case .claudeCode: return "Paste in Terminal."
            case .codex: return "Paste into ~/.codex/config.toml."
            }
        }

        func setup(helper path: String) -> String {
            let json = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            switch self {
            // `opencode mcp add … -- <command>` saved nothing on Rosh's Mac (Nov 12, 2026), so this
            // adds the server to OpenCode's settings file, keeping what is already there.
            case .openCode:
                return """
                    python3 - \(shellPath(path)) <<'EOF'
                    import json, os, sys
                    path = os.path.expanduser("~/.config/opencode/opencode.json")
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    config = json.load(open(path)) if os.path.exists(path) else {"$schema": "https://opencode.ai/config.json"}
                    config.setdefault("mcp", {})["atelier"] = {"type": "local", "command": [sys.argv[1]], "enabled": True}
                    json.dump(config, open(path, "w"), indent=2)
                    print("Saved", path)
                    EOF
                    """
            case .cherry: return path
            case .ollmcp: return "ollmcp mcp add atelier --scope user -- \(shellPath(path))"
            case .lmStudio, .claudeDesktop: return "\"atelier\": { \"command\": \"\(json)\", \"args\": [] }"
            case .claudeCode: return "claude mcp add --transport stdio --scope user atelier -- \(shellPath(path))"
            case .codex: return "[mcp_servers.atelier]\ncommand = \"\(json)\"\nargs = []"
            }
        }
    }
}

/// Atelier > Settings… > Agents: whether chat apps may connect, what each one may do, the
/// helper to point them at, and what they did.
struct AgentsSettings: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        AgentsSettingsForm(server: model.agents)
    }
}

private struct AgentsSettingsForm: View {
    @ObservedObject var server: AgentServer
    @AppStorage(AgentSettings.previewsKey) private var previews = false
    @AppStorage(AgentSettings.locationKey) private var location = false
    @AppStorage(AgentSettings.confirmAboveKey) private var confirmAbove = 50
    @AppStorage("agents.setupClient") private var client: AgentHelper.Client = .openCode
    @State private var copied: String?
    @State private var selectedActivity: Set<UUID> = []
    /// The line a ⇧-click range starts from.
    @State private var activityAnchor: UUID?

    var body: some View {
        Form {
            SettingsSection("Access") {
                Toggle("Allow chat apps to use Atelier", isOn: Binding(
                    get: { server.isRunning || (AgentSettings.isEnabled && server.problem != nil) },
                    set: { server.setEnabled($0) }))
                status
                DockStatus(dock: server.dock)
                Toggle("Let agents see photo previews", isOn: $previews)
                    // get_preview comes and goes: connected chat apps list the tools again.
                    .onChange(of: previews) { _, _ in server.toolsChanged() }
                Toggle("Include location in photo details", isOn: $location)
                Picker("Ask before one change touches more than", selection: $confirmAbove) {
                    ForEach([10, 25, 50, 100, 250, 500], id: \.self) { count in
                        Text("\(count) photos").tag(count)
                    }
                    Divider()
                    Text("Never ask").tag(0)
                }
            } footer: {
                Text("Chat apps such as OpenCode, Claude or Cherry Studio connect through Atelier's helper, and Atelier asks you the first time each one connects. Whatever Atelier tells an app goes to the model it uses: with Ollama nothing leaves this Mac, with a hosted model it goes to that provider. Private photos are never shared. Apps allowed Organize can rate, flag, label, add keywords and add to collections: each change shows a notice with Undo at the bottom of the photo, and nothing an app does deletes anything. A chat app built for it (Docent) can dock Atelier's window beside its own; no model can move the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Apps") {
                if server.grantList.isEmpty {
                    Text("No chat app has connected yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(server.grantList) { grant in
                    GrantRow(grant: grant, isConnected: server.connected.contains { $0.id == grant.clientID },
                             setProfile: { server.setProfile($0, for: grant.clientID) },
                             forget: { server.forget(clientID: grant.clientID) })
                }
            } footer: {
                Text("Atelier names each app from its code signature, not from what the app says. Apps started from Terminal (Claude Code, OpenCode, ollmcp) are listed as Terminal. Changing an app's access disconnects it; it reconnects with the new access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PhoneSettingsSection(phone: server.phone)

            SettingsSection("Connect an App") {
                LabeledContent("Helper") {
                    if let url = AgentHelper.url, AgentHelper.isBuilt {
                        HStack {
                            Text(url.path)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Button("Copy") { copy(url.path, as: "Path") }
                        }
                    } else {
                        Text("Not built. In Xcode, choose Product > Scheme > atelier-mcp, then Product > Build (⌘B), then switch back to the AtelierApp scheme.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = AgentHelper.url, AgentHelper.isBuilt {
                    LabeledContent("Setup for") {
                        HStack {
                            Picker("Setup for", selection: $client) {
                                ForEach(AgentHelper.Client.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Copy Setup") { copy(client.setup(helper: url.path), as: client.title) }
                        }
                    }
                    Text(copied.map { "Copied the \($0) setup. " + client.hint } ?? client.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Help > Atelier Help > Connect a chat app has the steps for each app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Activity") {
                if server.activity.entries.isEmpty {
                    Text("Nothing yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shownActivity) { entry in
                    ActivityRow(entry: entry, isSelected: selectedActivity.contains(entry.id))
                        .contentShape(Rectangle())
                        .onTapGesture { selectActivity(entry) }
                        .contextMenu {
                            Button(copyTitle(for: entry)) {  // not an action: a Settings list, not a command
                                copyActivity(selectedActivity.contains(entry.id) ? nil : [entry.id])
                            }
                            Button("Copy All") { copyActivity(Set(shownActivity.map(\.id))) }  // not an action: a Settings list, not a command
                        }
                }
            } footer: {
                if !server.activity.entries.isEmpty {
                    Text("Click a line to select it; ⌘-click adds lines, ⇧-click selects a range. Copy copies the selected lines, or all of them when none is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                HStack(spacing: 2) {
                    Button {
                        copyActivity(nil)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(SidebarIconButtonStyle())
                    .help(selectedActivity.isEmpty ? "Copy the activity log" : "Copy the selected lines")
                    .disabled(server.activity.entries.isEmpty)
                    Button {
                        selectedActivity = []
                        server.clearActivity()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(SidebarIconButtonStyle())
                    .help("Clear the activity log")
                    .disabled(server.activity.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: client) { _, _ in copied = nil }
    }

    @ViewBuilder private var status: some View {
        if let problem = server.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if server.isRunning {
            let count = server.connected.count
            Label(count == 0 ? "Ready. No app is connected." : "\(count) app\(count == 1 ? "" : "s") connected.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        }
    }

    private func copyTitle(for entry: AgentActivity) -> String {
        selectedActivity.contains(entry.id) && selectedActivity.count > 1 ? "Copy \(selectedActivity.count) Lines" : "Copy"
    }

    private var shownActivity: [AgentActivity] { Array(server.activity.entries.prefix(100)) }

    /// Click selects one line (or clears it), ⌘-click adds or removes one, ⇧-click a range, as in Finder.
    private func selectActivity(_ entry: AgentActivity) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = activityAnchor,
           let from = shownActivity.firstIndex(where: { $0.id == anchor }),
           let to = shownActivity.firstIndex(where: { $0.id == entry.id }) {
            selectedActivity = Set(shownActivity[min(from, to)...max(from, to)].map(\.id))
            return
        }
        if modifiers.contains(.command) {
            if selectedActivity.contains(entry.id) { selectedActivity.remove(entry.id) } else { selectedActivity.insert(entry.id) }
        } else {
            selectedActivity = selectedActivity == [entry.id] ? [] : [entry.id]
        }
        activityAnchor = entry.id
    }

    /// Copies `ids` (nil: the selection, or every line when nothing is selected), oldest first,
    /// one line each: "2026-11-12 21:41:33  Cherry Studio  get_preview".
    private func copyActivity(_ ids: Set<UUID>?) {
        let chosen = ids ?? (selectedActivity.isEmpty ? Set(shownActivity.map(\.id)) : selectedActivity)
        let lines = shownActivity.filter { chosen.contains($0.id) }.reversed().map { entry in
            "\(Self.logTime.string(from: entry.date))  \(entry.clientName)  \(entry.text)"
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func copy(_ text: String, as name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = name == "Path" ? nil : name
    }
}

/// "Docked beside Docent", with Undock, while a chat app has docked Atelier's window (AT-050h).
private struct DockStatus: View {
    @ObservedObject var dock: AgentDock

    var body: some View {
        if let client = dock.dockedTo {
            HStack {
                Label("Atelier's window is docked beside \(client.name).", systemImage: "rectangle.split.2x1")
                    .font(.callout)
                Spacer()
                Button("Undock") { dock.undockByHand() }
                    .controlSize(.small)
            }
        }
    }
}

/// One app's access: its name and path, whether it's connected, the profile menu and Remove.
private struct GrantRow: View {
    let grant: AgentGrant
    let isConnected: Bool
    let setProfile: (AgentProfile?) -> Void
    let forget: () -> Void

    var body: some View {
        LabeledContent {
            HStack {
                Picker(grant.name, selection: Binding(get: { grant.profile }, set: { setProfile($0) })) {
                    Text("Don't Allow").tag(AgentProfile?.none)
                    Divider()
                    ForEach(AgentProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(AgentProfile?.some(profile))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(grant.profile?.summary ?? "This app can't use Atelier.")
                Button(action: forget) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help("Remove \(grant.name). Atelier asks again the next time it connects.")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(isConnected ? "Connected" : "Not connected")
                    Text(grant.name)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let seen = grant.lastSeen { parts.append("Last used \(seen.formatted(.relative(presentation: .named)))") }
        if let path = grant.path { parts.append(path) }
        return parts.isEmpty ? "Never used" : parts.joined(separator: " · ")
    }
}

private struct ActivityRow: View {
    let entry: AgentActivity
    var isSelected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(entry.kind == .failed || entry.kind == .denied ? Color.orange : Color.secondary)
                .frame(width: 16)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.clientName)
                .fontWeight(.medium)
            Text(entry.text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var symbol: String {
        switch entry.kind {
        case .connected: return "link"
        case .disconnected: return "power"
        case .allowed: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .call: return "magnifyingglass"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
