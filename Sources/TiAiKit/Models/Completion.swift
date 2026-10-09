import Foundation

/// What the app sends to `POST /api/v1/chat/completions`.
///
/// The shape is OpenAI-compatible only at the surface. The parts that are
/// Open WebUI's own and that a naive OpenAI client gets wrong:
///
/// * `parent_id` is **intent**, and its presence matters as much as its value:
///   absent means "do not manage my chat", `null` means "this is a root
///   message", a value means "branch from here". Encoding an optional field
///   with `Encodable`'s default would drop the key entirely, which is the
///   "legacy caller" path — so `encode(to:)` below writes it explicitly.
/// * `user_message` is what the server persists as the user's turn. Without it
///   the model still answers, but the transcript in the database does not
///   contain the question, and the same conversation opened in the browser is
///   missing a turn.
/// * `id` is the *assistant* message id the client generated. The server reads
///   `message_ids` from it (`main.py`: `message_ids = [{'model_id': model_id,
///   'message_id': form_data.pop('id', None)}]`), and that value becomes
///   `metadata['message_id']` — the key the event emitter needs to exist at
///   all. Omit it and the model still answers, the stream still completes, and
///   **the assistant turn is never written to the chat**: `get_event_emitter`
///   returns None without a message id, and every persistence path is gated on
///   it. The probe found this the hard way: `persisted turns: user`.
///   `assistant_message_id` is a different thing — it means "continue this
///   existing message", used by regenerate.
/// * `features` is a dict of booleans, not the list of strings older versions
///   took.
public struct CompletionRequest: Encodable, Sendable {
    public struct WireMessage: Encodable, Sendable {
        public var id: String
        public var role: String
        public var content: MessageContent
        public var parentID: String?
        public var model: String?
        public var files: [JSONValue]?

        public init(
            id: String, role: String, content: MessageContent,
            parentID: String? = nil, model: String? = nil, files: [JSONValue]? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.parentID = parentID
            self.model = model
            self.files = files
        }

        enum CodingKeys: String, CodingKey {
            case id, role, content, model, files
            case parentID = "parentId"
        }
    }

    /// How the server should read this turn's place in the conversation.
    ///
    /// Three cases because the API has three distinct instructions and the
    /// difference between two of them is whether a key is present at all:
    /// `.root` writes `"parent_id": null` (this is the first turn of a chat),
    /// `.message` writes an id (branch from here), `.unspecified` omits the
    /// key, which is the legacy "do not manage my chat" path.
    public enum ParentID: Equatable, Sendable {
        case root
        case message(String)
        case unspecified
    }

    /// Model parameters. Only non-nil values are sent, so the server's own
    /// defaults (global defaults merged with per-model overrides) win for
    /// everything the user has not explicitly touched.
    public struct Params: Encodable, Sendable {
        public var temperature: Double?
        public var topP: Double?
        public var maxTokens: Int?
        public var system: String?
        public var reasoning: String?
        public var streamDeltaChunkSize: Int?

