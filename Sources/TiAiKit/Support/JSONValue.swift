import Foundation

/// A JSON value we do not have a schema for.
///
/// Open WebUI is deliberately open in several places — a model's
/// `meta.capabilities`, a tool's `output`, `content` blocks whose type list
/// grows with every release. Typing those as `Any` would cost `Sendable` on
/// every model that contains one, so open content decodes into this instead.
///
/// It is also the escape hatch that keeps a new server release from breaking
/// the app: unknown keys land here and are simply not rendered, rather than
/// failing a whole response's decode.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Object member lookup, so nested payloads read top to bottom instead of
    /// turning into a chain of `?.objectValue?`.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public var firstArrayElement: JSONValue? { arrayValue?.first }

    /// Compact JSON, for showing a tool call's arguments to a human.
    ///
    /// Nil only if re-encoding fails, which for a value that was just decoded
    /// means the two encoders disagree — worth showing as nothing rather than
    /// crashing a transcript over.
    public var jsonText: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): Self.numberFormatter.string(from: NSNumber(value: value))
        case let .bool(value): value ? "true" : "false"
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        }
    }
}

/// The decoding rule this package follows, stated once instead of at every
/// call site: a field the app merely *displays* is `decodeIfPresent` plus a
/// default, because a server that stops sending it is a cosmetic problem. A
/// field the app cannot function without is decoded strictly, because a server
/// that stops sending it is a contract violation and should be loud.
///
/// `ModelDecodingTests` pins both halves of that line.
