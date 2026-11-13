import AgentActions
import Foundation

/// An MCP tool as listed to clients.
public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    /// MCP Apps: the view that shows this tool's results, or who may call it.
    public var ui: MCPToolUI?

    public init(name: String, title: String, description: String, inputSchema: JSONValue = .emptyObjectSchema,
                readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, ui: MCPToolUI? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.ui = ui
    }

    /// Only a view calls it; the model never sees it.
    public var isAppOnly: Bool { ui.map { !$0.visibility.contains(.model) } ?? false }

    public var json: JSONValue { json(apps: true) }

    /// Without `apps` (the client doesn't show views), the view link is left out.
    public func json(apps: Bool) -> JSONValue {
        var members: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                // Atelier's own library only; nothing on the internet.
                "openWorldHint": .bool(false),
            ]),
        ]
        if apps, let ui {
            var meta: [String: JSONValue] = ["ui": ui.json]
            // The flat key that hosts from before the stable spec read.
            if let uri = ui.resourceURI { meta["ui/resourceUri"] = .string(uri) }
            members["_meta"] = .object(meta)
        }
        return .object(members)
    }
}

public extension JSONValue {
    static let emptyObjectSchema = JSONValue.object([
        "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
    ])
}

/// What a tool call returns: a JSON result (also sent as text for clients that only read text),
/// optional images, or an error the model can read and recover from.
public struct MCPToolResult: Sendable, Hashable {
    public var structured: JSONValue?
    public var text: String
    public var images: [(data: Data, mimeType: String)] { imageList.map { ($0.data, $0.mimeType) } }
    var imageList: [Image]
    public var isError: Bool

    struct Image: Sendable, Hashable { var data: Data; var mimeType: String }

    public static func json(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(structured: value, text: value.compactText, imageList: [], isError: false)
    }

    /// A result whose structured part is for a view (large, such as thumbnails), with a short text.
    public static func json(_ value: JSONValue, text: String) -> MCPToolResult {
        MCPToolResult(structured: value, text: text, imageList: [], isError: false)
    }

    public static func image(_ data: Data, mimeType: String, caption: JSONValue) -> MCPToolResult {
        MCPToolResult(structured: caption, text: caption.compactText,
                      imageList: [Image(data: data, mimeType: mimeType)], isError: false)
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(structured: nil, text: message, imageList: [], isError: true)
    }

    public static func == (lhs: MCPToolResult, rhs: MCPToolResult) -> Bool {
        lhs.structured == rhs.structured && lhs.text == rhs.text && lhs.imageList == rhs.imageList && lhs.isError == rhs.isError
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(isError)
    }

    var json: JSONValue {
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for image in imageList {
            content.append(.object(["type": .string("image"), "data": .string(image.data.base64EncodedString()),
                                    "mimeType": .string(image.mimeType)]))
        }
        var members: [String: JSONValue] = ["content": .array(content), "isError": .bool(isError)]
        if let structured, case .object = structured { members["structuredContent"] = structured }
        return .object(members)
    }
}

public struct MCPServerInfo: Sendable {
    public var name: String
    public var title: String
    public var version: String
    public var instructions: String

    public init(name: String, title: String, version: String, instructions: String) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
    }
}

/// The app behind the server. Every call names the checked client; `authorize` runs before
/// each request (it may ask the person the first time), so a revoked grant stops the next call.
public protocol MCPHost: AnyObject, Sendable {
    var serverInfo: MCPServerInfo { get }
    func authorize(_ client: AgentClient) async -> AgentAuthorization
    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool]
    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult
}

/// One client's conversation: JSON-RPC 2.0 messages, one per line, as MCP's stdio transport
/// sends them. Messages are handled in order.
public final class MCPSession: @unchecked Sendable {
    /// Newest first. 2026-07-28 clients are answered with 2025-06-18, which they accept.
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let preferredVersion = "2025-06-18"

    public private(set) var client: AgentClient
    public private(set) var protocolVersion: String?
    /// The client shows MCP Apps views (it declared `io.modelcontextprotocol/ui` in `initialize`).
    public private(set) var showsViews = false
    private let host: MCPHost
    private let output: (@Sendable (String) -> Bool)?
    private var openChannel: MCPChannel?

    /// `output` sends a line to the client outside a reply (notifications such as
    /// `docking/moved`); without it the session only answers.
    public init(client: AgentClient, host: MCPHost, output: (@Sendable (String) -> Bool)? = nil) {
        self.client = client
        self.host = host
        self.output = output
    }

    private var docking: DockingCoordinator? { (host as? MCPDockingHost)?.docking }

    private var channel: MCPChannel {
        if let openChannel { return openChannel }
        let channel = MCPChannel(client: client, output: output)
        openChannel = channel
        return channel
    }

    /// The connection is gone: windows it docked are let go.
    public func close() async {
        guard let openChannel else { return }
        openChannel.close()
        await docking?.closed(openChannel)
    }

