import Foundation

/// Typed client over an Open WebUI instance.
///
/// One method per endpoint, no generic "call any path" escape hatch: the
/// surface the app can use is the surface this file describes. Paths are
/// written relative to `/api/v1` via `Server.api`, except the handful of
/// routes FastAPI mounts at the root (`/health`, `/api/version`, `/api/config`).
public struct OWUIClient: Sendable {
    public let server: Server
    private let transport: any APITransport

    public init(server: Server, transport: any APITransport = URLSessionTransport()) {
        self.server = server
        self.transport = transport
    }

    public func withToken(_ token: String) -> OWUIClient {
        OWUIClient(server: server.withToken(token), transport: transport)
    }

    // MARK: - plumbing

    private func perform(
        _ method: String,
        _ url: URL,
        bodyData: Data?,
        contentType: String? = "application/json",
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !server.token.isEmpty {
            req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            req.httpBody = bodyData
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(req)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unreachable("response was not HTTP")
        }
        return (data, http)
    }

    private func request<T: Decodable>(
        _ method: String, _ path: String, query: [String: String] = [:],
        bodyData: Data? = nil, timeout: TimeInterval = 30
    ) async throws -> T {
        let (data, http) = try await perform(
            method, server.api(path, query: query), bodyData: bodyData, timeout: timeout)
        return try Self.validate(data, http, as: T.self)
    }

    /// Same, for the few routes outside the versioned router.
    private func rawRequest<T: Decodable>(_ method: String, _ path: String, timeout: TimeInterval = 15) async throws -> T {
        let data = try await perform(method, server.raw(path), bodyData: nil, timeout: timeout)
        return try Self.validate(data.0, data.1, as: T.self)
    }

    /// A response that is only a status code.
    @discardableResult
    private func expectStatus(_ method: String, _ path: String, query: [String: String] = [:], bodyData: Data? = nil) async throws -> Bool {
        let (data, http) = try await perform(method, server.api(path, query: query), bodyData: bodyData)
        switch http.statusCode {
        case 200..<300: return true
        case 401: throw APIError.unauthorized
        default: throw APIError.http(status: http.statusCode, message: Self.detail(from: data) ?? "\(http.statusCode)")
        }
    }

