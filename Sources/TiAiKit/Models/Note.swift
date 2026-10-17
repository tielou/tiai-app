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
            .map { Self.plain(String($0)) }
            // A rule (`---`, `***`) survives the markup strip as punctuation, and
            // a row of dashes is not a preview of anything.
            .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
        guard let first = lines.first else { return "Empty note" }
        if Self.saysTheSameThing(first, title) {
            return lines.dropFirst().first ?? "Empty note"
        }
        return first
    }

    /// A line of Markdown reduced to the text a reader would actually want.
    ///
    /// A preview is a preview. `**Base:** Kos Town · **Car:** yes` and
    /// `[_open-systems.com_](http://…)` are the author's punctuation, not
    /// yours, and at one line long the markup cost more than it explained.
    static func plain(_ line: String) -> String {
        var s = line
        // Block markers off the front, links down to their text — a bare URL is
        // the whole line at this width — then the emphasis characters.
        s = s.replacing(/^[\s#>]+/, with: "")
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        for marker in ["**", "__", "~~", "*", "_", "`"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether a body line is just the title again.
    ///
    /// Compared on letters and numbers alone: an emoji in front, `_UNDERSCORES_`
    /// around it and an em dash instead of a hyphen are decoration, and the real
    /// notes have all three.
    ///
    /// The shape that matters is a body line that is a *shorter* version of the
    /// title, because Open WebUI titles a note from its first heading and then
    /// widens it — a note titled "Kos — 7 Days, Late September (Vegetarian
    /// Edition)" opens with "# Kos — 7 Days, Late September".
    ///
    /// Only in that direction. A body that starts with the title's words and
    /// carries on is content, not a restatement, and dropping it loses the only
    /// line the note has. Hence the length floor as well: a bare "Goal" under a
    /// title of "Goal setting" is not the title repeated.
    static func saysTheSameThing(_ body: String, _ title: String) -> Bool {
        func scrub(_ s: String) -> String {
            s.lowercased()
                .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        let a = scrub(body), b = scrub(title)
        guard a.count >= 10, !b.isEmpty else { return false }
        return b.hasPrefix(a)
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
