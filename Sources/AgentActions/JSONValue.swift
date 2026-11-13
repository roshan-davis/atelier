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