    /// Handles one line; returns the reply line, or nil for notifications.
    public func handle(_ line: Data) async -> String? {
        guard let message = JSONValue(parsing: line) else {
            return Self.error(id: .null, code: -32700, message: "Parse error: not JSON").compactText
        }
        if case .array = message {
            return Self.error(id: .null, code: -32600, message: "Batches are not supported (MCP 2025-06-18)").compactText
        }
        guard case .object(let members) = message, members["jsonrpc"]?.stringValue == "2.0",
              let method = members["method"]?.stringValue else {
            // A response from the client to something we never sent, or not JSON-RPC.
            if message["id"] != nil, message["method"] == nil { return nil }
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid request").compactText
        }
        let params = members["params"]?.objectValue ?? [:]
        guard let id = members["id"] else {
            notification(method, params)
            return nil
        }
        let reply = await request(method, params, id: id)
        return reply.compactText
    }

    private func notification(_ method: String, _ params: [String: JSONValue]) {
        // notifications/initialized, notifications/cancelled: nothing runs long in this phase.
    }

    private func request(_ method: String, _ params: [String: JSONValue], id: JSONValue) async -> JSONValue {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.preferredVersion
            protocolVersion = version
            if let info = params["clientInfo"]?.objectValue {
                let name = info["name"]?.stringValue ?? "?"
                client.clientInfo = info["version"]?.stringValue.map { "\(name) \($0)" } ?? name
            }
            showsViews = MCPApps.clientSupports(params["capabilities"])
            if case .denied(let reason) = await host.authorize(client) {
                return Self.error(id: id, code: -32001, message: reason)
            }
            let info = host.serverInfo
            var capabilities: [String: JSONValue] = ["tools": .object(["listChanged": .bool(false)])]
            if host is MCPResourceHost {
                capabilities["resources"] = .object(["listChanged": .bool(false)])
            }
            if showsViews, host is MCPResourceHost {
                capabilities["extensions"] = .object([MCPApps.extensionID: .object([:])])
            }
            // Docking needs a way back to the client for its notifications.
            if docking != nil, output != nil {
                capabilities["experimental"] = .object(["docking": DockingProtocol.capability])
            }
            return Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(capabilities),
                "serverInfo": .object(["name": .string(info.name), "title": .string(info.title),
                                       "version": .string(info.version)]),
                "instructions": .string(info.instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            switch await host.authorize(client) {
            case .denied(let reason):
                return Self.error(id: id, code: -32001, message: reason)
            case .allowed(let profile):
                let tools = await visibleTools(profile)
                return Self.result(id: id, .object(["tools": .array(tools.map { $0.json(apps: showsViews) })]))
            }
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            switch await host.authorize(client) {
            case .denied(let reason):
                return Self.error(id: id, code: -32001, message: reason)
            case .allowed(let profile):
                let tools = await visibleTools(profile)
                guard tools.contains(where: { $0.name == name }) else {
                    let names = tools.filter { !$0.isAppOnly }.map(\.name)
                    let hint = Suggest.closest(to: name, in: names).map { " Did you mean \($0)?" } ?? ""
                    return Self.error(id: id, code: -32602, message: "Unknown tool: \(name).\(hint)")
                }
                let arguments = params["arguments"]?.objectValue ?? [:]
                let result = await host.call(name, arguments: arguments, client: client, profile: profile)
                return Self.result(id: id, result.json)
            }
        case let method where DockingProtocol.methods.contains(method):
            guard let docking, output != nil else {
                return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
            }
            if case .denied(let reason) = await host.authorize(client) {
                return Self.error(id: id, code: -32001, message: reason)
            }
            switch await docking.handle(method, params, channel: channel) {
            case .success(let result):
                return Self.result(id: id, result)
            case .failure(let failure):
                return Self.error(id: id, code: failure.code, message: failure.message, data: failure.data)
            }
        case "resources/list":
            switch await host.authorize(client) {
            case .denied(let reason):
                return Self.error(id: id, code: -32001, message: reason)
            case .allowed(let profile):
                let resources = await visibleResources(profile)
                return Self.result(id: id, .object(["resources": .array(resources.map(\.listing))]))
            }
        case "resources/templates/list":
            return Self.result(id: id, .object(["resourceTemplates": .array([])]))
        case "resources/read":
            guard let uri = params["uri"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "resources/read needs a uri")
            }
            switch await host.authorize(client) {
            case .denied(let reason):
                return Self.error(id: id, code: -32001, message: reason)
            case .allowed(let profile):
                guard let resource = await visibleResources(profile).first(where: { $0.uri == uri }) else {
                    return Self.error(id: id, code: -32002, message: "Resource not found: \(uri)", data: .object(["uri": .string(uri)]))
                }
                return Self.result(id: id, .object(["contents": .array([resource.contents])]))
            }
        case "prompts/list":
            return Self.result(id: id, .object(["prompts": .array([])]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The host's tools, without those only a view calls when this client shows no views.
    private func visibleTools(_ profile: AgentProfile) async -> [MCPTool] {
        let tools = await host.tools(for: client, profile: profile)
        return showsViews ? tools : tools.filter { !$0.isAppOnly }
    }

    /// The host's resources, without views when this client shows none.
    private func visibleResources(_ profile: AgentProfile) async -> [MCPResource] {
        guard let host = host as? MCPResourceHost else { return [] }
        let resources = await host.resources(for: client, profile: profile)
        return showsViews ? resources : resources.filter { !$0.isView }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }
}

/// "Did you mean" for names and values an agent got slightly wrong.
public enum Suggest {
    public static func closest(to word: String, in candidates: [String]) -> String? {
        let target = word.lowercased()
        let scored = candidates.map { ($0, distance(target, $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 <= max(2, target.count / 3) ? best.0 : nil
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
