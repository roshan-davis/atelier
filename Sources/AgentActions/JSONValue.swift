import Foundation

/// A small JSON value with its own writer, so the committed catalog file comes out byte for byte
/// the same on every platform and Foundation version (keys sorted, two-space indent).
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Pretty-printed text with sorted keys and a final newline.
    public var text: String {
        var out = ""
        write(into: &out, indent: 0)
        return out + "\n"
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                out += String(Int(value))
            } else {
                out += "\(value)"
            }
        case .string(let value): out += Self.quoted(value)
        case .array(let values):
            guard !values.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, value) in values.enumerated() {
                out += String(repeating: " ", count: indent + 2)
                value.write(into: &out, indent: indent + 2)
                out += index == values.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            let keys = members.keys.sorted()
            for (index, key) in keys.enumerated() {
                out += String(repeating: " ", count: indent + 2) + Self.quoted(key) + ": "
                members[key]!.write(into: &out, indent: indent + 2)
                out += index == keys.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Codable and one-line text (MCP messages are one JSON object per line)

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON text; nil when it isn't JSON.
    public init?(parsing data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = value
    }

    /// One line, no spaces, keys sorted: the MCP wire form.
    public var compactText: String {
        var out = ""
        writeCompact(into: &out)
        return out
    }

    private func writeCompact(into out: inout String) {
        switch self {
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.writeCompact(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                out += JSONValue.string(key).text.dropLast() + ":"
                members[key]!.writeCompact(into: &out)
            }
            out += "}"
        default:
            out += text.dropLast()
        }
    }

    // Convenience readers for parsing requests.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .number(let value) where value.rounded() == value && abs(value) < 9e15: return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
