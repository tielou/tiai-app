import Foundation
import Testing

@testable import TiAiKit

/// Loads a file from `Fixtures/`.
///
/// Fixtures are real captured payloads with the identifiers scrubbed, not
/// hand-written idealisations — the value is in the parts nobody would
/// hand-write, like a `content` that is a block array, a message with both a
/// `statusHistory` and an `error`, and a model record with no `info` at all.
enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: nil)
        else {
            preconditionFailure("missing fixture \(name)")
        }
        return try! Data(contentsOf: url)
    }

    static func string(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

// MARK: - SSE framing

struct SSEParserTests {
    private func parse(_ text: String, in chunks: [String] = []) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks.isEmpty ? [text] : chunks {
            events += parser.feed(Data(chunk.utf8))
        }
        events += parser.finish()
        return events
    }

    @Test func singleFrame() {
        let events = parse("data: {\"a\":1}\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "{\"a\":1}")
    }

    /// The one that only shows up on a lossy connection: a frame split across
    /// two network reads, mid-value.
    @Test func frameSplitAcrossChunks() {
        let events = parse("", in: ["data: {\"a\"", ":1}\n", "\n"])
        #expect(events.count == 1)
        #expect(events[0].data == "{\"a\":1}")
    }

    @Test func exactlyOneLeadingSpaceIsFraming() {
        // "data:  x" carries a payload of " x", not "x".
        let events = parse("data:  x\n\n")
        #expect(events[0].data == " x")
    }

    @Test func crlfAndBareCR() {
        #expect(parse("data: a\r\n\r\n").first?.data == "a")
        #expect(parse("data: b\r\r").first?.data == "b")
    }

    /// A bare CR at the end of a chunk may be the first half of a CRLF split
    /// across reads; treating it as a line end there corrupts the next field.
    @Test func trailingCRWaitsForTheNextChunk() {
        let events = parse("", in: ["data: a\r", "\n\r\n"])
        #expect(events.count == 1)
        #expect(events.first?.data == "a")
    }

    @Test func commentsAreIgnored() {
        let events = parse(": keep-alive\n\ndata: x\n\n")
        #expect(events.map(\.data) == ["x"])
    }

    @Test func multipleDataLinesJoinWithNewline() {
        let events = parse("data: a\ndata: b\n\n")
        #expect(events.first?.data == "a\nb")
    }

    @Test func eventAndIDFieldsSurvive() {
        let events = parse("event: status\nid: 7\ndata: x\n\n")
        #expect(events.first?.event == "status")
        #expect(events.first?.id == "7")
    }

    @Test func finalFrameWithoutTrailingBlankLineIsNotDropped() {
        let events = parse("data: last")
        #expect(events.last?.data == "last")
    }
}

// MARK: - completion stream

struct ChatEventStreamTests {
    private func events(from text: String) async throws -> [ChatEvent] {
        let bytes = ByteStream {
            AsyncThrowingStream { continuation in
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    continuation.yield(Data((line + "\n").utf8))
                }
                continuation.finish()
            }
        }
        var result: [ChatEvent] = []
        for try await event in ChatEventStream(bytes: bytes) {
            result.append(event)
        }
        return result
    }

    @Test func fixtureStreamNormalizes() async throws {
        let events = try await events(from: Fixture.string("stream.sse"))

        let text = events.compactMap { if case let .delta(value) = $0 { value } else { nil } }
            .joined()
        #expect(text == "Because the KV pool was full.")

        #expect(events.contains(.reasoning("checking the metrics")))
        #expect(events.contains(.usage(
            TokenUsage(
                promptTokens: 4210, completionTokens: 88, totalTokens: 4298,
                completionTokensPerSecond: nil))))
        #expect(events.last == .done)
    }

    @Test func errorFrameEndsTheStream() async throws {
        let frame = "data: {\"error\":{\"message\":\"model not found\"}}\n\n"
        let events = try await events(from: frame)
        #expect(events == [.failed("model not found")])
    }

    @Test func nonJsonFrameIsIgnoredRatherThanFatal() async throws {
        let frame = """
            data: not json

            data: {"choices":[{"delta":{"content":"hi"}}]}

            data: [DONE]

            """
        let events = try await events(from: frame)
        #expect(events == [.delta("hi"), .done])
    }
}

