import AgentActions
import Foundation

/// Checks an agent's parameters against an action's generated schema before anything runs, and
/// says what is wrong in words a model can fix: an unknown field with "did you mean", a missing
/// one, a wrong type, a value outside its range, or a choice that isn't one of the listed values.
public enum ParameterCheck {
    /// Every problem with `arguments`, or none.
    public static func problems(_ arguments: [String: JSONValue], against schema: ParameterSchema) -> [String] {
        var problems: [String] = []
        let names = schema.fields.map(\.name)
        for key in arguments.keys.sorted() where !names.contains(key) {
            let hint = Suggest.closest(to: key, in: names).map { " Did you mean \"\($0)\"?" } ?? ""
            let known = names.isEmpty ? " This takes no parameters." : " Parameters: \(names.joined(separator: ", "))."
            problems.append("Unknown parameter \"\(key)\".\(hint.isEmpty ? known : hint)")
        }
        for field in schema.fields {
            guard let value = arguments[field.name], value != .null else {
                if field.required { problems.append("\"\(field.name)\" is required.") }
                continue
            }
            if let problem = check(value, field.type, name: field.name, note: field.note) { problems.append(problem) }
        }
        return problems
    }

    /// The arguments as JSON data for the parameter type's decoder, or the problems.
    public static func decodable(_ arguments: [String: JSONValue], against schema: ParameterSchema) -> Result<Data, Problems> {
        let found = problems(arguments, against: schema)
        guard found.isEmpty else { return .failure(Problems(messages: found)) }
        // Nulls mean "not given": the decoders treat a missing optional the same way.
        let cleaned = arguments.filter { $0.value != .null }
        return .success(Data(JSONValue.object(cleaned).compactText.utf8))
    }

    /// Decodes `P` from an agent's arguments, after checking them.
    public static func decode<P: ActionParameters>(_ type: P.Type, from arguments: [String: JSONValue]) -> Result<P, Problems> {
        switch decodable(arguments, against: .of(P.self)) {
        case .failure(let problems):
            return .failure(problems)
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(P.self, from: data))
            } catch {
                return .failure(Problems(messages: ["The parameters don't fit: \(error)"]))
            }
        }
    }

    public struct Problems: Error, Hashable, Sendable {
        public var messages: [String]
        public var text: String { messages.joined(separator: " ") }

        public init(messages: [String]) { self.messages = messages }
    }

    private static func check(_ value: JSONValue, _ type: ParameterSchema.FieldType, name: String, note: FieldNote?) -> String? {
        switch type {
        case .boolean:
            guard case .bool = value else { return "\"\(name)\" must be true or false." }
        case .integer:
            guard let number = integer(value) else { return "\"\(name)\" must be a whole number." }
            if let problem = range(Double(number), name: name, note: note) { return problem }
        case .number:
            guard let number = value.doubleValue else { return "\"\(name)\" must be a number." }
            if let problem = range(number, name: name, note: note) { return problem }
        case .string:
            guard case .string = value else { return "\"\(name)\" must be text." }
        case .choice(let choices):
            guard case .string(let text) = value else {
                return "\"\(name)\" must be one of: \(choices.joined(separator: ", "))."
            }
            guard choices.contains(text) else {
                let hint = Suggest.closest(to: text, in: choices).map { " Did you mean \"\($0)\"?" } ?? ""
                return "\"\(name)\" can't be \"\(text)\". Use one of: \(choices.joined(separator: ", ")).\(hint)"
            }
        case .list(let element):
            guard case .array(let values) = value else { return "\"\(name)\" must be a list." }
            for (index, item) in values.enumerated() {
                if let problem = check(item, element, name: "\(name)[\(index)]", note: nil) { return problem }
            }
        }
        return nil
    }

    private static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let number): return number
        case .number(let number) where number.rounded() == number && abs(number) < 9e15: return Int(number)
        default: return nil
        }
    }

    private static func range(_ number: Double, name: String, note: FieldNote?) -> String? {
        if let minimum = note?.minimum, number < minimum { return "\"\(name)\" must be at least \(format(minimum))." }
        if let maximum = note?.maximum, number > maximum { return "\"\(name)\" must be at most \(format(maximum))." }
        return nil
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
