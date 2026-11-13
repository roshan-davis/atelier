import AgentMCP
import AppKit

/// The question Atelier asks the first time a chat app connects: "Allow “Claude” to use
/// Atelier?", with the profile to grant (the one the app asked for is chosen, Look when it
/// asked for none). Asked in Atelier's own window, so only the person can answer it; the
/// chat app can't. The answer is stored per app and changed in Settings > Agents.
@MainActor
enum AgentApproval {
    /// The profile to grant, or nil for Don't Allow.
    static func ask(_ client: AgentClient) -> AgentProfile? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow “\(client.name)” to use Atelier?"
        var details = "\(client.name) wants to work with your photo library through Atelier's agent connection (MCP)."
        if let info = client.clientInfo, info.lowercased() != client.name.lowercased() {
            details += " It calls itself “\(info)”."
        }
        if let path = client.path { details += "\n\n\(path)" }
        details += "\n\nWhatever Atelier tells it goes to the model the app uses. Private photos are never shared. "
            + "You can change this later in Atelier > Settings… > Agents."
        alert.informativeText = details

        let requested = client.requestedProfile ?? .look
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for profile in AgentProfile.allCases {
            popup.addItem(withTitle: "\(profile.title): \(profile.summary)")
            popup.lastItem?.representedObject = profile.rawValue
        }
        popup.selectItem(at: AgentProfile.allCases.firstIndex(of: requested) ?? 0)
        popup.sizeToFit()
        let label = NSTextField(labelWithString: client.requestedProfile == nil
                                ? "Allow as:" : "Allow as (it asked for \(requested.title)):")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: max(popup.frame.width, 300), height: 54)
        alert.accessoryView = stack

        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (popup.selectedItem?.representedObject as? String).flatMap(AgentProfile.init(rawValue:)) ?? .look
    }
}