// MARK: - decoding

struct ModelDecodingTests {
    @Test func modelListDecodes() throws {
        struct Envelope: Decodable { let data: [ChatModel] }
        let models = try Fixture.decode(Envelope.self, "models.json").data
        #expect(models.count == 4)

        let personal = models[0]
        #expect(personal.id == "local-personal")
        #expect(personal.supportsVision)
        #expect(personal.defaultFeatureIDs == ["web_search"])
        #expect(personal.baseModelID == "qwen3.8-flash-next")
        // An unknown capability is kept, not dropped: a capability added by a
        // server release should light up a toggle, not fail to decode.
        #expect(personal.capabilities["some_future_capability"] == true)
    }

    /// Capability names are the server's, not the app's: `citations` and
    /// `builtin_tools`, not `citation` and `tools`. Getting this wrong hides
    /// features the user has.
    @Test func capabilitiesUseTheServersNames() throws {
        struct Envelope: Decodable { let data: [ChatModel] }
        let models = try Fixture.decode(Envelope.self, "models.json").data
        let personal = models[0]
        let deep = models[1]

        #expect(personal.supportsCitation)
        #expect(personal.supportsTools)
        #expect(personal.supportsWebSearch)
        #expect(personal.supportsMemory)
        #expect(personal.supportsStatusUpdates)
        #expect(!personal.supportsImageGeneration)
        #expect(deep.supportsImageGeneration)
        #expect(deep.supports(.codeInterpreter))
        #expect(!personal.supports(.codeInterpreter))
        // Thinking is a route (local-personal vs local-fast), not a capability —
        // which is why there is no thinking toggle in the composer.
        #expect(!personal.supports("thinking"))
    }

    /// The fast and quick routes advertise nothing. "No metadata" must not
    /// become "no features" — that would switch web search off on the models
    /// where the operator uses it most.
    @Test func emptyCapabilityMapOffersEverything() throws {
        struct Envelope: Decodable { let data: [ChatModel] }
        let models = try Fixture.decode(Envelope.self, "models.json").data
        let fast = models[2]
        #expect(fast.capabilities.isEmpty)
        #expect(fast.supports(.webSearch))
        #expect(fast.supports(.memory))
    }

    /// A model with no `info` at all is a server that changed shape, and the
    /// picker must still list it.
    @Test func modelWithoutInfoStillDecodes() throws {
        struct Envelope: Decodable { let data: [ChatModel] }
        let models = try Fixture.decode(Envelope.self, "models.json").data
        let bare = models[3]
        #expect(bare.id == "no-info-at-all")
        #expect(bare.capabilities.isEmpty)
        #expect(bare.baseModelID == nil)
    }

    @Test func chatListDecodesWithMissingOptionalFields() throws {
        let chats: [ChatSummary] = try Fixture.decode([ChatSummary].self, "chats-list.json")
        #expect(chats.count == 2)
        #expect(chats[0].pinned)
        #expect(chats[0].snippet == "Why is tiai slow?")
        // The second row has no pinned/archived keys at all.
        #expect(chats[1].pinned == false)
        #expect(chats[1].updatedAt > .distantPast)
    }

    /// `enable_websocket` is inside `features`, not at the root. Reading it from
    /// the root reports false and would convince the app there is no side
    /// channel — which is a design decision made silently by a typo.
    @Test func configReadsFlagsWhereTheServerPutsThem() throws {
        let config = try Fixture.decode(ServerConfig.self, "config.json")
        #expect(config.version == "0.11.4")
        #expect(config.enableWebsocket)
        #expect(!config.enableSignup)
    }
}

struct ChatDetailTests {
    @Test func threadFollowsTheCurrentBranch() throws {
        let chat = try Fixture.decode(ChatDetail.self, "chat-detail.json")
        // Two assistant siblings exist; currentId points at the second one.
        #expect(chat.thread.map(\.id) == ["user-1", "assistant-2"])
        #expect(chat.title == "Homelab question")
        #expect(chat.pinned)
    }

