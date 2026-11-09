import Foundation

/// A JSON value, for MCP messages and tool schemas.
enum Value: Codable, Sendable, Equatable,
            ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
            ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: Value...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, Value)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([Value].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: Value].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var objectValue: [String: Value]? { if case .object(let value) = self { value } else { nil } }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value == value.rounded(): Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }
}

/// An MCP tool definition.
struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: Value

    var json: Value {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
    }
}

/// The result of an MCP tools/call.
enum CallTool {
    struct Result: Sendable {
        enum Content: Sendable {
            case text(String)
        }
        let content: [Content]
        let isError: Bool

        var json: Value {
            .object([
                "content": .array(content.map { item in
                    switch item {
                    case .text(let text): .object(["type": "text", "text": .string(text)])
                    }
                }),
                "isError": .bool(isError),
            ])
        }
    }
}
