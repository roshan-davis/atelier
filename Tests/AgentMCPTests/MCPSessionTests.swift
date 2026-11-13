import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

/// An Easel-shaped host (documents and layers), so the module stays app-neutral.
final class SketchMCPHost: MCPHost, @unchecked Sendable {
    let lock = NSLock()
    var grants: [String: AgentProfile?] = [:]
    var calls: [(String, [String: JSONValue], String)] = []

    var serverInfo: MCPServerInfo {
        MCPServerInfo(name: "sketch", title: "Sketch", version: "1", instructions: "Sketch's documents and layers.")
    }

    func authorize(_ client: AgentClient) async -> AgentAuthorization {
        lock.withLock {
            guard let grant = grants[client.id] else { return .denied("\(client.name) isn't allowed. Allow it in Settings > Agents.") }
            guard let profile = grant else { return .denied("\(client.name) isn't allowed.") }
            return .allowed(profile)
        }
    }

    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] {
        var tools = [MCPTool(name: "list_documents", title: "List documents", description: "Open documents.", readOnly: true)]
        if profile >= .edit {
            tools.append(MCPTool(name: "rename_layer", title: "Rename layer", description: "Renames a layer.", readOnly: false))
        }
        return tools
    }

    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        lock.withLock { calls.append((tool, arguments, client.id)) }
        switch tool {
        case "list_documents": return .json(.object(["documents": .array([.string("Poster")])]))
        default: return .error("No such layer")
        }
    }

    func allow(_ id: String, _ profile: AgentProfile?) { lock.withLock { grants[id] = profile } }
}

final class MCPSessionTests: XCTestCase {
    let client = AgentClient(id: "com.example.chat#TEAM", name: "Chat", pid: 42)

    func send(_ session: MCPSession, _ text: String) async -> JSONValue? {
        guard let reply = await session.handle(Data(text.utf8)) else { return nil }
        return JSONValue(parsing: Data(reply.utf8))
    }

    func testInitializeNegotiatesVersionAndListsTools() async {
        let host = SketchMCPHost()
        host.allow(client.id, .look)
        let session = MCPSession(client: client, host: host)
        let reply = await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"opencode","version":"0.9"},"capabilities":{}}}"#)
        XCTAssertEqual(reply?["id"], .int(1))
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(reply?["result"]?["serverInfo"]?["name"], .string("sketch"))
        XCTAssertEqual(session.client.clientInfo, "opencode 0.9")
        let notified = await send(session, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notified)

        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["list_documents"])
        XCTAssertEqual(list?["result"]?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"], .bool(true))
    }

    func testUnknownVersionGetsPreferredOne() async {
        let host = SketchMCPHost()
        host.allow(client.id, .look)
        let session = MCPSession(client: client, host: host)
        let reply = await send(session, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string(MCPSession.preferredVersion))
        XCTAssertEqual(reply?["id"], .string("a"))
    }

    func testDeniedClientGetsReadableError() async {
        let host = SketchMCPHost()
        let session = MCPSession(client: client, host: host)
        let reply = await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertEqual(reply?["error"]?["code"], .int(-32001))
        XCTAssertTrue(reply?["error"]?["message"]?.stringValue?.contains("Settings > Agents") == true)
    }

    func testCallsCheckTheGrantEachTime() async {
        let host = SketchMCPHost()
        host.allow(client.id, .edit)
        let session = MCPSession(client: client, host: host)
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#
        let first = await send(session, call)
        XCTAssertEqual(first?["result"]?["isError"], .bool(false))
        XCTAssertEqual(first?["result"]?["structuredContent"]?["documents"], .array([.string("Poster")]))
        XCTAssertEqual(first?["result"]?["content"]?.arrayValue?.first?["type"], .string("text"))

        host.allow(client.id, nil)   // revoked in Settings
        let second = await send(session, call)
        XCTAssertEqual(second?["error"]?["code"], .int(-32001))
        XCTAssertEqual(host.calls.count, 1)
    }

    func testToolsAboveTheProfileAreUnknown() async {
        let host = SketchMCPHost()
        host.allow(client.id, .look)
        let session = MCPSession(client: client, host: host)
        let reply = await send(session, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rename_layer","arguments":{}}}"#)
        XCTAssertEqual(reply?["error"]?["code"], .int(-32602))
        let typo = await send(session, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_document"}}"#)
        XCTAssertTrue(typo?["error"]?["message"]?.stringValue?.contains("Did you mean list_documents?") == true)
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testToolErrorsAreResultsNotProtocolErrors() async {
        let host = SketchMCPHost()
        host.allow(client.id, .edit)
        let session = MCPSession(client: client, host: host)
        let reply = await send(session, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rename_layer","arguments":{"name":"Sky"}}}"#)
        XCTAssertEqual(reply?["result"]?["isError"], .bool(true))
        XCTAssertEqual(host.calls.first?.1["name"], .string("Sky"))
    }

    func testMalformedMessages() async {
        let session = MCPSession(client: client, host: SketchMCPHost())
        let notJSON = await send(session, "hello")
        XCTAssertEqual(notJSON?["error"]?["code"], .int(-32700))
        let batch = await send(session, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(batch?["error"]?["code"], .int(-32600))
        let unknown = await send(session, #"{"jsonrpc":"2.0","id":7,"method":"sampling/createMessage"}"#)
        XCTAssertEqual(unknown?["error"]?["code"], .int(-32601))
        let ping = await send(session, #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        XCTAssertEqual(ping?["result"], .object([:]))
        let response = await send(session, #"{"jsonrpc":"2.0","id":9,"result":{}}"#)
        XCTAssertNil(response)
    }

    func testCompactTextIsOneSortedLine() {
        let value = JSONValue.object(["b": .array([.int(1), .string("x\ny")]), "a": .bool(true)])
        XCTAssertEqual(value.compactText, #"{"a":true,"b":[1,"x\ny"]}"#)
        XCTAssertEqual(JSONValue(parsing: Data(value.compactText.utf8)), value)
    }

    func testSuggest() {
        XCTAssertEqual(Suggest.closest(to: "serch_photos", in: ["search_photos", "get_photo"]), "search_photos")
        XCTAssertNil(Suggest.closest(to: "export", in: ["search_photos", "get_photo"]))
    }
}

final class AgentProfileTests: XCTestCase {
    func descriptor(_ kind: ActionKind, hidden: String? = nil) -> ActionDescriptor {
        Action<NoParameters>("layer.thing", "Thing", place: "Layer", summary: "Does a thing.", kind: kind,
                             hidden: hidden).descriptor
    }

    func testMinimumProfileFollowsKind() {
        let edit: (ActionDescriptor) -> AgentProfile = { _ in .edit }
        XCTAssertEqual(AgentProfile.minimum(for: descriptor(.reads), editProfile: edit), .look)
        XCTAssertEqual(AgentProfile.minimum(for: descriptor(.view), editProfile: edit), .organize)
        XCTAssertEqual(AgentProfile.minimum(for: descriptor(.edit), editProfile: edit), .edit)
        XCTAssertEqual(AgentProfile.minimum(for: descriptor(.writesFiles), editProfile: edit), .everything)
        XCTAssertEqual(AgentProfile.minimum(for: descriptor(.opensApp), editProfile: edit), .everything)
        XCTAssertNil(AgentProfile.minimum(for: descriptor(.deletes), editProfile: edit))
        XCTAssertNil(AgentProfile.minimum(for: descriptor(.reads, hidden: "debug only"), editProfile: edit))
        XCTAssertTrue(AgentProfile.look < .organize && AgentProfile.edit < .everything)
    }
}
