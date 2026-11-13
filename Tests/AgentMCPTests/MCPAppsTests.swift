import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

/// An Easel-shaped host with a layer strip view and a tool only that view calls.
final class SketchViewsHost: MCPResourceHost, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []

    static let strip = MCPResource(uri: "ui://sketch/layers", name: "layers", title: "Layers",
                                   description: "The layers as a strip.", mimeType: MCPApps.mimeType,
                                   text: "<!doctype html><title>Layers</title>",
                                   ui: .object(["prefersBorder": .bool(false)]))
    static let notes = MCPResource(uri: "sketch://notes", name: "notes", title: "Notes", description: "Notes.",
                                   mimeType: "text/plain", text: "hello")

    var serverInfo: MCPServerInfo { MCPServerInfo(name: "sketch", title: "Sketch", version: "1", instructions: "") }

    func authorize(_ client: AgentClient) async -> AgentAuthorization { .allowed(.look) }

    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] {
        [MCPTool(name: "list_layers", title: "List layers", description: "Layers.", readOnly: true,
                 ui: MCPToolUI(resourceURI: Self.strip.uri)),
         MCPTool(name: "layer_thumbnails", title: "Layer thumbnails", description: "For the strip.", readOnly: true,
                 ui: .appOnly)]
    }

    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        lock.withLock { calls.append(tool) }
        return .json(.object(["thumbnails": .array([.string(String(repeating: "x", count: 100))])]), text: "1 thumbnail")
    }

    func resources(for client: AgentClient, profile: AgentProfile) async -> [MCPResource] { [Self.strip, Self.notes] }
}

final class MCPAppsTests: XCTestCase {
    let client = AgentClient(id: "com.example.docent#TEAM", name: "Docent", pid: 7)

    func send(_ session: MCPSession, _ text: String) async -> JSONValue? {
        guard let reply = await session.handle(Data(text.utf8)) else { return nil }
        return JSONValue(parsing: Data(reply.utf8))
    }

    static let withViews = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}}"#
    static let withoutViews = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#

    func testClientThatShowsViewsSeesLinksViewsAndAppOnlyTools() async {
        let host = SketchViewsHost()
        let session = MCPSession(client: client, host: host)
        let initialized = await send(session, Self.withViews)
        XCTAssertTrue(session.showsViews)
        XCTAssertNotNil(initialized?["result"]?["capabilities"]?["resources"])
        XCTAssertNotNil(initialized?["result"]?["capabilities"]?["extensions"]?[MCPApps.extensionID])

        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["list_layers", "layer_thumbnails"])
        XCTAssertEqual(tools[0]["_meta"]?["ui"]?["resourceUri"], .string("ui://sketch/layers"))
        XCTAssertEqual(tools[0]["_meta"]?["ui/resourceUri"], .string("ui://sketch/layers"))
        XCTAssertEqual(tools[1]["_meta"]?["ui"]?["visibility"], .array([.string("app")]))

        let resources = await send(session, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        XCTAssertEqual(resources?["result"]?["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue },
                       ["ui://sketch/layers", "sketch://notes"])
        XCTAssertNil(resources?["result"]?["resources"]?.arrayValue?.first?["text"])

        let read = await send(session, #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"ui://sketch/layers"}}"#)
        let content = read?["result"]?["contents"]?.arrayValue?.first
        XCTAssertEqual(content?["mimeType"], .string(MCPApps.mimeType))
        XCTAssertEqual(content?["text"], .string("<!doctype html><title>Layers</title>"))
        XCTAssertEqual(content?["_meta"]?["ui"]?["prefersBorder"], .bool(false))

        let call = await send(session, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"layer_thumbnails","arguments":{}}}"#)
        XCTAssertEqual(call?["result"]?["content"]?.arrayValue?.first?["text"], .string("1 thumbnail"))
        XCTAssertNotNil(call?["result"]?["structuredContent"]?["thumbnails"])
        XCTAssertEqual(host.calls, ["layer_thumbnails"])
    }

    func testClientWithoutViewsSeesNoneOfIt() async {
        let host = SketchViewsHost()
        let session = MCPSession(client: client, host: host)
        _ = await send(session, Self.withoutViews)
        XCTAssertFalse(session.showsViews)

        let list = await send(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["list_layers"])
        XCTAssertNil(tools[0]["_meta"])

        let resources = await send(session, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        XCTAssertEqual(resources?["result"]?["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue }, ["sketch://notes"])
        let read = await send(session, #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"ui://sketch/layers"}}"#)
        XCTAssertEqual(read?["error"]?["code"], .int(-32002))

        let call = await send(session, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"layer_thumbnails","arguments":{}}}"#)
        XCTAssertEqual(call?["error"]?["code"], .int(-32602))
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testDeclaringTheExtensionWithoutTheHTMLTypeIsNotEnough() {
        XCTAssertFalse(MCPApps.clientSupports(JSONValue(parsing: Data(#"{"extensions":{"io.modelcontextprotocol/ui":{}}}"#.utf8))))
        XCTAssertFalse(MCPApps.clientSupports(nil))
    }

    func testHostWithoutResourcesListsNone() async {
        let host = SketchMCPHost()
        host.allow(client.id, .look)
        let session = MCPSession(client: client, host: host)
        let initialized = await send(session, Self.withViews)
        XCTAssertNil(initialized?["result"]?["capabilities"]?["resources"])
        let resources = await send(session, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        XCTAssertEqual(resources?["result"]?["resources"], .array([]))
    }
}