    private static func validate<T: Decodable>(_ data: Data, _ http: HTTPURLResponse, as type: T.Type) throws -> T {
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decoding("\(String(describing: type)): \(error.localizedDescription)")
            }
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.http(status: http.statusCode, message: detail(from: data) ?? "\(http.statusCode)")
        }
    }

    /// FastAPI puts the human-readable reason in `{"detail": ...}` — a string
    /// most of the time, an array of field errors on a validation failure.
    static func detail(from data: Data) -> String? {
        struct Envelope: Decodable { let detail: JSONValue? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch envelope.detail {
        case let .string(value)?: return value
        case .some: return String(data: data, encoding: .utf8)
        case nil: return nil
        }
    }

    // MARK: - server

    /// Unauthenticated liveness check. First thing the connect screen calls, so
    /// "wrong URL" and "server down" are distinguished before anyone types a
    /// password.
    public func health() async throws -> Bool {
        let (data, http) = try await perform("GET", server.raw("/health"), bodyData: nil, timeout: 10)
        if http.statusCode == 200 { return true }
        throw APIError.http(status: http.statusCode, message: Self.detail(from: data) ?? "unreachable")
    }

    public func version() async throws -> ServerVersion {
        try await rawRequest("GET", "/api/version")
    }

    public func config() async throws -> ServerConfig {
        try await rawRequest("GET", "/api/config")
    }

    // MARK: - auth

    public func signin(email: String, password: String) async throws -> SessionUser {
        struct Form: Encodable { let email: String; let password: String }
        let (data, http) = try await perform(
            "POST", server.api("/auths/signin"),
            bodyData: try JSONEncoder().encode(Form(email: email, password: password)))
        return try Self.validate(data, http, as: SessionUser.self)
    }

    /// Who the current token belongs to. Doubles as the token probe at launch.
    public func session() async throws -> SessionUser {
        try await request("GET", "/auths/")
    }

    public func signout() async throws {
        try await expectStatus("POST", "/auths/signout")
    }

    // MARK: - models

    /// The picker. `{"data": [...]}`.
    public func models() async throws -> [ChatModel] {
        struct Envelope: Decodable { let data: [ChatModel] }
        let envelope: Envelope = try await request("GET", "/models")
        return envelope.data
    }
    // MARK: - chats

    public func chatList() async throws -> [ChatSummary] {
        try await request("GET", "/chats/list")
    }

    public func searchChats(_ text: String) async throws -> [ChatSummary] {
        try await request("GET", "/chats/search", query: ["text": text])
    }

    public func pinnedChats() async throws -> [ChatSummary] {
        try await request("GET", "/chats/pinned")
    }

    public func archivedChats() async throws -> [ChatSummary] {
        try await request("GET", "/chats/archived")
    }

    public func chat(id: String) async throws -> ChatDetail {
        try await request("GET", "/chats/\(id)")
    }

    /// Creates an empty chat and returns it, id included.
    ///
    /// Two surprises packed in here, both found by running the probe rather
    /// than by reading docs. The body is `{"chat": {...}}` — a bare
    /// `{"title": ...}` is a 422 `"body.chat Field required"`, because the
    /// router takes the whole chat document and reads the title out of it.
    /// And the app creates chats here rather than letting the completion
    /// endpoint mint one: with no `chat_id` the server generates its own uuid
    /// and reports it over the websocket, which a REST-only client never sees.
    public func createChat(title: String = "New Chat", folderID: String? = nil) async throws -> ChatDetail {
        struct History: Encodable {
            let currentId: String?
            let messages: [String: JSONValue]
        }
        struct Skeleton: Encodable {
            let title: String
            let models: [String]
            let messages: [JSONValue]
            let tags: [String]
            let timestamp: Int
            let history: History
        }
        struct Form: Encodable {
            let chat: Skeleton
            let folder_id: String?
        }
        let form = Form(
            chat: Skeleton(
                title: title,
                models: [],
                messages: [],
                tags: [],
                timestamp: Int(Date().timeIntervalSince1970 * 1000),
                history: History(currentId: nil, messages: [:])),
            folder_id: folderID)
        return try await request("POST", "/chats/new", bodyData: try? JSONEncoder().encode(form))
    }

    /// Renames a chat. There is no `/title` route: the update endpoint patches
    /// the chat document and the server copies `chat.title` onto the column.
    public func renameChat(id: String, title: String) async throws {
        struct Patch: Encodable { let title: String }
        struct Form: Encodable { let chat: Patch }
        try await expectStatus(
            "POST", "/chats/\(id)",
            bodyData: try? JSONEncoder().encode(Form(chat: Patch(title: title))))
    }

    /// Pin and archive are *toggles* server-side — there is no per-chat
    /// unpin/unarchive — so these report the new state rather than asserting a
    /// wanted one. Firing one blindly on appear would flicker the pin on every
    /// refresh.
    public func togglePinned(id: String) async throws -> ChatDetail {
        try await request("POST", "/chats/\(id)/pin")
    }

    public func toggleArchived(id: String) async throws -> ChatDetail {
        try await request("POST", "/chats/\(id)/archive")
    }

    public func deleteChat(id: String) async throws {
        try await expectStatus("DELETE", "/chats/\(id)")
    }

    public func deleteMessage(chatID: String, messageID: String) async throws -> ChatDetail {
        try await request("DELETE", "/chats/\(chatID)/messages/\(messageID)")
    }

    // MARK: - completion

    /// Starts a completion and hands back the normalized event stream.
    ///
    /// The status check happens before a single byte is parsed: an expired JWT
    /// answers with a 401 and an HTML or JSON body, and feeding that to the SSE
    /// parser produces an empty stream that looks like a model that said
    /// nothing instead of a session that needs refreshing.
    public func stream(_ completion: CompletionRequest) async throws -> ChatEventStream {
        let url = try server.api("/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !server.token.isEmpty {
            req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        // No timeout: a long cold prefill on a local engine is normal, not hung.
        req.timeoutInterval = 0
        req.httpBody = try JSONEncoder().encode(completion)

        let (bytes, http) = try await transport.bytes(req)
        switch http.statusCode {
        case 200..<300: break
        case 401: throw APIError.unauthorized
        default:
            // The body is small in this case; reading it is what turns
            // "HTTP 400" into "model not found".
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw APIError.http(
                status: http.statusCode,
                message: Self.detail(from: body) ?? "\(http.statusCode)")
        }
        return ChatEventStream(bytes: bytes)
    }

    /// Stops a generation the user cancelled. Cancelling the local task is not
    /// enough on its own: the server keeps generating into the chat otherwise,
    /// and the message lands in the transcript half-written.
    ///
    /// Note the prefix. The task routes are mounted at the root (`/api/...`)
    /// and have **no `/api/v1` alias** — asking for the versioned one is a 405,
    /// which is what the probe reported before this was fixed.
    public func stop(chatID: String) async throws {
        let (data, http) = try await perform(
            "POST", server.raw("/api/tasks/chat/\(chatID)/stop"), bodyData: Data("{}".utf8))
        switch http.statusCode {
        case 200..<300: break
        case 401: throw APIError.unauthorized
        default: throw APIError.http(status: http.statusCode, message: Self.detail(from: data) ?? "\(http.statusCode)")
        }
    }

    // MARK: - tool calls

    /// The MCP tool servers the operator has configured.
    ///
    /// Read from the instance rather than listed in the app, so a server added
    /// in the admin UI shows up in the chat without an app release. The response
    /// is an array of configuration blobs whose shape belongs to the admin UI,
    /// not to the API contract, so it is decoded tolerantly and unreadable
    /// entries are dropped rather than failing the whole list.
    public func toolServers() async throws -> [ToolServer] {
        // The shape of this response belongs to the admin UI rather than to a
        // published contract, and it has been seen both bare and wrapped. Betting
        // on one form means the section silently never appears — which is what
        // the first attempt did — so every form that arrives is accepted.
        let json: JSONValue = try await request("GET", "/configs/tool_servers")
        let items =
            json.arrayValue
            ?? json["data"]?.arrayValue
            ?? json["toolServers"]?.arrayValue
            ?? json["servers"]?.arrayValue
            ?? []
        return items.compactMap(ToolServer.init)
    }

    /// Answers a tool call and lets the parked run continue.
    ///
    /// One route, three actions: `approve` and `reject` for a tool the model
    /// wants to run, `answer` for `ask_user`. The server refuses the wrong one —
    /// approving an `ask_user` is a 400 — so the caller picks by what the call
    /// actually is rather than by what seems reasonable.
    ///
    /// The response is not the answer. Resolving starts a *new* completion on
    /// the server, whose tokens arrive on the socket under the same assistant
    /// message id, so the caller must still be listening when this returns.
    public func resolveToolCall(
        chatID: String,
        messageID: String,
        callID: String,
        action: ToolCallAction,
        answers: JSONValue? = nil,
        timedOut: Bool = false
    ) async throws {
        var body: [String: JSONValue] = [
            "call_id": .string(callID),
            "action": .string(action.rawValue),
            "timed_out": .bool(timedOut),
        ]
        if let answers { body["answers"] = answers }
        let data = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)

        let (payload, http) = try await perform(
            "POST", server.api("/chats/\(chatID)/messages/\(messageID)/resolve"), bodyData: data)
        switch http.statusCode {
        case 200..<300: break
        case 401: throw APIError.unauthorized
        case 409:
            // Already resolved — usually a second device or a second tap.
            throw APIError.http(status: 409, message: "That answer was already given.")
        default:
            throw APIError.http(
                status: http.statusCode, message: Self.detail(from: payload) ?? "\(http.statusCode)")
        }
    }

    // MARK: - memories

    public func memories() async throws -> [Memory] {
        try await request("GET", "/memories/")
    }

    public func addMemory(_ content: String) async throws -> Memory {
        struct Form: Encodable { let content: String }
        return try await request("POST", "/memories/add", bodyData: try? JSONEncoder().encode(Form(content: content)))
    }

    public func updateMemory(id: String, content: String) async throws -> Memory {
        struct Form: Encodable { let content: String }
        return try await request("POST", "/memories/\(id)/update", bodyData: try? JSONEncoder().encode(Form(content: content)))
    }

    public func deleteMemory(id: String) async throws {
        try await expectStatus("DELETE", "/memories/\(id)")
    }

    // MARK: - prompts

    public func prompts() async throws -> [Prompt] {
        try await request("GET", "/prompts/")
    }

    // MARK: - files

    /// Uploads an attachment for RAG or vision. Multipart, because that is
    /// what the endpoint takes; the returned id goes into the message's `files`.
    public func uploadFile(data: Data, filename: String, mimeType: String) async throws -> FileRecord {
        let boundary = "----tiai-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (payload, http) = try await perform(
            "POST", server.api("/files/"),
            bodyData: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120)
        return try Self.validate(payload, http, as: FileRecord.self)
    }
}

/// A memory record (`/api/v1/memories`). `type` distinguishes facts about the
/// user from facts about the conversation.
public struct Memory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var content: String
    public var type: String
    public var path: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, content, type, path
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "user"
        path = try? c.decode(String.self, forKey: .path)
        updatedAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .updatedAt)) ?? 0))
    }
}

public struct Prompt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var content: String
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, content
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        updatedAt = Date(timeIntervalSince1970: Double((try? c.decode(Int.self, forKey: .updatedAt)) ?? 0))
    }
}

public struct FileRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var filename: String
    public var type: String?
    public var meta: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, type, meta
        case filename = "filename"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        filename = (try? c.decode(String.self, forKey: .filename)) ?? "file"
        type = try? c.decode(String.self, forKey: .type)
        meta = try? c.decode(JSONValue.self, forKey: .meta)
    }
}
