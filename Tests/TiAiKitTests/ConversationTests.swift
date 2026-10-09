import Foundation
import Testing

@testable import TiAiKit

private typealias Frame = ChatEventSocket.Frame

/// The conversation state machine, driven by a scripted transport and frames fed
/// into the hub by hand — no network, and no waiting on a model.
///
/// What these lock down is the sequence the probe proved the server requires:
/// create the chat first, send the assistant message id, read the socket while
/// the POST is still open, and treat `finish_reason` as the end.
@Test @MainActor func sendingCreatesTheChatFirstAndCarriesTheAssistantID() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", defaults: ["web_search"])],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"), transport: transport),
        hub: hub)

    conversation.draft = "Say the magic word"
    conversation.send()

    try await transport.awaitCompletion()
    #expect(transport.paths.first == "/api/v1/chats/new")

    let completion = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: completion) as? [String: Any])
    // Without this id the server writes nothing to the transcript, and the
    // answer arrives and then never happened.
    let assistantID = try #require(json["id"] as? String)
    #expect(!assistantID.isEmpty)
    #expect(json["chat_id"] as? String == "chat-1")
    #expect(json.hasNullParent)  // a first message has no parent, and null is not the same as absent
    #expect((json["features"] as? [String: Bool])?["web_search"] == true)

    for frame in Frames.run(chat: "chat-1", message: assistantID, answer: "MAGIC") {
        hub.receive(frame)
    }

    // The run ends on the terminal frame, not on the POST returning.
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.last?.text == "MAGIC")
    #expect(conversation.turns.last?.streaming == false)
    #expect(conversation.chatID == "chat-1")
}

@Test @MainActor func reasoningAndAnswerStayApartAndTheTerminalFrameEndsTheRun() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.reasoning_text.delta", "delta": "hmm"]))
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "Hel"]))
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "lo"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))

    try await waitUntil { conversation.phase == .ready }
    let answer = try #require(conversation.turns.last)
    #expect(answer.text == "Hello")
    #expect(answer.reasoning == "hmm")
    #expect(!answer.streaming)
    #expect(transport.paths.contains("/api/tasks/chat/chat-1/stop") == false)
}

@Test @MainActor func framesForAnotherMessageOrChatAreIgnored() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: "someone-else",
                               inner: ["type": "response.output_text.delta", "delta": "NOT MINE"]))
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "other-chat", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "NOT MY CHAT"]))
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "mine"]))

    try await waitUntil { conversation.turns.last?.text.contains("mine") == true }
    // Give the strays a chance to land if they were going to.
    try await Task.sleep(for: .milliseconds(20))
    #expect(conversation.turns.last?.text == "mine")
}

@Test @MainActor func stopAsksTheServerAndWaitsForTheTerminalFrame() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.draft = "count to a hundred"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "1 2 3"]))

    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { transport.paths.contains("/api/tasks/chat/chat-1/stop") }

    // The stop endpoint answers 200 whether or not anything halted, so the run
    // is only over when the server says so.
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.last?.text == "1 2 3")
}

@Test @MainActor func regenerateReusesTheUserMessageSoTheServerFilesASibling() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let firstAssistant = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: firstAssistant,
                               inner: ["type": "response.output_text.delta", "delta": "one"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstAssistant,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.count == 2)

    conversation.regenerate()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
    let newAssistantID = try #require(json["id"] as? String)
    #expect(newAssistantID != firstAssistant)
    // The parent is the user message, so the new answer is a sibling of the old
    // one rather than a new turn — that is what "2/2" in the web UI means.
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(json["parent_id"] as? String == userMessage["id"] as? String)
    #expect(conversation.turns.count == 2)  // placeholder answer, not a new pair
}

@Test @MainActor func aSilentStreamIsEndedRatherThanWaitingForever() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    hub.expire(chatID: "chat-1")  // what the silence watchdog does
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.error != nil)
    #expect(conversation.turns.last?.streaming == false)
}

@Test @MainActor func titleComesFromTheFirstLine() {
    #expect(ConversationModel.title(from: "Hello there\nsecond line") == "Hello there")
    #expect(ConversationModel.title(from: "   ") == "New Chat")
    #expect(ConversationModel.title(from: String(repeating: "x", count: 80)).count == 40)
}

// MARK: - helpers

