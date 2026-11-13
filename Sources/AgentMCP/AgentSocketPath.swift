import Foundation

/// Where an app listens and its helper connects: `~/Library/Application Support/<App>/Agents/<app>.sock`.
/// `<APP>_MCP_SOCKET` overrides it (tests, a second copy of the app).
public enum AgentSocketPath {
    public static func path(app: String) -> String {
        let key = app.uppercased() + "_MCP_SOCKET"
        if let path = ProcessInfo.processInfo.environment[key], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("\(app)/Agents/\(app.lowercased()).sock").path
    }
}