    @Test func blockContentYieldsText() throws {
        let chat = try Fixture.decode(ChatDetail.self, "chat-detail.json")
        let assistant = chat.thread.last
        #expect(assistant?.content.text == "Because the KV pool was full.")
        #expect(assistant?.content.blocks?.count == 1)
    }

    @Test func statusSourcesAndUsageSurvive() throws {
        let chat = try Fixture.decode(ChatDetail.self, "chat-detail.json")
        let assistant = chat.thread.last
        #expect(assistant?.statusHistory.map(\.status) == ["thinking", "calling tool: homelab"])
        #expect(assistant?.sources?.count == 1)
        #expect(assistant?.usage?.promptTokens == 4210)
        #expect(assistant?.done == true)
    }

    /// The tree walk must not loop forever on a cycle, and must fall back to
    /// something renderable when currentId points at a message that is gone.
    @Test func treeWalkSurvivesBrokenLinks() throws {
        let chat = try Fixture.decode(ChatDetail.self, "chat-detail.json")
        #expect(ChatMessage.tree(from: chat.messages, currentID: "does-not-exist").count >= 1)
        #expect(ChatMessage.tree(from: [:], currentID: nil).isEmpty)
    }
}

// MARK: - encoding

struct CompletionRequestTests {
    private func json(_ request: CompletionRequest) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(request))
    }

    private func base(_ parentID: CompletionRequest.ParentID) -> CompletionRequest {
        CompletionRequest(
            model: "local-personal",
            messages: [CompletionRequest.WireMessage(id: "m", role: "user", content: .text("hi"))],
            chatID: "c",
            parentID: parentID,
            stream: true)
    }

    /// "Key absent" and "key null" are different instructions to the server, so
    /// the difference has to survive encoding. This test is the reason the type
    /// is an enum instead of an optional string.
    @Test func parentIDDistinguishesAbsentFromNull() throws {
        let root = try json(base(.root))
        #expect(root["parent_id"] == .null)

        let absent = try json(base(.unspecified))
        #expect(absent["parent_id"] == nil)

        let branch = try json(base(.message("abc")))
        #expect(branch["parent_id"] == .string("abc"))
    }

    @Test func contentEncodesBackAsAWireValue() throws {
        let request = CompletionRequest(
            model: "m",
            messages: [CompletionRequest.WireMessage(id: "1", role: "user", content: .text("hello"))],
            stream: true)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains(#""content":"hello""#))
    }

    @Test func featuresAreABooleanMap() throws {
        var request = base(.root)
        request.features = [ChatFeature.webSearch.rawValue: true, ChatFeature.memory.rawValue: false]
        let encoded = try json(request)
        guard case let .object(features)? = encoded["features"] else { Issue.record("features missing"); return }
        #expect(features["web_search"] == .bool(true))
        #expect(features["memory"] == .bool(false))
    }
}

// MARK: - requests

/// Captures what went out and answers with a canned body, so a test can assert
/// on the request the client built. The alternative — a fixture of the response
/// alone — is exactly how the `POST /chats/new` body bug survived: the decode
/// side was tested and the encode side was not.
final class RecordingTransport: APITransport, @unchecked Sendable {
    private(set) var lastRequest: URLRequest?
    var status = 200
    var body = Data("{}".utf8)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, http)
    }

    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        lastRequest = request
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let payload = body
        return (ByteStream { AsyncThrowingStream { $0.yield(payload); $0.finish() } }, http)
    }
}

struct RequestTests {
    private func client(_ transport: RecordingTransport) -> OWUIClient {
        OWUIClient(
            server: Server(baseURL: URL(string: "https://chat.example.co")!, token: "tok"),
            transport: transport)
    }

