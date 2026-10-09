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
        #expect(models.count == 3)

        let personal = models[0]
        #expect(personal.id == "local-personal")
        #expect(personal.supportsVision)
        #expect(personal.supportsThinking)
        #expect(personal.defaultFeatureIDs == ["web_search"])
        #expect(personal.baseModelID == "qwen3.8-flash-next")
        // An unknown capability is kept, not dropped: a capability added by a
        // server release should light up a toggle, not fail to decode.
        #expect(personal.capabilities["some_future_capability"] == true)
    }

    /// A model with no `info` at all is a server that changed shape, and the
    /// picker must still list it.
    @Test func modelWithoutInfoStillDecodes() throws {
        struct Envelope: Decodable { let data: [ChatModel] }
        let models = try Fixture.decode(Envelope.self, "models.json").data
        let bare = models[2]
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
