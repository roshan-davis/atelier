import AgentMCP
import Foundation

// atelier-mcp: the stdio MCP server that chat apps start. It relays to the Atelier app over a
// private socket; Atelier itself decides what each app may do (Settings > Agents).
//
//   atelier-mcp [--profile look|organize|edit|everything]
//
// --profile is only a request; the person chooses the grant in Atelier.

var arguments = CommandLine.arguments.dropFirst()
var profile: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--profile":
        profile = arguments.popFirst()
    case "--help", "-h":
        print("atelier-mcp [--profile look|organize|edit|everything]: connects a chat app to Atelier over MCP (stdio).")
        exit(0)
    case "--version":
        print("atelier-mcp 1")
        exit(0)
    default:
        FileHandle.standardError.write(Data("atelier-mcp: unknown option \(argument)\n".utf8))
        exit(2)
    }
}
exit(MCPRelay.run(socketPath: AgentSocketPath.path(app: "Atelier"), requestedProfile: profile))
