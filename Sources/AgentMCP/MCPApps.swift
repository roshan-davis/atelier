import AgentActions
import Foundation

/// MCP Apps (the `io.modelcontextprotocol/ui` extension, stable 2026-01-26): a tool can name an
/// HTML view that a chat app which supports it (Docent) shows in place of the tool's text, such
/// as Atelier's photo carousel. Clients that don't declare the extension never see the view
/// links, the views or the tools only a view may call, so nothing changes for them.
public enum MCPApps {
    public static let extensionID = "io.modelcontextprotocol/ui"
    public static let mimeType = "text/html;profile=mcp-app"

    /// Whether `initialize`'s client capabilities declare the extension with the HTML view type.
    public static func clientSupports(_ capabilities: JSONValue?) -> Bool {
        guard let declared = capabilities?["extensions"]?[extensionID] else { return false }
        guard let types = declared["mimeTypes"]?.arrayValue else { return false }
        return types.contains(.string(mimeType))
    }
}

/// A tool's link to its view.
public struct MCPToolUI: Sendable, Hashable {
    /// Who may call the tool: the model, the view, or both (the default).
    public enum Visibility: String, Sendable, Hashable { case model, app }

    public var resourceURI: String?
    public var visibility: [Visibility]

    public init(resourceURI: String? = nil, visibility: [Visibility] = [.model, .app]) {
        self.resourceURI = resourceURI
        self.visibility = visibility
    }

    /// A tool only views call (thumbnails for a carousel): hidden from the model.
    public static let appOnly = MCPToolUI(visibility: [.app])

    var json: JSONValue {
        var members: [String: JSONValue] = ["visibility": .array(visibility.map { .string($0.rawValue) })]
        if let resourceURI { members["resourceUri"] = .string(resourceURI) }
        return .object(members)
    }
}

/// A resource the server offers, such as a view's HTML.
public struct MCPResource: Sendable, Hashable {
    public var uri: String
    public var name: String
    public var title: String
    public var description: String
    public var mimeType: String
    public var text: String
    /// `_meta.ui` of a view: `csp`, `prefersBorder`.
    public var ui: JSONValue?

    public init(uri: String, name: String, title: String, description: String, mimeType: String, text: String,
                ui: JSONValue? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.text = text
        self.ui = ui
    }

    public var isView: Bool { mimeType == MCPApps.mimeType }

    var listing: JSONValue {
        var members: [String: JSONValue] = [
            "uri": .string(uri), "name": .string(name), "title": .string(title),
            "description": .string(description), "mimeType": .string(mimeType),
        ]
        if let ui { members["_meta"] = .object(["ui": ui]) }
        return .object(members)
    }

    var contents: JSONValue {
        var members: [String: JSONValue] = ["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]
        if let ui { members["_meta"] = .object(["ui": ui]) }
        return .object(members)
    }
}

/// A host with resources (views). Asked after `authorize`, like tools.
public protocol MCPResourceHost: MCPHost {
    func resources(for client: AgentClient, profile: AgentProfile) async -> [MCPResource]
}
