import Foundation

/// An action's parameters: a Swift type whose schema is generated from it, so the schema an agent
/// sees can't drift from the code. Give an `example` with every field set (optionals too), and
/// optional notes per field.
public protocol ActionParameters: Codable, Sendable {
    /// A value with every field set; the schema is read from how it encodes.
    static var example: Self { get }
    /// Per-field descriptions and limits, by field name.
    static var fieldNotes: [String: FieldNote] { get }
}

public extension ActionParameters {
    static var fieldNotes: [String: FieldNote] { [:] }
}

/// For actions that take no parameters.
public struct NoParameters: ActionParameters, Hashable {
    public init() {}
    public static let example = NoParameters()
}

/// A parameter with a fixed set of values: the schema lists them.
public protocol AgentEnum: CaseIterable, Codable, Sendable, RawRepresentable where RawValue == String {
    var agentChoices: [String] { get }
}

public extension AgentEnum {
    var agentChoices: [String] { Self.allCases.map(\.rawValue) }
}

public struct FieldNote: Hashable, Sendable {
    public var summary: String
    public var minimum: Double?
    public var maximum: Double?

    public init(_ summary: String, minimum: Double? = nil, maximum: Double? = nil) {
        self.summary = summary
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// The generated description of a parameter type.
public struct ParameterSchema: Hashable, Sendable {
    public indirect enum FieldType: Hashable, Sendable {
        case boolean, integer, number, string
        case choice([String])
        case list(FieldType)
    }

    public struct Field: Hashable, Sendable {
        public var name: String
        public var type: FieldType
        public var required: Bool
        public var note: FieldNote?
    }

    /// In the order the type encodes them.
    public var fields: [Field]
    /// Why the schema couldn't be read fully (unsupported shapes, empty example lists).
    public var problems: [String]

    public static let empty = ParameterSchema(fields: [], problems: [])

    /// Reads the schema from how `P.example` encodes.
    public static func of<P: ActionParameters>(_ type: P.Type) -> ParameterSchema {
        let recorder = SchemaRecorder()
        do {
            try P.example.encode(to: SchemaEncoder(recorder: recorder, path: []))
        } catch {
            recorder.problems.append("\(P.self): \(error)")
        }
        let notes = P.fieldNotes
        var fields = recorder.fields
        for index in fields.indices { fields[index].note = notes[fields[index].name] }
        var problems = recorder.problems
        for name in notes.keys.sorted() where !fields.contains(where: { $0.name == name }) {
            problems.append("\(P.self): a note names \"\(name)\", which is not a field")
        }
        return ParameterSchema(fields: fields, problems: problems)
    }

    /// JSON Schema for the parameters object (draft 2020-12 subset).
    public var json: JSONValue {
        var properties: [String: JSONValue] = [:]
        for field in fields {
            var schema = Self.json(for: field.type)
            if case .object(var members) = schema, let note = field.note {
                if !note.summary.isEmpty { members["description"] = .string(note.summary) }
                if let minimum = note.minimum { members["minimum"] = .number(minimum) }
                if let maximum = note.maximum { members["maximum"] = .number(maximum) }
                schema = .object(members)
            }
            properties[field.name] = schema
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(fields.filter(\.required).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }

    private static func json(for type: FieldType) -> JSONValue {
        switch type {
        case .boolean: return .object(["type": .string("boolean")])
        case .integer: return .object(["type": .string("integer")])
        case .number: return .object(["type": .string("number")])
        case .string: return .object(["type": .string("string")])
        case .choice(let values): return .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
        case .list(let element): return .object(["type": .string("array"), "items": json(for: element)])
        }
    }
}

// MARK: - Reading a schema from an example value

private final class SchemaRecorder {
    var fields: [ParameterSchema.Field] = []
    var problems: [String] = []

    func add(_ name: String, _ type: ParameterSchema.FieldType?, required: Bool) {
        guard let type else {
            problems.append("\(name): can't read its type (give the example a value, and lists one element)")
            return
        }
        if let index = fields.firstIndex(where: { $0.name == name }) {
            fields[index].type = type
            fields[index].required = fields[index].required && required
        } else {
            fields.append(.init(name: name, type: type, required: required, note: nil))
        }
    }
}

/// Reads the top-level keyed container: one field per key.
private struct SchemaEncoder: Encoder {
    let recorder: SchemaRecorder
    let path: [CodingKey]
    var codingPath: [CodingKey] { path }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(FieldContainer<Key>(recorder: recorder))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        recorder.problems.append("Parameters must be a struct with named fields, not a list")
        return ValueProbe().unkeyedContainer()
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        recorder.problems.append("Parameters must be a struct with named fields, not a single value")
        return ValueProbe().singleValueContainer()
    }
}

private struct FieldContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let recorder: SchemaRecorder
    var codingPath: [CodingKey] { [] }

    mutating func encodeNil(forKey key: Key) throws { recorder.add(key.stringValue, nil, required: false) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { recorder.add(key.stringValue, .boolean, required: true) }
    mutating func encode(_ value: String, forKey key: Key) throws { recorder.add(key.stringValue, .string, required: true) }
    mutating func encode(_ value: Double, forKey key: Key) throws { recorder.add(key.stringValue, .number, required: true) }
    mutating func encode(_ value: Float, forKey key: Key) throws { recorder.add(key.stringValue, .number, required: true) }
    mutating func encode(_ value: Int, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { recorder.add(key.stringValue, .integer, required: true) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        recorder.add(key.stringValue, ValueProbe.type(of: value), required: true)
    }

    // Optional fields: synthesized Codable writes them with encodeIfPresent.
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { optional(value, key) }
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws { optional(value, key) }

    private func optional<T: Encodable>(_ value: T?, _ key: Key) {
        recorder.add(key.stringValue, value.flatMap { ValueProbe.type(of: $0) }, required: false)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                         forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        recorder.problems.append("\(key.stringValue): nested objects are not supported")
        return ValueProbe().container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        recorder.problems.append("\(key.stringValue): write lists as Swift arrays")
        return ValueProbe().unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder { SchemaEncoder(recorder: recorder, path: []) }
    mutating func superEncoder(forKey key: Key) -> Encoder { SchemaEncoder(recorder: recorder, path: []) }
}

/// Finds the type of one field's value: a plain value, a choice, or a list of either.
private final class ValueProbe: Encoder {
    var found: ParameterSchema.FieldType?
    var element: ParameterSchema.FieldType?
    var isList = false
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func type<T: Encodable>(of value: T) -> ParameterSchema.FieldType? {
        if let choice = value as? any AgentEnum { return .choice(choice.agentChoices) }
        let probe = ValueProbe()
        do { try value.encode(to: probe) } catch { return nil }
        if probe.isList { return probe.element.map { .list($0) } }
        return probe.found
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(Ignored<Key>())
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        isList = true
        return ListProbe(owner: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { SingleProbe(owner: self) }

    private struct Ignored<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var codingPath: [CodingKey] { [] }
        mutating func encodeNil(forKey key: Key) throws {}
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {}
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                             forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Ignored<NestedKey>())
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { ListProbe(owner: ValueProbe()) }
        mutating func superEncoder() -> Encoder { ValueProbe() }
        mutating func superEncoder(forKey key: Key) -> Encoder { ValueProbe() }
    }

    private struct SingleProbe: SingleValueEncodingContainer {
        let owner: ValueProbe
        var codingPath: [CodingKey] { [] }
        mutating func encodeNil() throws {}
        mutating func encode(_ value: Bool) throws { owner.found = .boolean }
        mutating func encode(_ value: String) throws { owner.found = .string }
        mutating func encode(_ value: Double) throws { owner.found = .number }
        mutating func encode(_ value: Float) throws { owner.found = .number }
        mutating func encode(_ value: Int) throws { owner.found = .integer }
        mutating func encode(_ value: Int8) throws { owner.found = .integer }
        mutating func encode(_ value: Int16) throws { owner.found = .integer }
        mutating func encode(_ value: Int32) throws { owner.found = .integer }
        mutating func encode(_ value: Int64) throws { owner.found = .integer }
        mutating func encode(_ value: UInt) throws { owner.found = .integer }
        mutating func encode(_ value: UInt8) throws { owner.found = .integer }
        mutating func encode(_ value: UInt16) throws { owner.found = .integer }
        mutating func encode(_ value: UInt32) throws { owner.found = .integer }
        mutating func encode(_ value: UInt64) throws { owner.found = .integer }
        mutating func encode<T: Encodable>(_ value: T) throws { owner.found = ValueProbe.type(of: value) }
    }

    private struct ListProbe: UnkeyedEncodingContainer {
        let owner: ValueProbe
        var codingPath: [CodingKey] { [] }
        var count = 0
        mutating func encodeNil() throws { count += 1 }
        mutating func encode<T: Encodable>(_ value: T) throws {
            count += 1
            if owner.element == nil { owner.element = ValueProbe.type(of: value) }
        }
        mutating func encode(_ value: Bool) throws { try encode(Box(value)) }
        mutating func encode(_ value: String) throws { try encode(Box(value)) }
        mutating func encode(_ value: Double) throws { try encode(Box(value)) }
        mutating func encode(_ value: Float) throws { try encode(Box(value)) }
        mutating func encode(_ value: Int) throws { try encode(Box(value)) }
        mutating func encode(_ value: Int8) throws { try encode(Box(value)) }
        mutating func encode(_ value: Int16) throws { try encode(Box(value)) }
        mutating func encode(_ value: Int32) throws { try encode(Box(value)) }
        mutating func encode(_ value: Int64) throws { try encode(Box(value)) }
        mutating func encode(_ value: UInt) throws { try encode(Box(value)) }
        mutating func encode(_ value: UInt8) throws { try encode(Box(value)) }
        mutating func encode(_ value: UInt16) throws { try encode(Box(value)) }
        mutating func encode(_ value: UInt32) throws { try encode(Box(value)) }
        mutating func encode(_ value: UInt64) throws { try encode(Box(value)) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            count += 1
            return KeyedEncodingContainer(Ignored<NestedKey>())
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            count += 1
            return ListProbe(owner: ValueProbe())
        }
        mutating func superEncoder() -> Encoder { ValueProbe() }
    }

    /// Sends a primitive list element through the generic path, so its type is read once.
    private struct Box<T: Encodable>: Encodable {
        let value: T
        init(_ value: T) { self.value = value }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}
