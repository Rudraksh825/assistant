import Foundation

/// Untyped JSON for `Record<string, unknown>` payloads and PATCH bodies.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        // Whole numbers go out as integers so epoch-ms and ids never become 1.7e12.
        case .number(let v): if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var double: Double? { if case .number(let v) = self { v } else { nil } }
    public var int: Int? { double.map { Int($0) } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var isNull: Bool { self == .null }

    public static func ms(_ date: Date?) -> JSONValue {
        date.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null
    }

    /// Returns a copy with `value` set at a dotted path, creating objects on the way ("ui.haptics").
    public func setting(_ path: String, to value: JSONValue) -> JSONValue {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return value }
        let head = parts.removeFirst()
        var o = object ?? [:]
        o[head] = (o[head] ?? .null).setting(parts.joined(separator: "."), to: value)
        return .object(o)
    }

    /// Compact single-line or pretty JSON text, for previews of tool inputs.
    public func text(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
}