    /// The bug the probe caught: the router takes the whole chat document, so a
    /// bare `{"title": …}` is a 422 `body.chat Field required`.
    @Test func createChatSendsTheChatDocument() async throws {
        let transport = RecordingTransport()
        transport.body = Fixture.data("chat-detail.json")
        _ = try await client(transport).createChat(title: "Hello")

        let body = try #require(transport.lastRequest?.httpBody)
        let sent = try JSONDecoder().decode([String: JSONValue].self, from: body)
        #expect(sent["chat"]?.objectValue?["title"]?.stringValue == "Hello")
        #expect(sent["chat"]?.objectValue?["history"] != nil)
        #expect(sent["title"] == nil)
    }

    @Test func bearerTokenGoesOnEveryCall() async throws {
        let transport = RecordingTransport()
        transport.body = Fixture.data("chats-list.json")
        _ = try await client(transport).chatList()
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    /// A 401 must arrive as `unauthorized` and not as a decoding failure: this
    /// is the difference between a login screen and a mysterious error card.
    @Test func unauthorizedBecomesUnauthorized() async {
        let transport = RecordingTransport()
        transport.status = 401
        transport.body = Data("{\"detail\":\"Not authenticated\"}".utf8)
        do {
            _ = try await client(transport).chatList()
            Issue.record("expected a throw")
        } catch let error as APIError {
            #expect(error.isUnauthorized)
        } catch {
            Issue.record("expected APIError.unauthorized, got \(error)")
        }
    }

    @Test func completionRequestIsPostedToTheRightPlace() async throws {
        let transport = RecordingTransport()
        transport.body = Data()
        _ = try await client(transport).stream(
            CompletionRequest(
                model: "local-personal",
                messages: [CompletionRequest.WireMessage(id: "1", role: "user", content: .text("hi"))],
                chatID: "c1", parentID: .root, messageID: "a1"))
        #expect(transport.lastRequest?.url?.path == "/api/v1/chat/completions")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let sent = try JSONDecoder().decode([String: JSONValue].self, from: #require(transport.lastRequest?.httpBody))
        #expect(sent["parent_id"] == .null)
        #expect(sent["chat_id"] == .string("c1"))
    }

    /// The wire name for "the assistant message this completion fills in" is
    /// `id`, and without it the server has no message id, `get_event_emitter`
    /// returns None, and the assistant turn is never persisted. The probe found
    /// this by reading back a chat that contained only the user's turn.
    @Test func completionCarriesTheAssistantMessageID() async throws {
        let transport = RecordingTransport()
        transport.body = Data()
        _ = try await client(transport).stream(
            CompletionRequest(
                model: "local-personal",
                messages: [CompletionRequest.WireMessage(id: "u1", role: "user", content: .text("hi"))],
                chatID: "c1", parentID: .root, messageID: "a1"))
        let sent = try JSONDecoder().decode([String: JSONValue].self, from: #require(transport.lastRequest?.httpBody))
        #expect(sent["id"] == .string("a1"))
    }

    /// The task routes have no `/api/v1` alias; asking for one is a 405.
    @Test func stopUsesTheUnversionedTaskRoute() async throws {
        let transport = RecordingTransport()
        try await client(transport).stop(chatID: "c1")
        #expect(transport.lastRequest?.url?.path == "/api/tasks/chat/c1/stop")
    }
}

// MARK: - server

struct ServerTests {
    @Test func parsesWhatSomebodyTypesIntoSettings() {
        #expect(Server.parse("chat.example.co")?.absoluteString == "https://chat.example.co")
        #expect(Server.parse("http://192.168.0.155:8080")?.host == "192.168.0.155")
        #expect(Server.parse("  https://chat.example.co/ ")?.absoluteString == "https://chat.example.co/")
        #expect(Server.parse("") == nil)
        #expect(Server.parse("not a url") == nil)
        #expect(Server.parse("ftp://example.co") == nil)
    }

    /// A base URL typed with a trailing slash would otherwise produce
    /// `//api/v1/...`, which FastAPI answers with a redirect to a path its
    /// router does not have.
    @Test func apiPathDoesNotDoubleSlash() throws {
        let withSlash = Server(baseURL: URL(string: "https://chat.example.co/")!)
        #expect(try withSlash.api("/chats/list").absoluteString == "https://chat.example.co/api/v1/chats/list")

        let without = Server(baseURL: URL(string: "https://chat.example.co")!)
        #expect(try without.api("/chats/list").absoluteString == "https://chat.example.co/api/v1/chats/list")
    }

    @Test func routesOutsideTheVersionedRouterStayOutside() throws {
        let server = Server(baseURL: URL(string: "https://chat.example.co")!)
        #expect(try server.raw("/api/version").absoluteString == "https://chat.example.co/api/version")
        #expect(try server.raw("/health").absoluteString == "https://chat.example.co/health")
    }
}

@Test func anEmptyURLShellIsNotAServer() {
    // The connect screen's placeholder is `https://`, which is a valid URL and a
    // nonsense host. It used to be reported as "Not reachable" before anyone had
    // typed anything.
    let shell = Server(baseURL: URL(string: "https://")!)
    #expect(!shell.hasURL)
    #expect(!shell.isConfigured)

    let real = Server(baseURL: URL(string: "https://chat.example.co")!, token: "t")
    #expect(real.hasURL)
    #expect(real.isConfigured)

    let hostless = Server(baseURL: URL(string: "https://")!, token: "t")
    #expect(!hostless.isConfigured)
}

@Test func realServerPayloadCarriesItsCitations() throws {
    // Straight from the server, from a chat where the model fetched rbb24.
    // Recorded rather than hand-written because the assumption "the app would
    // obviously have shown this" was wrong: the sources are stored, and the app
    // was the thing dropping them.
    let data = Fixture.data("chat-with-sources.json")
    let detail = try JSONDecoder().decode(ChatDetail.self, from: data)
    let message = try #require(detail.messages.values.first)
    let sources = message.citedSources
    #expect(sources.count == 1)
    #expect(sources.first?.name == "https://www.rbb24.de/berlin/")
    // The url is NOT on `source` for a fetched page — it is on metadata[0].url.
    // Reading only source.url is why a citation rendered as dead text.
    #expect(sources.first?.url == "https://www.rbb24.de/berlin/")
}

@Test func noteTimestampsSurviveWhateverUnitTheyArriveIn() throws {
    // Recorded from the server: notes come back with nanosecond timestamps, and
    // reading them as seconds put "December 5828963" in the list. The other
    // units are covered because nothing in the API says which one it is.
    func note(_ stamp: String) -> Note {
        try! JSONDecoder().decode(
            Note.self,
            from: Data("""
            {"id":"n1","title":"T","updated_at":\(stamp),"created_at":\(stamp),
             "data":{"content":{"md":"# Head\\nbody line"}}}
            """.utf8))
    }
    let expected = 1_790_407_934
    for stamp in ["\(expected)", "\(expected)000", "\(expected)000000", "\(expected)000000000"] {
        let seconds = note(stamp).updatedAt.timeIntervalSince1970
        #expect(abs(seconds - Double(expected)) < 2, "stamp \(stamp) read as \(seconds)")
    }
    #expect(note("\(expected)000000000").markdown == "# Head\nbody line")
    #expect(note("\(expected)000000000").preview == "Head")
}

@Test func aPreviewDoesNotRepeatTheTitle() throws {
    func note(_ title: String, _ md: String) throws -> Note {
        let raw: [String: Any] = [
            "id": "n", "title": title,
            "updated_at": 1_790_407_934, "created_at": 1_790_407_934,
            "data": ["content": ["md": md]],
        ]
        return try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    // All three shapes off the live server, verbatim.
    #expect(try note("Kos — 7 Days, Late September (Vegetarian Edition)",
                     "# Kos — 7 Days, Late September\n\n**Base:** Kos Town")
        .preview.contains("Base"))
    #expect(try note("AI Agent Naming — Options & Recommendation (Slack-ready)",
                     "🛰️ _AI AGENT NAMING — OPTIONS & RECOMMENDATION_  \n\nRoster below")
        .preview.contains("Roster"))
    #expect(try note("Home Agent Platform — Architecture",
                     "# Home Agent Platform — Architecture\n**Goal:** resident agents")
        .preview.contains("Goal"))
    // A body that starts with the title's words and carries on is content.
    #expect(try note("Kos", "Kos is an island").preview == "Kos is an island")
    // Too short to be a restatement, whatever it prefixes.
    #expect(try note("Goal setting for the quarter", "Goal\nrun the plan").preview == "Goal")
    #expect(try note("Anything", "").preview == "Empty note")
    // Markup is the author's, not the reader's.
    #expect(try note("Trip", "**Base:** Kos Town · **Car:** yes").preview
        == "Base: Kos Town · Car: yes")
    #expect(try note("Roster", "[_open-systems.com_](http://open-systems.com/x) has them")
        .preview == "open-systems.com has them")
    // A rule is not a preview of anything.
    #expect(try note("Plan", "---\n\nactually this").preview == "actually this")
}