        public init(
            temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil,
            system: String? = nil, reasoning: String? = nil, streamDeltaChunkSize: Int? = nil
        ) {
            self.temperature = temperature
            self.topP = topP
            self.maxTokens = maxTokens
            self.system = system
            self.reasoning = reasoning
            self.streamDeltaChunkSize = streamDeltaChunkSize
        }

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case maxTokens = "max_tokens"
            case system, reasoning
            case streamDeltaChunkSize = "stream_delta_chunk_size"
        }
    }

    public var model: String
    public var messages: [WireMessage]
    public var stream: Bool
    public var chatID: String?
    public var parentID: ParentID
    public var userMessage: WireMessage?
    /// The assistant message id this completion will fill in. Required for the
    /// exchange to be persisted at all — see the type comment.
    public var messageID: String?
    /// Set only when continuing or regenerating an existing assistant message.
    public var assistantMessageID: String?
    public var features: [String: Bool]
    public var files: [String]?
    public var params: Params
    public var folderID: String?

    public init(
        model: String,
        messages: [WireMessage],
        chatID: String? = nil,
        parentID: ParentID = .unspecified,
        userMessage: WireMessage? = nil,
        messageID: String? = nil,
        assistantMessageID: String? = nil,
        features: [String: Bool] = [:],
        files: [String]? = nil,
        params: Params = Params(),
        stream: Bool = true,
        folderID: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.chatID = chatID
        self.parentID = parentID
        self.userMessage = userMessage
        self.messageID = messageID
        self.assistantMessageID = assistantMessageID
        self.features = features
        self.files = files
        self.params = params
        self.folderID = folderID
    }

    enum Keys: String, CodingKey {
        case model, messages, stream, features, files, params
        case chatID = "chat_id"
        case parentID = "parent_id"
        case userMessage = "user_message"
        case messageID = "id"
        case assistantMessageID = "assistant_message_id"
        case folderID = "folder_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(stream, forKey: .stream)
        try c.encode(features, forKey: .features)
        try c.encode(params, forKey: .params)

        // Written explicitly, including the null, because "key absent" and
        // "key null" are different instructions to the server.
        switch parentID {
        case .root: try c.encodeNil(forKey: .parentID)
        case let .message(id): try c.encode(id, forKey: .parentID)
        case .unspecified: break
        }

        if let chatID { try c.encode(chatID, forKey: .chatID) }
        if let userMessage { try c.encode(userMessage, forKey: .userMessage) }
        if let messageID { try c.encode(messageID, forKey: .messageID) }
        if let assistantMessageID { try c.encode(assistantMessageID, forKey: .assistantMessageID) }
        if let files { try c.encode(files, forKey: .files) }
        if let folderID { try c.encode(folderID, forKey: .folderID) }
    }
}

/// One `data:` frame of the completion stream, before it is turned into a
/// `ChatEvent`.
///
/// `choices[].delta` carries the text; `usage` arrives on a final chunk only
/// when the model advertises the `usage` capability (the server asks for
/// `include_usage` on the app's behalf); `selected_model_id` is how an
/// arena/auto-routed model reports which model actually answered.
struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
            var reasoning: String?
            var role: String?
        }

        var index: Int?
        var delta: Delta?
        var message: Delta?
        var finishReason: String?

        enum Keys: String, CodingKey {
            case index, delta, message
            case finishReason = "finish_reason"
        }
    }

    var id: String?
    var model: String?
    var choices: [Choice]?
    var usage: TokenUsage?
    var selectedModelID: String?
    var error: JSONValue?

    enum Keys: String, CodingKey {
        case id, model, choices, usage, error
        case selectedModelID = "selected_model_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decode(String.self, forKey: .id)
        model = try? c.decode(String.self, forKey: .model)
        choices = try? c.decode([Choice].self, forKey: .choices)
        usage = try? c.decode(TokenUsage.self, forKey: .usage)
        selectedModelID = try? c.decode(String.self, forKey: .selectedModelID)
        error = try? c.decode(JSONValue.self, forKey: .error)
    }
}

/// A normalized streaming event. Everything above this line is wire format;
/// everything below is what the UI consumes.
///
/// The point of the enum is that the UI does not know or care whether an event
/// arrived over SSE, over the websocket side channel, or from a
/// post-completion `GET /chats/{id}` reconciliation — three transports with
/// three different payloads, one rendering path.
public enum ChatEvent: Equatable, Sendable {
    /// Assistant text delta.
    case delta(String)
    /// Reasoning/thinking delta, rendered in a collapsed block.
    case reasoning(String)
    /// A status line: "Searching the web", "Calling tool: homelab".
    case status(String, done: Bool)
    /// A tool call or its result, as raw output for the tool card.
    case tool(JSONValue)
    /// Sources/citations attached to the message.
    case sources([JSONValue])
    /// Which model actually answered (arena / auto-route).
    case modelSelected(String)
    /// The chat's title, generated asynchronously after the first reply.
    case title(String)
    case usage(TokenUsage)
    case done
    case failed(String)
}
