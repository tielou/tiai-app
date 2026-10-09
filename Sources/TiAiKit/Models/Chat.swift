import Foundation

/// A row in the chat list (`GET /api/v1/chats/list`, `/search`, `/pinned`, …).
public struct ChatSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var createdAt: Date
    public var lastReadAt: Date?
    public var snippet: String?
    public var pinned: Bool
    public var archived: Bool
    public var folderID: String?

    enum Keys: String, CodingKey {
        case id, title, snippet, pinned, archived
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case lastReadAt = "last_read_at"
        case folderID = "folder_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        updatedAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .updatedAt)) ?? 0))
        createdAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .createdAt)) ?? 0))
        lastReadAt = (try? c.decode(Int.self, forKey: .lastReadAt)).map { Date(timeIntervalSince1970: Double($0)) }
        snippet = try? c.decode(String.self, forKey: .snippet)
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        folderID = try? c.decode(String.self, forKey: .folderID)
    }
}

/// A full conversation (`GET /api/v1/chats/{id}`).
///
/// `history` is the interesting part and it is a *tree*, not a list: every
/// message carries `parentId` and `childrenIds`, and `currentId` marks the
/// branch being read. Edit-and-resend and "regenerate" create siblings rather
/// than replacing anything, which is why the web UI can show "2/3" under a
/// reply. Flattening that to an array on decode throws the feature away, so
/// `ChatMessage.tree(from:currentID:)` walks it instead.
public struct ChatDetail: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var createdAt: Date
    public var pinned: Bool
    public var archived: Bool
    public var folderID: String?
    public var summary: String?
    public var currentMessageID: String?
    public var models: [String]
    public var tags: [String]
    public var messages: [String: ChatMessage]
    public var currentID: String?

    enum Keys: String, CodingKey {
        case id, title, chat, meta, pinned, archived, summary, tags
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case folderID = "folder_id"
        case currentMessageID = "current_message_id"
    }

    enum ChatKeys: String, CodingKey {
        case models, tags, history, title
        case currentId
    }

    enum HistoryKeys: String, CodingKey {
        case messages
        case currentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        updatedAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .updatedAt)) ?? 0))
        createdAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .createdAt)) ?? 0))
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        folderID = try? c.decode(String.self, forKey: .folderID)
        summary = try? c.decode(String.self, forKey: .summary)
        currentMessageID = try? c.decode(String.self, forKey: .currentMessageID)

        models = []
        tags = []
        messages = [:]
        currentID = nil

        // `chat` is a JSON blob the server treats as opaque; a server that
        // stores it as a string (older installs kept it stringified) must not
        // take the whole chat down with it.
        if let chat = try? c.nestedContainer(keyedBy: ChatKeys.self, forKey: .chat) {
            models = (try? chat.decode([String].self, forKey: .models)) ?? []
            tags = (try? chat.decode([String].self, forKey: .tags)) ?? []
            if let history = try? chat.nestedContainer(keyedBy: HistoryKeys.self, forKey: .history) {
                currentID = try? history.decode(String.self, forKey: .currentId)
                messages = (try? history.decode([String: ChatMessage].self, forKey: .messages)) ?? [:]
            }
        }
        if currentID == nil { currentID = currentMessageID }
    }

    /// The branch the server considers current, oldest first.
    public var thread: [ChatMessage] {
        ChatMessage.tree(from: messages, currentID: currentID ?? currentMessageID)
    }
}