@Test func notesRequestsMatchTheRoutes() async throws {
    // The routes are `POST /notes/create`, `POST /notes/{id}/update` and
    // `DELETE /notes/{id}/delete` — none of them RESTful, all of them easy to
    // guess wrong, and a wrong guess only shows up when someone tries to save.
    let transport = NotesTransport()
    let client = OWUIClient(
        server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
        transport: transport)

    _ = try await client.notes()
    _ = try await client.note(id: "n1")
    _ = try await client.createNote(title: "Groceries", markdown: "# List\n- bread")
    _ = try await client.updateNote(id: "n1", title: "Groceries", markdown: "# List\n- milk")
    try await client.deleteNote(id: "n1")

    #expect(transport.calls.map { "\($0.0) \($0.1)" } == [
        "GET /api/v1/notes",
        "GET /api/v1/notes/n1",
        "POST /api/v1/notes/create",
        "POST /api/v1/notes/n1/update",
        "DELETE /api/v1/notes/n1/delete",
    ])
    // Only `title` and `data.content.md` go on the wire. The note also holds a
    // rich-editor document, and the server merges the keys present — sending
    // anything else would overwrite what the web UI wrote.
    // The delete sends nothing, so "last" would be an empty body.
    let body = try #require(transport.bodies.last { !$0.isEmpty })
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(json?["title"] as? String == "Groceries")
    let content = (json?["data"] as? [String: Any])?["content"] as? [String: Any]
    #expect(content?["md"] as? String == "# List\n- milk")
    #expect(json.map { Set($0.keys) } == ["title", "data"])
}

