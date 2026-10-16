import Foundation

/// A note (`/api/v1/notes`).
///
/// Notes are a separate object from chats in Open WebUI, with their own list,
/// editor and sharing. The body lives inside `data` as `content.md` — markdown,
/// which is what the web UI shows — alongside a rich-editor document this client
/// does not touch. Only the keys a save actually sends are merged server-side, so
/// leaving the editor document out of the payload leaves it alone rather than
/// clearing it.
public struct Note: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var data: JSONValue?
    public var isPinned: Bool
    public var writeAccess: Bool
    public var updatedAt: Date
    public var createdAt: Date

    enum Keys: String, CodingKey {
        case id, title, data
        case isPinned = "is_pinned"
        case pinned
        case writeAccess = "write_access"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        data = try? c.decode(JSONValue.self, forKey: .data)
        // The list calls it `is_pinned`, the record calls it `pinned`.
        isPinned = (try? c.decode(Bool.self, forKey: .isPinned))
            ?? (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        writeAccess = (try? c.decode(Bool.self, forKey: .writeAccess)) ?? true
        updatedAt = Self.date(c, .updatedAt) ?? .now
        createdAt = Self.date(c, .createdAt) ?? .now
    }

    public init(
        id: String, title: String, data: JSONValue? = nil, isPinned: Bool = false,
        writeAccess: Bool = true, updatedAt: Date = .now, createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.data = data
        self.isPinned = isPinned
        self.writeAccess = writeAccess
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(data, forKey: .data)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(createdAt, forKey: .createdAt)
    }

    /// Timestamps arrive with no stated unit, and it is not seconds.
    ///
    /// The notes table stores what the database hands back, which came out as
    /// `1790407934893532341` — nanoseconds. Read as seconds that prints
    /// "December 5828963" in the list, so the unit is inferred from magnitude
    /// rather than assumed.
    private static func date(_ c: KeyedDecodingContainer<Keys>, _ key: Keys) -> Date? {
        guard let raw = try? c.decode(Double.self, forKey: key), raw > 0 else { return nil }
        let seconds: Double
        switch raw {
        case ..<1e11: seconds = raw                // seconds
        case ..<1e14: seconds = raw / 1e3          // milliseconds
        case ..<1e17: seconds = raw / 1e6          // microseconds
        default: seconds = raw / 1e9               // nanoseconds
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The note's markdown, or nothing when the shape is not recognised.
    ///
    /// Read defensively on purpose: a note whose body cannot be found should show
    /// its title and an empty body rather than fail the whole list.
    public var markdown: String {
        data?["content"]?["md"]?.stringValue ?? ""
    }

    /// A one-line preview for the list: the first line of the body that says
    /// something the title did not already say.
    ///
    /// Notes usually open by repeating their own title as a heading, which made
    /// every row read the same thing twice.
    public var preview: String {
        let lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "***" && $0 != "---" }
        let heading = title.trimmingCharacters(in: .whitespaces)
        if let first = lines.first, first == heading {
            return lines.dropFirst().first ?? "Empty note"
        }
        return lines.first ?? "Empty note"
    }

    /// The payload for a save: only `content.md`, so the rich-editor document the
    /// web UI keeps alongside it is left as it is.
    static func payload(title: String, markdown: String) -> Data {
        let body: [String: JSONValue] = [
            "title": .string(title),
            "data": .object(["content": .object(["md": .string(markdown)])]),
        ]
        return (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
    }
}