/// One message in a conversation.
///
/// Keys are camelCase here (unlike the rest of the API) because this blob is
/// the Svelte client's own document shape, mirrored by the server's
/// `chat_message` table — see `DB_TO_JSON_KEY_MAP` in
/// `open_webui/models/chat_messages.py`, which is where `model_id` → `model`
/// and `created_at` → `timestamp` come from.
public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: String
    public var content: MessageContent
    public var parentID: String?
    public var childrenIDs: [String]
    public var model: String?
    public var done: Bool
    public var error: String?
    public var timestamp: Date?
    public var sources: [JSONValue]?
    public var files: [JSONValue]?
    public var embeds: [JSONValue]?
    public var statusHistory: [StatusEntry]
    public var usage: TokenUsage?
    public var meta: JSONValue?

    public var isUser: Bool { role == "user" }
    public var isAssistant: Bool { role == "assistant" }

    enum Keys: String, CodingKey {
        case id, role, content, model, done, error, sources, files, embeds, meta, usage, timestamp
        case parentID = "parentId"
        case childrenIDs = "childrenIds"
        case statusHistory = "statusHistory"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        role = (try? c.decode(String.self, forKey: .role)) ?? "user"
        content = (try? c.decode(MessageContent.self, forKey: .content)) ?? .text("")
        parentID = try? c.decode(String.self, forKey: .parentID)
        childrenIDs = (try? c.decode([String].self, forKey: .childrenIDs)) ?? []
        model = try? c.decode(String.self, forKey: .model)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? true
        // `error` is `{"content": "..."}` or a bare string depending on which
        // code path wrote it.
        error =
            if let text = try? c.decode(String.self, forKey: .error) { text }
        else if let object = try? c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error) {
            try? object.decode(String.self, forKey: .content)
        } else { nil }
        timestamp = (try? c.decode(Double.self, forKey: .timestamp)).map {
            Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0)
        }
        sources = try? c.decode([JSONValue].self, forKey: .sources)
        files = try? c.decode([JSONValue].self, forKey: .files)
        embeds = try? c.decode([JSONValue].self, forKey: .embeds)
        statusHistory = (try? c.decode([StatusEntry].self, forKey: .statusHistory)) ?? []
        usage = try? c.decode(TokenUsage.self, forKey: .usage)
        meta = try? c.decode(JSONValue.self, forKey: .meta)
    }

    enum ErrorKeys: String, CodingKey { case content }

    /// Walk `parentId` from `currentID` to the root, then reverse.
    ///
    /// Falls back to chronological order when the tree is unusable (a chat
    /// whose currentId points at a deleted message), because a list that
    /// renders something is recoverable and an empty screen is not.
    public static func tree(from messages: [String: ChatMessage], currentID: String?) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        var path: [ChatMessage] = []
        var seen: Set<String> = []
        var cursor = currentID ?? messages.values.map { ($0.timestamp ?? .distantPast, $0) }.max { $0.0 < $1.0 }?.1.id
        while let id = cursor, let message = messages[id], !seen.contains(id) {
            seen.insert(id)
            path.append(message)
            cursor = message.parentID
        }
        if path.isEmpty {
            return messages.values.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        }
        return path.reversed()
    }
}

/// `content` is a plain string most of the time and an array of typed blocks
/// when there is multimodal content in play. Both are legal at all times, so
/// both must decode.
public enum MessageContent: Codable, Equatable, Sendable {
    case text(String)
    case blocks([JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([JSONValue].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }

    /// The text to render. Block content contributes its `text` fields, which
    /// is what the transcript needs; the non-text blocks are reachable through
    /// `blocks` for whoever renders attachments.
    public var text: String {
        switch self {
        case let .text(value): value
        case let .blocks(values):
            values.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        }
    }

    public var blocks: [JSONValue]? {
        if case let .blocks(values) = self { values } else { nil }
    }

    public init(text: String) {
        self = .text(text)
    }

    /// Encodes back the way it arrived: a bare string, or the block array.
    /// The synthesized implementation would wrap it in `{"text": ...}`, which
    /// the server accepts and then renders as nothing.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .blocks(values): try container.encode(values)
        }
    }
}

/// A step in the "searching the web / calling tool X" trail. Persisted by the
/// server onto the message, which is what makes it recoverable after the fact
/// even though it is *emitted* over the websocket and not over the SSE stream.
public struct StatusEntry: Codable, Equatable, Sendable {
    public var status: String
    public var done: Bool
    public var createdAt: Date?

    enum Keys: String, CodingKey {
        case status, done
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)).map {
            Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0)
        }
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    /// Some gateways report time-to-first-token here; it is the number that
    /// explains "why is it silent", so it is worth surfacing in diagnostics.
    public var completionTokensPerSecond: Double?

    public init(
        promptTokens: Int?, completionTokens: Int?, totalTokens: Int?,
        completionTokensPerSecond: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.completionTokensPerSecond = completionTokensPerSecond
    }

    enum Keys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case completionTokensPerSecond = "completion_tokens_per_second"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        promptTokens = try? c.decode(Int.self, forKey: .promptTokens)
        completionTokens = try? c.decode(Int.self, forKey: .completionTokens)
        totalTokens = try? c.decode(Int.self, forKey: .totalTokens)
        completionTokensPerSecond = try? c.decode(Double.self, forKey: .completionTokensPerSecond)
    }
}