/// Answers just enough for the notes routes to decode.
private final class NotesTransport: APITransport, @unchecked Sendable {
    private(set) var calls: [(String, String)] = []
    private(set) var bodies: [Data] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        calls.append((request.httpMethod ?? "", path))
        bodies.append(request.httpBody ?? Data())
        let note = """
        {"id":"n1","title":"Groceries","is_pinned":false,
         "updated_at":1790407934000000000,"created_at":1790407934000000000,
         "data":{"content":{"md":"# List\\n- bread"}}}
        """
        // The client drops the trailing slash on the way to the URL, so routes
        // are matched by suffix here rather than by exact path.
        let payload: String
        if path.hasSuffix("/notes/n1/delete") { payload = "true" }
        else if path.hasSuffix("/notes") { payload = "[\(note)]" }
        else { payload = note }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(payload.utf8), response)
    }

    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        fatalError("notes do not stream")
    }
}

private func voiceClient(_ transport: RecordingTransport) -> OWUIClient {
    OWUIClient(
        server: Server(baseURL: URL(string: "https://chat.example.co")!, token: "tok"),
        transport: transport)
}

// Dictation posts to Open WebUI's own transcription endpoint rather than to a
// speech model directly, so swapping Whisper for something else stays a server
// setting and never an app release.
@Test func transcribePostsMultipartAndReadsTheText() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"text":"  order the router firmware  ","filename":"a.m4a"}"#.utf8)
    let text = try await voiceClient(transport).transcribe(
        data: Data("fake-audio".utf8), filename: "a.m4a", mimeType: "audio/m4a")

    #expect(text == "order the router firmware", "whitespace is not content")
    let request = try #require(transport.lastRequest)
    #expect(request.url?.path == "/api/v1/audio/transcriptions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
    let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"file\"; filename=\"a.m4a\""))
    #expect(body.contains("Content-Type: audio/m4a"))
    #expect(body.contains("fake-audio"))
}

