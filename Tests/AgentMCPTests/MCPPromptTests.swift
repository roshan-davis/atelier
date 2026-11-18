import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

/// The Easel-shaped host with prompts, as an app lists its skills (SL-002c).
final class SketchPromptHost: MCPPromptHost, @unchecked Sendable {
    let base = SketchMCPHost()
    var serverInfo: MCPServerInfo { base.serverInfo }
    func authorize(_ client: AgentClient) async -> AgentAuthorization { await base.authorize(client) }
    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] { await base.tools(for: client, profile: profile) }
    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        await base.call(tool, arguments: arguments, client: client, profile: profile)
    }

    func prompts(for client: AgentClient, profile: AgentProfile) async -> [MCPPrompt] {
        [MCPPrompt(name: "tidy-layers", title: "Tidy the layers", description: "Names and groups layers.",
                   arguments: [.init(name: "document", description: "Which document.", required: false)])]
    }

    func prompt(_ name: String, arguments: [String: String], client: AgentClient, profile: AgentProfile) async -> String? {
        name == "tidy-layers" ? "Tidy \(arguments["document"] ?? "not given")." : nil
    }
}

final class MCPPromptTests: XCTestCase {
    let client = AgentClient(id: "com.example.chat#TEAM", name: "Chat", pid: 42)

    func send(_ session: MCPSession, _ text: String) async -> JSONValue? {
        guard let reply = await session.handle(Data(text.utf8)) else { return nil }
        return JSONValue(parsing: Data(reply.utf8))
    }

    func testPromptsAreDeclaredListedAndFilledIn() async {
        let host = SketchPromptHost()
        host.base.allow(client.id, .look)
        let session = MCPSession(client: client, host: host, output: { _ in true })
        let initialize = await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        XCTAssertEqual(initialize?["result"]?["capabilities"]?["prompts"]?["listChanged"], .bool(true))

        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#)
        let prompt = list?["result"]?["prompts"]?.arrayValue?.first
        XCTAssertEqual(prompt?["name"], .string("tidy-layers"))
        XCTAssertEqual(prompt?["arguments"]?.arrayValue?.first?["required"], .bool(false))

        let get = await send(session, #"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"tidy-layers","arguments":{"document":"Poster"}}}"#)
        let message = get?["result"]?["messages"]?.arrayValue?.first
        XCTAssertEqual(message?["role"], .string("user"))
        XCTAssertEqual(message?["content"]?["text"], .string("Tidy Poster."))

        let unknown = await send(session, #"{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"tidy-layer"}}"#)
        XCTAssertEqual(unknown?["error"]?["message"], .string("Unknown prompt: tidy-layer. Did you mean tidy-layers?"))
    }

    func testPromptsChangedIsSentOnlyAfterInitialize() async {
        let host = SketchPromptHost()
        host.base.allow(client.id, .look)
        let sent = LockedLines()
        let session = MCPSession(client: client, host: host, output: { sent.append($0) })
        XCTAssertFalse(session.promptsChanged())
        _ = await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        XCTAssertTrue(session.promptsChanged())
        XCTAssertEqual(sent.lines.count, 1)
        XCTAssertTrue(sent.lines[0].contains(MCPSession.promptsListChanged))
    }

    func testHostsWithoutPromptsListNone() async {
        let host = SketchMCPHost()
        host.allow(client.id, .look)
        let session = MCPSession(client: client, host: host, output: { _ in true })
        let initialize = await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        XCTAssertNil(initialize?["result"]?["capabilities"]?["prompts"])
        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#)
        XCTAssertEqual(list?["result"]?["prompts"], .array([]))
        XCTAssertFalse(session.promptsChanged())
    }

    func testDeniedClientsGetNoPrompts() async {
        let host = SketchPromptHost()
        let session = MCPSession(client: client, host: host)
        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#)
        XCTAssertEqual(list?["error"]?["code"], .int(-32001))
    }
}

/// Lines sent by a session, from any thread.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) -> Bool {
        lock.withLock { stored.append(line) }
        return true
    }
}
