import Foundation

/// Shared coders: camelCase keys, timestamps as epoch milliseconds.
public enum BrainJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return e
    }()

    /// Called with a description of every array element that failed to decode and was skipped.
    nonisolated(unsafe) public static var onDroppedElement: (@Sendable (String) -> Void)?
}

/// String enums that decode unknown raw values to `.unknown` instead of throwing.
public protocol LenientEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    static var unknown: Self { get }
}

extension LenientEnum {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct LossyArray<T: Decodable>: Decodable {
    var values: [T] = []

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            do { values.append(try c.decode(T.self)) } catch {
                _ = try? c.decode(JSONValue.self)
                BrainJSON.onDroppedElement?("\(T.self): \(error)")
            }
        }
    }
}

// The synthesized `init(from:)` of every model in this module resolves to these overloads, which is
// what makes arrays lossy (one bad element is skipped, not the list) and absent collections/scalars default.
extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ type: [T].Type, forKey key: Key) throws -> [T] {
        try decodeIfPresent(LossyArray<T>.self, forKey: key)?.values ?? []
    }

    func decode<T: Decodable>(_ type: [String: T].Type, forKey key: Key) throws -> [String: T] {
        try decodeIfPresent([String: T].self, forKey: key) ?? [:]
    }

    func decode<T: LenientEnum>(_ type: T.Type, forKey key: Key) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? .unknown
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeIfPresent(Bool.self, forKey: key) ?? false
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeIfPresent(String.self, forKey: key) ?? ""
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeIfPresent(Int.self, forKey: key) ?? 0
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeIfPresent(Double.self, forKey: key) ?? 0
    }
}