@Test func silentAudioIsNotAFailure() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"text":"   "}"#.utf8)
    let text = try await voiceClient(transport).transcribe(
        data: Data("x".utf8), filename: "a.m4a", mimeType: "audio/m4a")
    #expect(text == nil, "a few seconds of silence is an outcome, not an error")
}

@Test func memoryUpdateSendsOnlyContent() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"id":"m1","content":"prefers trains","type":"user","updated_at":1}"#.utf8)
    _ = try await voiceClient(transport).updateMemory(id: "m1", content: "prefers trains")

    let request = try #require(transport.lastRequest)
    #expect(request.url?.path == "/api/v1/memories/m1/update")
    let sent = try JSONDecoder().decode([String: JSONValue].self,
                                        from: try #require(request.httpBody))
    #expect(sent["content"]?.stringValue == "prefers trains")
    // The endpoint writes any key it receives, so absent is the only "leave
    // alone". Sending them null would change them, not preserve them.
    #expect(sent["type"] == nil)
    #expect(sent["path"] == nil)
}

@Test func deleteChatUsesTheBareResourceRoute() async throws {
    let transport = RecordingTransport()
    transport.status = 200
    transport.body = Data("true".utf8)
    try await voiceClient(transport).deleteChat(id: "c1")

    let request = try #require(transport.lastRequest)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path == "/api/v1/chats/c1")
}

// The app names its own chats, the way the web client does. `POST /chats/{id}`
// merges whatever is sent into the stored chat and copies `title` to its column,
// so the body must be nested under `chat` — a bare `{"title": ...}` is ignored
// and the chat keeps reading "New Chat" in the list and in the browser.
@Test func settingAChatTitleNestsItUnderChat() async throws {
    let transport = RecordingTransport()
    let client = OWUIClient(
        server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
        transport: transport)
    try await client.setChatTitle(id: "chat-1", title: "Boiling eggs")

    let request = try #require(transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/v1/chats/chat-1")
    let body = try #require(
        JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let chat = try #require(body["chat"] as? [String: Any], "title must be nested under `chat`")
    #expect(chat["title"] as? String == "Boiling eggs")
    #expect(body["history"] == nil, "sending history would risk clobbering the thread")
}

// The greeting is the first thing the app says, and the server stores most
// accounts' `name` as their email — so "Good afternoon, thilo@wobker.co" was the
// alternative to deriving a name.
@Test func greetingUsesAHumanFirstWord() {
    #expect(Greeting.firstName(from: "thilo@wobker.co") == "Thilo")
    #expect(Greeting.firstName(from: "rebecca.wobker@x.co") == "Rebecca")
    #expect(Greeting.firstName(from: "Thilo Wobker") == "Thilo")
    #expect(Greeting.firstName(from: "thilo") == "Thilo")
    #expect(Greeting.firstName(from: "") == nil)
    #expect(Greeting.firstName(from: nil) == nil)

    #expect(Greeting.timeOfDay(hour: 7) == "Good morning")
    #expect(Greeting.timeOfDay(hour: 15) == "Good afternoon")
    #expect(Greeting.timeOfDay(hour: 20) == "Good evening")
    #expect(Greeting.timeOfDay(hour: 1) == "Still up")

    var components = DateComponents(); components.hour = 15; components.minute = 10
    let afternoon = Calendar.current.date(from: components)!
    #expect(Greeting.line(for: "thilo@wobker.co", at: afternoon) == "Good afternoon, Thilo")
    // No name is not an error state; it just stops short.
    #expect(Greeting.line(for: nil, at: afternoon) == "Good afternoon")
}
