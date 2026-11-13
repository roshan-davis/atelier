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
    @AppStorage("agents.setupClient") private var client: AgentHelper.Client = .openCode
    @State private var copied: String?

    var body: some View {
        Form {
            SettingsSection("Access") {
                Toggle("Allow chat apps to use Atelier", isOn: Binding(
                    get: { server.isRunning || (AgentSettings.isEnabled && server.problem != nil) },
                    set: { server.setEnabled($0) }))
                status
                Toggle("Let agents see photo previews", isOn: $previews)
                Toggle("Include location in photo details", isOn: $location)
            } footer: {
                Text("Chat apps such as OpenCode, Claude or Cherry Studio connect through Atelier's helper, and Atelier asks you the first time each one connects. Whatever Atelier tells an app goes to the model it uses: with Ollama nothing leaves this Mac, with a hosted model it goes to that provider. Private photos are never shared. Agents can only read in this version.")
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
                ForEach(server.activity.entries.prefix(100)) { entry in
                    ActivityRow(entry: entry)
                }
            } trailing: {
                Button {
                    server.clearActivity()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help("Clear the activity log")
                .disabled(server.activity.entries.isEmpty)
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

    private func copy(_ text: String, as name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = name == "Path" ? nil : name
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
        .accessibilityElement(children: .combine)
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
