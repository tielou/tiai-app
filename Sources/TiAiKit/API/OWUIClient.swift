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
            #if DEBUG
            // The request side of the same trick. A screenshot cannot show
            // whether a field made it onto the wire, and "the photo was sent but
            // the model never saw it" is exactly the kind of claim worth
            // checking instead of reasoning about.
            Self.dump(url: url, method: "REQ_\(method)", data: bodyData)
            #endif
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
        #if DEBUG
        Self.dump(url: url, method: method, data: data)
        #endif
        return (data, http)
    }

    #if DEBUG
    /// DEBUG-only: writes each response body to a directory so the real payload
    /// can be read back without anyone pasting a token into a terminal.
    ///
    /// Set it with `xcrun simctl launch --setenv TIAI_DEBUG_DUMP=/tmp/tiai-dump`;
    /// the path lands inside the device container, which is readable from the
    /// Mac. This exists because guessing at a server's payload from a screenshot
    /// is how wrong assumptions get shipped — see the notes on `sources`.
    static func dump(url: URL, method: String, data: Data) {
        guard let dir = ProcessInfo.processInfo.environment["TIAI_DEBUG_DUMP"] else { return }
        let name = "\(method)_" + url.path.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".json"))
    }

    /// DEBUG-only: appends a line to the dump directory.
    ///
    /// stdout is not reliably readable from a launched simulator process, and the
    /// OAuth hand-off is exactly the kind of failure that is invisible on screen —
    /// a web view that redirects somewhere and shows nothing.
    static func debugLog(_ line: String) {
        guard let dir = ProcessInfo.processInfo.environment["TIAI_DEBUG_DUMP"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("debug.log")
        let stamp = ISO8601DateFormatter().string(from: .now)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? "\(stamp) \(line)\n".data(using: .utf8)?.write(to: url)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write("\(stamp) \(line)\n".data(using: .utf8) ?? Data())
    }
    #endif

    private func request<T: Decodable>(
        _ method: String, _ path: String, query: [String: String] = [:],
        bodyData: Data? = nil, timeout: TimeInterval = 30
    ) async throws -> T {
        // GETs are idempotent, so a blip is absorbed silently. The ladder is
        // deliberately long-tailed: the case that actually hurts is a self-hosted
        // server restarting, which takes half a minute, and three tries inside two
        // seconds just means the app gives up while the backend is still booting.
        // Cached content stays on screen through it, so waiting costs nothing the
        // user can see.
        let attempts = method == "GET" ? 6 : 1
        var last: Error = APIError.unreachable("no attempt made")
        for attempt in 0..<attempts {
            do {
                let (data, http) = try await perform(
                    method, server.api(path, query: query), bodyData: bodyData, timeout: timeout)
                return try Self.validate(data, http, as: T.self)
            } catch {
                last = error
                let transient = (error as? APIError)?.isTransient ?? false
                guard transient, attempt + 1 < attempts else { throw error }
                try? await Task.sleep(for: .seconds(Self.retryDelays[attempt]))
            }
        }
        throw last
    }

    /// Waits between GET retries. Roughly 25 seconds in total: long enough to
    /// ride out a container restart, short enough that a genuinely wrong URL
    /// still reports itself within a screenful of patience.
    static let retryDelays: [TimeInterval] = [0.3, 0.9, 2.0, 5.0, 9.0]

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

    /// Names a chat.
    ///
    /// `POST /chats/{id}` merges whatever is sent into the stored chat and then
    /// copies `title` out to its own column, so sending only a title leaves the
    /// history alone. The web UI does the same thing; without it a chat the app
    /// started stays literally "New Chat" in the list and in the browser, even
    /// though the app shows a sensible name in its own nav bar.
    public func setChatTitle(id: String, title: String) async throws {
        let body = try JSONEncoder().encode(["chat": ["title": title]])
        _ = try await expectStatus("POST", "/chats/\(id)", bodyData: body)
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
        #if DEBUG
        // The completion does not go through `perform`, so it needs its own
        // dump. This is the request worth reading when someone says "it sent but
        // the model never saw it" — the answer is either in here or it is not.
        Self.dump(url: url, method: "REQ_POST", data: req.httpBody ?? Data())
        #endif

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

    /// Raw JSON for diagnostics.
    ///
    /// Some endpoints have no published shape, and the only way to find out what
    /// one actually returns is to look at it. Every wrong guess about
    /// `tool_servers` so far was a guess because nobody had looked.
    public func rawJSON(_ path: String) async throws -> JSONValue {
        let (data, http) = try await perform("GET", server.api(path), bodyData: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    // MARK: - tool calls

    /// The tools this chat can be given: MCP servers and workspace tools alike.
    ///
    /// One endpoint, and it is the one the web client's tool picker uses. Three
    /// earlier guesses at this — the admin registry at `/configs/tool_servers`,
    /// `settings.toolServers`, and a merged tolerant decode of both — were all
    /// wrong, and all three are recorded in the commit history so nobody repeats
    /// them. What settles it is the bytes: `/tools/` returns
    /// `{"id": "server:mcp:1", "name": "Notion"}, {"id": "server:mcp:2", "name":
    /// "Sonos"}`, while the admin registry returns `TOOL_SERVER_CONNECTIONS`
    /// keyed by url with no names at all, and `settings.toolServers` does not
    /// exist on this deployment.
    ///
    /// Selected ids go out as `tool_ids`. Entries that cannot be read are dropped
    /// rather than failing the list: one odd row should not cost the whole picker.
    /// Terminals the instance registered, so the completion request can name one.
    public func terminals() async throws -> [Terminal] {
        let json: JSONValue = try await request("GET", "/terminals/")
        return (json.arrayValue ?? []).compactMap(Terminal.init)
    }

    public func chatTools() async throws -> [ChatTool] {
        let json: JSONValue = try await request("GET", "/tools/")
        return (json.arrayValue ?? []).compactMap(ChatTool.init)
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

    // MARK: - editing and rating

    /// Replaces a message's text.
    ///
    /// The server keeps the message id, so the siblings a previous regenerate
    /// created stay where they are — which is what makes "edit and resend" a
    /// branch rather than a rewrite of history.
    public func updateMessage(chatID: String, messageID: String, content: String) async throws {
        let data = (try? JSONEncoder().encode(["content": content])) ?? Data("{}".utf8)
        let _: JSONValue = try await request(
            "POST", "/chats/\(chatID)/messages/\(messageID)", bodyData: data)
    }

    /// Thumbs up or down on an assistant message.
    ///
    /// The body is read off the web client rather than documented: `type:
    /// "rating"` with the score under `data`. A rating is the least important
    /// thing happening in a chat, so a rejection should be shown and then
    /// forgotten, never block a reply.
    public func rate(chatID: String, messageID: String, rating: Int) async throws {
        let body: [String: JSONValue] = [
            "type": .string("rating"),
            "data": .object(["rating": .number(Double(rating))]),
            "chat_id": .string(chatID),
            "message_id": .string(messageID),
        ]
        let data = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
        // Under /evaluations, not at the API root: the feedback routes are
        // mounted on the evaluations router (`/api/v1/evaluations/feedback`).
        // Posting to /feedback returns 404 and the thumb silently does nothing.
        let _: JSONValue = try await request("POST", "/evaluations/feedback", bodyData: data)
    }

    // MARK: - memories

    public func memories() async throws -> [Memory] {
        try await request("GET", "/memories/")
    }

    public func addMemory(_ content: String) async throws -> Memory {
        struct Form: Encodable { let content: String }
        return try await request("POST", "/memories/add", bodyData: try? JSONEncoder().encode(Form(content: content)))
    }


    /// Edits one memory in place.
    ///
    /// Only `content` is sent. The endpoint also accepts `type` and `path`, and
    /// treats a present key as an instruction to write it — so sending them
    /// null would not leave them alone, it would change them.
    public func updateMemory(id: String, content: String) async throws -> Memory {
        struct Form: Encodable { let content: String }
        return try await request(
            "POST", "/memories/\(id)/update",
            bodyData: try? JSONEncoder().encode(Form(content: content)))
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

    // MARK: - audio

    /// Speech to text, using whatever STT the instance has configured.
    ///
    /// The endpoint is Open WebUI's own `/audio/transcriptions`, so the app
    /// never talks to Whisper directly and never needs to know that it exists:
    /// the instance decides the model, the language detection, the chunking of
    /// long audio, and whether it is Whisper at all. Adding or swapping the
    /// backend stays a server-side change rather than an app release.
    ///
    /// Returns nil when the audio came back empty, which is a real outcome —
    /// a few seconds of silence transcribes to nothing — and is different from
    /// a failure, which throws.
    public func transcribe(data: Data, filename: String, mimeType: String,
                           language: String? = nil) async throws -> String? {
        var body = Data()
        let boundary = "----tiai-\(UUID().uuidString)"
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        if let language {
            body.append(Data("\r\n--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
            body.append(Data(language.utf8))
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (payload, http) = try await perform(
            "POST", server.api("/audio/transcriptions"),
            bodyData: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120)
        // `text` is optional on purpose: a response that decodes but carries no
        // text is a successful call over silent audio, not a failure.
        struct Transcript: Decodable { let text: String? }
        let transcript = try Self.validate(payload, http, as: Transcript.self)
        let trimmed = (transcript.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - notes

    /// Notes are a separate object from chats, with their own list and sharing.
    public func notes() async throws -> [Note] {
        try await request("GET", "/notes/")
    }

    public func note(id: String) async throws -> Note {
        try await request("GET", "/notes/\(id)")
    }

    public func createNote(title: String, markdown: String) async throws -> Note {
        try await request(
            "POST", "/notes/create", bodyData: Note.payload(title: title, markdown: markdown))
    }

    /// Saves a note. Only `title` and `content.md` are sent, because the server
    /// merges the keys present and a note also carries a rich-editor document
    /// this client has no business rewriting.
    public func updateNote(id: String, title: String, markdown: String) async throws -> Note {
        try await request(
            "POST", "/notes/\(id)/update",
            bodyData: Note.payload(title: title, markdown: markdown))
    }

    public func deleteNote(id: String) async throws {
        let _: Bool = try await request("DELETE", "/notes/\(id)/delete")
    }

    /// Raw bytes of an uploaded file.
    ///
    /// `AsyncImage` cannot be used here: the route is behind the bearer token,
    /// and a plain URL handed to it comes back 401 — which is also why a picture
    /// attached in the web UI never appeared in this app. The app fetches the
    /// bytes itself and hands over an image.
    public func fileContent(id: String) async throws -> Data {
        let (data, http) = try await perform(
            "GET", server.api("/files/\(id)/content"), bodyData: nil, timeout: 60)
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        default: throw APIError.http(status: http.statusCode, message: "\(http.statusCode)")
        }
    }

    /// Bytes for a file the model produced in its terminal sandbox.
    ///
    /// Not under the file routes: the sandbox is a separate service that Open
    /// WebUI proxies at `/terminals/{selector}/`, and it identifies the chat by
    /// an `X-Session-Id` header rather than anything in the path — without it
    /// the terminal does not know whose sandbox to look in.
    public func terminalFile(selector: String, path: String, sessionID: String) async throws -> Data {
        let url = try server.api("/terminals/\(selector)/files/view",
                                 query: ["path": path])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !server.token.isEmpty {
            req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(sessionID, forHTTPHeaderField: "X-Session-Id")
        let (data, response) = try await transport.send(req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unreachable("response was not HTTP")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        default: throw APIError.http(status: http.statusCode, message: "\(http.statusCode)")
        }
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
