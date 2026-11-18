import AgentActions
import Foundation

/// An MCP prompt as listed to clients (`prompts/list`). Atelier lists the person's skills this
/// way (BACKLOG SL-002c, studio-shared-lib Skills PRD "How agents get skills"), so a chat app
/// that shows prompts (Docent, under `/`) offers them with no change on its side.
public struct MCPPrompt: Sendable, Hashable {
    /// One argument the client asks the person for before it gets the prompt.
    public struct Argument: Sendable, Hashable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]

    public init(name: String, title: String, description: String, arguments: [Argument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    public var json: JSONValue {
        var members: [String: JSONValue] = ["name": .string(name), "title": .string(title), "description": .string(description)]
        if !arguments.isEmpty {
            members["arguments"] = .array(arguments.map {
                .object(["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)])
            })
        }
        return .object(members)
    }
}

/// A host that offers prompts. `prompt` returns the text of the one user message `prompts/get`
/// answers with, or nil when there is no prompt of that name for this client.
public protocol MCPPromptHost: MCPHost {
    func prompts(for client: AgentClient, profile: AgentProfile) async -> [MCPPrompt]
    func prompt(_ name: String, arguments: [String: String], client: AgentClient, profile: AgentProfile) async -> String?
}

extension MCPSession {
    /// `prompts/get`'s result: one user message with the text.
    static func promptResult(description: String, text: String) -> JSONValue {
        .object([
            "description": .string(description),
            "messages": .array([.object(["role": .string("user"),
                                         "content": .object(["type": .string("text"), "text": .string(text)])])]),
        ])
    }

    /// The arguments a client sent to `prompts/get`, as strings (MCP sends them as strings; a
    /// number or flag some clients send is written out).
    static func promptArguments(_ params: [String: JSONValue]) -> [String: String] {
        var arguments: [String: String] = [:]
        for (key, value) in params["arguments"]?.objectValue ?? [:] {
            switch value {
            case .string(let text): arguments[key] = text
            case .null: continue
            default: arguments[key] = value.compactText
            }
        }
        return arguments
    }
}