@Test func markdownSplitsFencesAndKeepsAnOpenOneAsCode() {
    #expect(Markdown.blocks("just words") == [.prose("just words")])
    #expect(
        Markdown.blocks("before\n```swift\nlet x = 1\n```\nafter")
        == [.prose("before"), .code(language: "swift", code: "let x = 1"), .prose("after")])
    // Mid-stream: the fence has opened and the closing one has not arrived yet.
    #expect(
        Markdown.blocks("before\n```py\nprint(")
        == [.prose("before"), .code(language: "py", code: "print(")])
    #expect(Markdown.hasOpenFence("```py\nprint("))
    #expect(!Markdown.hasOpenFence("```py\nprint()\n```"))
    #expect(Markdown.blocks("") == [])
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw ProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum ProbeFailure: Error { case timeout }

extension Dictionary where Key == String {
    /// `null` and absent are different instructions to this server, so the test
    /// has to tell them apart the way JSON does.
    var hasNullParent: Bool { keys.contains("parent_id") && self["parent_id"] is NSNull }
}

/// A transport that records the calls and answers well enough for a run to
/// proceed: chat creation succeeds, the completion body stays open (as it does
/// for real), and stop returns 200.
final class ScriptedTransport: APITransport, @unchecked Sendable {
    private(set) var paths: [String] = []
    private(set) var completionBodies: [Data] = []
    var completionBody: Data? { completionBodies.last }

    var chatDetail: Data {
        Data(
            """
            {"id":"chat-1","title":"New Chat","updated_at":1,"created_at":1,
             "chat":{"models":["local-personal"],"history":{"currentId":null,"messages":{}}}}
            """.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        if path.hasSuffix("/chats/new") { return (chatDetail, response(for: request, 200)) }
        return (Data("{}".utf8), response(for: request, 200))
    }

    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        completionBodies.append(request.httpBody ?? Data())
        // The real one stays open for the whole generation and yields nothing;
        // an empty stream that ends at once would let a bug that ignores the
        // socket look correct, so it stays open until cancelled.
        let stream = ByteStream {
            AsyncThrowingStream<Data, any Error> { _ in
                // No elements, and it never finishes. Cancellation is the only
                // way out, which is the point: a test that mistakes "the body
                // closed" for "the run is over" would pass against a stream that
                // ends by itself.
            }
        }
        return (stream, response(for: request, 200))
    }

    var assistantMessageID: String? {
        guard let completionBody,
              let json = try? JSONSerialization.jsonObject(with: completionBody) as? [String: Any]
        else { return nil }
        return json["id"] as? String
    }

    /// Waits for the nth completion request to have gone out. The subscription
    /// is installed before the POST, so "a listener exists" is not the same as
    /// "the request is on the wire" — and injecting frames before the id is
    /// known is how these tests were flaky.
    func awaitCompletion(_ count: Int = 1) async throws {
        try await waitUntil { self.completionBodies.count >= count }
    }

    private func response(for request: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

extension ChatEventSocket.Frame {
    /// Builds a frame the way the server does, so the code under test sees the
    /// same dictionary shape `SocketIOClient` hands it.
    static func fixture(
        kind: String, chatID: String, messageID: String, inner: [String: Any]
    ) -> ChatEventSocket.Frame {
        let payload: [String: Any] = [
            "chat_id": chatID,
            "message_id": messageID,
            "data": ["type": kind, "data": inner],
        ]
        guard let frame = ChatEventSocket.Frame(payload) else {
            preconditionFailure("test fixture did not round-trip: \(payload)")
        }
        return frame
    }
}

enum Frames {
    /// The shape a real run produces: an opener, content deltas, a terminal
    /// `finish_reason`. See `Fixtures/socket-frames.jsonl`.
    static func run(chat: String, message: String, answer: String) -> [ChatEventSocket.Frame] {
        [
            ChatEventSocket.Frame.fixture(kind: "response:completion", chatID: chat, messageID: message, inner: [
                "id": "chatcmpl-1", "object": "chat.completion.chunk", "model": "local-personal",
                "choices": [["index": 0, "delta": ["content": "", "role": "assistant"]]],
            ]),
            ChatEventSocket.Frame.fixture(
                kind: "response:completion", chatID: chat, messageID: message,
                inner: ["type": "response.output_text.delta", "delta": answer, "output_index": 1]),
            ChatEventSocket.Frame.fixture(kind: "chat:completion", chatID: chat, messageID: message, inner: [
                "choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]],
            ]),
        ]
    }
}

extension ChatModel {
    static func stub(_ id: String, defaults: [String] = []) -> ChatModel {
        let meta: [String: Any] = [
            "capabilities": ["web_search": true],
            "defaultFeatureIds": defaults,
        ]
        let object: [String: Any] = [
            "id": id, "name": id, "owned_by": "local", "info": ["meta": meta],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(ChatModel.self, from: data)
    }
}
