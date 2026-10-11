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
    private(set) var uploads: [Data] = []
    private(set) var resolveBodies: [Data] = []
    var completionBody: Data? { completionBodies.last }

    /// Replaces what GET /chats/{id} returns, for tests that need a real tree.
    var chatDetailOverride: Data?

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
        if path.hasSuffix("/chats/new") { return (chatDetailOverride ?? chatDetail, response(for: request, 200)) }
        if request.httpMethod == "GET", path.hasPrefix("/api/v1/chats/") {
            return (chatDetailOverride ?? chatDetail, response(for: request, 200))
        }
        if path.hasSuffix("/resolve") {
            resolveBodies.append(request.httpBody ?? Data())
            return (Data(#"{"status":true}"#.utf8), response(for: request, 200))
        }
        if path.hasSuffix("/files") || path.hasSuffix("/files/") {
            uploads.append(request.httpBody ?? Data())
            return (Data(#"{"id":"file-1","filename":"notes.txt","type":"text/plain","updated_at":1}"#.utf8),
                    response(for: request, 200))
        }
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
    static func stub(_ id: String, defaults: [String] = [], caps: [String: Bool]? = nil) -> ChatModel {
        let meta: [String: Any] = [
            "capabilities": caps ?? ["web_search": true],
            "defaultFeatureIds": defaults,
        ]
        let object: [String: Any] = [
            "id": id, "name": id, "owned_by": "local", "info": ["meta": meta],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(ChatModel.self, from: data)
    }
}


@Test @MainActor func attachmentsAreUploadedAndNamedOnTheCompletion() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.attach(data: Data("hi".utf8), name: "notes.txt", mimeType: "text/plain")
    try await waitUntil { conversation.attachments.count == 1 }
    #expect(transport.uploads.count == 1)
    // The multipart body has to name the file and declare its type, or the
    // server stores an extensionless blob it cannot route to a parser.
    let body = String(decoding: transport.uploads[0], as: UTF8.self)
    #expect(body.contains("filename=\"notes.txt\""))
    #expect(body.contains("Content-Type: text/plain"))

    conversation.draft = "read this"
    conversation.send()
    try await transport.awaitCompletion()
    let raw = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    // Not bare ids: the server walks `item["type"]` on each entry, so a list of
    // strings is not a shorter way of saying the same thing.
    let files = try #require(json["files"] as? [[String: Any]])
    #expect(files.first?["type"] as? String == "file")
    let inner = try #require(files.first?["file"] as? [String: Any])
    #expect(inner["id"] as? String == "file-1")
    #expect(inner["filename"] as? String == "notes.txt")
    // Attached to the message it was added for, then cleared - a chip that
    // lingered would silently re-send the same file on every later message.
    #expect(conversation.attachments.isEmpty)
}

@Test @MainActor func aPictureGoesInsideTheMessageNotJustInTheFilesList() async throws {
    // The bug this pins: the photo uploaded, the composer said "attached", the
    // message sent cleanly, and the model said it had received no image. `files`
    // is what retrieval and the transcript see; a vision model is given its
    // picture in the message content, and the app was only sending the id.
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { conversation.attachments.count == 1 }
    conversation.draft = "what is in this?"
    conversation.send()
    try await transport.awaitCompletion()

    let raw = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let user = try #require(messages.last { ($0["role"] as? String) == "user" })
    let blocks = try #require(user["content"] as? [[String: Any]])
    #expect(blocks.contains { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "what is in this?" })
    let image = try #require(blocks.first { ($0["type"] as? String) == "image_url" })
    let url = ((image["image_url"] as? [String: Any])?["url"] as? String) ?? ""
    // A data url, because the server passes `data:image/...` straight through to
    // the model. A file URL would have to be resolved and re-authenticated
    // server-side, which is a second thing to get wrong.
    #expect(url.hasPrefix("data:image/jpeg;base64,"))

    // And a model without vision is not sent a picture it cannot read.
    // A fresh transport: the assertion is about this request, not the last one.
    let blindTransport = ScriptedTransport()
    let blind = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-deep", caps: ["vision": false])],
        client: OWUIClient(server: server, transport: blindTransport),
        hub: ChatEventHub(server: server))
    blind.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { blind.attachments.count == 1 }
    blind.draft = "and this?"
    blind.send()
    try await blindTransport.awaitCompletion()
    let after = try #require(blindTransport.completionBody)
    let blindJSON = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
    let blindMessages = try #require(blindJSON["messages"] as? [[String: Any]])
    let blindUser = try #require(blindMessages.last { ($0["role"] as? String) == "user" })
    #expect(blindUser["content"] as? String == "and this?")
}

@Test @MainActor func memoryIsOnByDefaultWhereTheModelHasIt() {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let client = OWUIClient(server: server, transport: ScriptedTransport())

    let remembering = ChatModel.stub(
        "local-personal", defaults: ["web_search"],
        caps: ["web_search": true, "memory": true])
    let conversation = ConversationModel(
        chatID: nil, models: [remembering], client: client, hub: hub)

    // The server's default plus memory, which the server leaves off unless the
    // user enabled it globally.
    #expect(conversation.features["web_search"] == true)
    #expect(conversation.features["memory"] == true)

    // A model that does not report the capability must not get a toggle that
    // does nothing, and switching to it must drop the old model's choices.
    let plain = ChatModel.stub("local-fast", caps: ["web_search": true])
    conversation.select(model: "local-fast", from: [remembering, plain])
    #expect(conversation.features["memory"] == nil)

    // Filling in a model list that arrived late must not overwrite a choice the
    // user already made in this chat.
    conversation.features["web_search"] = false
    conversation.setModels([remembering, plain])
    #expect(conversation.features["web_search"] == false)
}

/// The frame the server emits when it parks a run on `ask_user`. `arguments` is
/// a JSON string inside a JSON object, and the schema inside it is the one
/// captured live from the server's own `ask_user` tool.
enum AskUserFixture {
    static let arguments =
        """
        {"allow_other":true,"questions":[{"header":"Meal choice","id":"meal",\
        "options":[{"description":"Classic, comforting","id":"pizza","label":"Pizza"},\
        {"description":"Fun and customizable","id":"tacos","label":"Tacos"}],\
        "question":"What would you like to eat?"}]}
        """

    static var outputItem: [String: Any] {
        [
            "type": "function_call", "call_id": "call_1", "name": "ask_user",
            "status": "pending", "arguments": arguments,
        ]
    }
}

@Test @MainActor func anAskUserCallParksTheRunInsteadOfEndingIt() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }

    let turn = try #require(conversation.turns.last)
    #expect(turn.awaitingCall?.name == "ask_user")
    // Parked is not finished and not failed. There is no terminal frame, so a
    // client that treats this as the end reports "the server sent nothing".
    #expect(conversation.error == nil)
    #expect(conversation.phase == .ready)
}

@Test @MainActor func answeringAToolCallResumesTheSameTurn() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }

    let call = try #require(conversation.turns.last?.awaitingCall)
    conversation.resolve(
        messageID: assistantID, call: call, action: .answer,
        answers: .object(["meal": .string("pizza")]))

    try await waitUntil { !transport.resolveBodies.isEmpty }
    let body = try #require(transport.resolveBodies.first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["call_id"] as? String == "call_1")
    #expect(json["action"] as? String == "answer")
    #expect((json["answers"] as? [String: String])?["meal"] == "pizza")
    #expect(transport.paths.contains("/api/v1/chats/chat-1/messages/\(assistantID)/resolve"))

    // The resumed run streams under the same assistant message id, so the answer
    // continues the turn that asked instead of starting a new one.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["type": "response.output_text.delta", "delta": "Berlin it is."]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.count == 2)  // user + one assistant, not three
    #expect(conversation.turns.last?.text == "Berlin it is.")
    #expect(conversation.turns.last?.awaitingCall == nil)
}

@Test func askUserPromptParsesTheRealSchema() {
    let data = Data(AskUserFixture.arguments.utf8)
    let arguments = try! JSONDecoder().decode(JSONValue.self, from: data)
    let prompt = try? #require(AskUserPrompt(arguments: arguments))
    #expect(prompt?.allowsOther == true)
    #expect(prompt?.questions.count == 1)
    #expect(prompt?.questions[0].value == "meal")
    #expect(prompt?.questions[0].header == "Meal choice")
    #expect(prompt?.questions[0].text == "What would you like to eat?")
    #expect(prompt?.questions[0].options.map(\.value) == ["pizza", "tacos"])
    #expect(prompt?.questions[0].options[0].label == "Pizza")
    #expect(prompt?.questions[0].options[0].detail == "Classic, comforting")

    // Answers are keyed by the tool's own ids, not by the wording.
    let answers = prompt!.answers(for: ["meal": ["pizza"]])
    #expect(answers["meal"]?.stringValue == "pizza")
}

/// The tool's arguments stream as `response.function_call_arguments.delta`,
/// which ends in `.delta` like every real content frame. Treating it as prose
/// prints the tool's JSON as the model's reply; the first live `ask_user` call
/// did exactly that, and the user read a schema instead of a question.
@Test func functionCallArgumentsNeverReachTheAnswer() {
    let frame = ChatEventSocket.Frame.fixture(
        kind: "response:completion", chatID: "c", messageID: "m",
        inner: ["type": "response.function_call_arguments.delta", "delta": "{}"])
    #expect(frame.delta == nil)
    #expect(frame.reasoningDelta == nil)

    // The real answer frame still has to get through.
    let answer = ChatEventSocket.Frame.fixture(
        kind: "response:completion", chatID: "c", messageID: "m",
        inner: ["type": "response.output_text.delta", "delta": "Pizza it is."])
    #expect(answer.delta == "Pizza it is.")
}

@Test @MainActor func theCompletionCarriesTheFieldsTheServerAccepts() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)
    conversation.tools = ["homelab"]
    conversation.chatVariables = .object(["room": .string("studio")])

    conversation.draft = "lights off"
    conversation.send()
    try await transport.awaitCompletion()

    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    // Without `ask` the server runs every tool without asking, and the approval
    // UI in this app would never appear.
    #expect((json["params"] as? [String: Any])?["tool_approval_mode"] as? String == "ask")
    #expect(json["tool_ids"] as? [String] == ["homelab"])
    #expect((json["chat_variables"] as? [String: Any])?["room"] as? String == "studio")
    // Fields nobody set must stay off the wire, not arrive as nulls the server
    // reads as "clear this".
    #expect(json["tool_servers"] == nil)
    #expect(json["session_id"] == nil)
    #expect(json["filter_ids"] == nil)
}

/// The order the server actually sends: arguments, finish, and only then the
/// pause frame with `output`. A client that ends the run on `finish_reason`
/// shows an empty turn and no question.
@Test @MainActor func thePauseFrameArrivesAfterTheFinishFrame() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "what should I eat?"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["type": "response.function_call_arguments.delta", "delta": "{\"questions\":[…]}"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))

    try await waitUntil { conversation.phase == .ready }
    let turn = try #require(conversation.turns.last)
    #expect(turn.awaitingCall?.name == "ask_user")
    // The arguments are not the answer.
    #expect(turn.text.isEmpty)
    #expect(conversation.error == nil)
}

/// A resolved call arrives as two entries sharing one `call_id`: the
/// `function_call` and its `function_call_output`. Reading them as two calls
/// rendered the same question twice on the live test.
@Test func aCallAndItsResultAreOneCard() {
    let items: [JSONValue] = [
        .object([
            "type": .string("function_call"), "call_id": .string("c1"),
            "name": .string("ask_user"), "status": .string("completed"),
            "arguments": .string("{}"),
        ]),
        .object([
            "type": .string("function_call_output"), "call_id": .string("c1"),
            "output": .array([.object(["type": .string("input_text"), "text": .string("pizza")])]),
            "status": .string("completed"),
        ]),
    ]
    let calls = ToolCall.calls(from: items)
    #expect(calls.count == 1)
    #expect(calls[0].resultText == "pizza")
    #expect(calls[0].status == .completed)
    #expect(!calls[0].isAwaitingUser)
}

@Test func anAnsweredCallReadsAsASentenceNotAsJSON() throws {
    let items: [JSONValue] = [
        .object([
            "type": .string("function_call"), "call_id": .string("c1"),
            "name": .string("ask_user"), "status": .string("completed"), "arguments": .string("{}"),
        ]),
        .object([
            "type": .string("function_call_output"), "call_id": .string("c1"),
            "output": .array([.object([
                "type": .string("input_text"),
                "text": .string(#"{"status":"answered","answers":{"meal":"Pizza"}}"#),
            ])]),
            "status": .string("completed"),
        ]),
    ]
    let call = try #require(ToolCall.calls(from: items).first)
    // The transcript should say what was picked, not show the wire payload.
    #expect(call.answerSummary == "Pizza")
}

@Test func chatToolsComeFromTheServerNotFromTheApp() throws {
    // Trimmed but otherwise verbatim from GET /api/v1/tools/ on the live
    // instance. The previous version of this test asserted that ids were urls,
    // which was a guess and was wrong: an MCP server arrives as `server:mcp:1`.
    let payload: [JSONValue] = [
        .object([
            "id": .string("server:mcp:1"), "name": .string("Notion"),
            "user_id": .string("server:mcp:1"), "authenticated": .bool(false),
            "meta": .object(["description": .string(""), "has_user_valves": .bool(false)]),
        ]),
        .object([
            "id": .string("server:mcp:2"), "name": .string("Sonos"),
            "authenticated": .bool(true),
            "meta": .object(["description": .string("Control the speakers")]),
        ]),
        // An entry with nothing to identify it is dropped, not shown blank.
        .object(["description": .string("mystery")]),
    ]
    let tools = payload.compactMap(ChatTool.init)
    #expect(tools.map(\.id) == ["server:mcp:1", "server:mcp:2"])
    #expect(tools.map(\.name) == ["Notion", "Sonos"])
    // An empty description means none, not a blank line under the name.
    #expect(tools[0].detail == nil)
    #expect(tools[1].detail == "Control the speakers")
    // An OAuth server the user has not signed into has to say so on the row;
    // absent is not the same as false.
    #expect(tools[0].authenticated == false)
    #expect(tools[1].authenticated == true)
    // Unverified is not broken: only an explicit error disables a tool.
    #expect(tools[0].available)
}

@Test func unauthenticatedServerToolsCarryTheirSignInURL() throws {
    func tool(_ id: String, _ authed: Bool?) -> ChatTool {
        var json: [String: JSONValue] = ["id": .string(id), "name": .string("x")]
        if let authed { json["authenticated"] = .bool(authed) }
        return ChatTool(.object(json))!
    }
    let base = URL(string: "https://chat.example.co")!
    // The shape the web client builds: the id without its `server:` prefix,
    // at the site root rather than under /api/v1.
    #expect(
        tool("server:mcp:1", false).authorizeURL(base: base)?.absoluteString
            == "https://chat.example.co/oauth/clients/mcp:1/authorize")
    // A trailing slash on the stored url must not become a double slash.
    let signed = tool("server:mcp:2", false).authorizeURL(base: URL(string: "https://chat.example.co/")!)
    #expect(signed?.absoluteString == "https://chat.example.co/oauth/clients/mcp:2/authorize")
    // Already signed in, or not an MCP server at all: nothing to open.
    #expect(tool("server:mcp:1", true).authorizeURL(base: base) == nil)
    #expect(tool("my_workspace_tool", nil).authorizeURL(base: base) == nil)
}

@Test func thinkingPoseIsStablePerRunAndVariesBetweenRuns() {
    // The animation is drawn, not a sprite sheet, so what matters is that one
    // run keeps one pose for its whole life — a cat that changes species
    // mid-generation is worse than no cat — and that runs do not all get the
    // same one, or it stops being a signal.
    #expect(ThinkingAnimation.poseIndex(for: "abc") == ThinkingAnimation.poseIndex(for: "abc"))
    let spread = (1...24).map { ThinkingAnimation.poseIndex(for: "run-\($0)") }
    #expect(Set(spread).count > 1, "every run gets the same animation")
}

@Test func onlySomeFailuresAreWorthRetrying() {
    // A blip gets another attempt; a wrong request gets the same answer twice.
    #expect(APIError.http(status: 503, message: "upstream").isTransient)
    #expect(APIError.http(status: 429, message: "slow down").isTransient)
    #expect(APIError.http(status: 408, message: "timeout").isTransient)
    #expect(APIError.unreachable("network is down").isTransient)
    #expect(!APIError.http(status: 404, message: "no such chat").isTransient)
    #expect(!APIError.http(status: 401, message: "gone").isTransient)
    #expect(!APIError.unauthorized.isTransient)
    #expect(!APIError.cancelled.isTransient)
    // Decoding is not transient either: the same bytes will not decode better.
    #expect(!APIError.decoding("not json").isTransient)
}

@Test func settledToolCallsShareOneCardAndQuestionsStayAlone() {
    func call(_ id: String, status: String) -> ToolCall {
        ToolCall(.object([
            "type": .string("function_call"), "call_id": .string(id),
            "name": .string("ask_user"), "status": .string(status),
        ]))!
    }
    let calls = [call("a", status: "completed"), call("b", status: "completed"),
                 call("q", status: "pending"), call("c", status: "completed")]
    let groups = ToolCall.grouped(calls)
    // Two settled, then the question on its own, then one more settled run.
    #expect(groups.count == 3)
    if case .settled(let pair) = groups[0] { #expect(pair.map(\.id) == ["a", "b"]) }
    if case .awaiting(let question) = groups[1] { #expect(question.id == "q") }
    if case .settled(let last) = groups[2] { #expect(last.map(\.id) == ["c"]) }
}

@Test @MainActor func editingAMessageStoresItAndReRunsFromIt() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"), transport: transport),
        hub: hub)
    // The message being edited has to exist, so the conversation is loaded from
    // a fixture that contains it.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-2","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1","assistant-2"]},
           "assistant-2":{"id":"assistant-2","role":"assistant","content":"second","parentId":"user-1"}}}}}
        """.utf8)
    await conversation.load()

    conversation.edit(messageID: "user-1", text: "Actually: Berlin, but colder")
    try await transport.awaitCompletion()

    // The text is stored on the server first; the run then reuses the same user
    // message id, so the previous answer survives as a sibling rather than being
    // overwritten.
    #expect(transport.paths.contains("/api/v1/chats/chat-1/messages/user-1"))
    #expect(transport.paths.last?.hasSuffix("/chat/completions") ?? false)
    let body = try #require(transport.completionBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((json["id"] as? String) != "assistant-2")
    #expect(json["parent_id"] as? String == "user-1")
    #expect(conversation.turns.first?.text == "Actually: Berlin, but colder")
}

@Test @MainActor func aThumbUpGoesToFeedback() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"), transport: transport),
        hub: hub)
    conversation.rate(messageID: "assistant-2", rating: 1)
    try await Task.sleep(for: .milliseconds(150))
    #expect(transport.paths.contains("/api/v1/evaluations/feedback"))
    #expect(conversation.ratings["assistant-2"] == 1)
    // Tapping the same thumb again clears it locally without another request.
    conversation.rate(messageID: "assistant-2", rating: 1)
    #expect(conversation.ratings["assistant-2"] == nil)
}

@Test @MainActor func siblingAnswersCanBePagedThrough() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    // The fixture has one user message with two assistant answers and the second
    // one current — the shape a regenerate leaves behind.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-2","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1","assistant-2"]},
           "assistant-1":{"id":"assistant-1","role":"assistant","content":"first","parentId":"user-1"},
           "assistant-2":{"id":"assistant-2","role":"assistant","content":"second","parentId":"user-1"}}}}}
        """.utf8)
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"), transport: transport),
        hub: hub)
    await conversation.load()

    let page = try #require(conversation.siblingPage(of: "user-1"))
    #expect(page.index == 2 && page.total == 2)
    #expect(conversation.turns.last?.text == "second")

    conversation.selectSibling(of: "user-1", direction: -1)
    #expect(conversation.turns.last?.text == "first")
    #expect(conversation.siblingPage(of: "user-1")?.index == 1)
    // Past the end is a no-op rather than a crash or a blank transcript.
    conversation.selectSibling(of: "user-1", direction: -1)
    #expect(conversation.turns.last?.text == "first")
}

@Test func blockLevelMarkdownIsRecognised() {
    // The inline-only parser Apple gives us cannot do headings or lists, and the
    // full one reflows newlines and shreds stack traces — so block structure is
    // detected per line. Before this, `## Key Facts` rendered as `## Key Facts`.
    #expect(Markdown.classify("## Key Facts") == .heading(level: 2, text: "Key Facts"))
    #expect(Markdown.classify("# Title") == .heading(level: 1, text: "Title"))
    #expect(Markdown.classify("- an item") == .bullet(text: "an item"))
    #expect(Markdown.classify("* also an item") == .bullet(text: "also an item"))
    #expect(Markdown.classify("3. third") == .numbered(index: 3, text: "third"))
    #expect(Markdown.classify("> quoted") == .quote(text: "quoted"))
    // Not headings: a hashtag, and hashes without the space.
    #expect(Markdown.classify("#hashtag") == nil)
    #expect(Markdown.classify("####### seven is not a heading") == nil)
    // A date or a version number is not a list item either.
    #expect(Markdown.classify("2024. was a year") == nil)
    #expect(Markdown.classify("plain prose") == nil)

    let blocks = Markdown.blocks("Before\n## Key Facts\n- one\n- two\nAfter")
    #expect(blocks == [
        .prose("Before"), .heading(level: 2, text: "Key Facts"),
        .bullet(text: "one"), .bullet(text: "two"), .prose("After"),
    ])
    // Inside a fence nothing is a heading.
    #expect(Markdown.blocks("```\n## not a heading\n```") == [
        .code(language: nil, code: "## not a heading")
    ])
}

@Test func citedSourcesFlattenTheServerShape() {
    // What the server actually stores: a web hit carries a url, a file or a
    // fetched page may not. The `[1]` markers in the answer text refer to this
    // list's order, so order is preserved and nothing is deduplicated.
    let json = """
    {"id":"m1","role":"assistant","content":"x [1]","sources":[\
      {"source":{"name":"Tagesspiegel","url":"https://tagesspiegel.de/a"},\
       "document":["..."],"metadata":[{"title":"Tagesspiegel"}]},\
      {"source":{"name":"rbb","url":"https://rbb-online.de/b"}},\
      {"source":{"id":"f1","name":"notes.pdf","type":"file"}},\
      {"source":{"url":"https://unnamed.example"}},\
      {"unexpected":true}\
    ]}
    """
    let message = try! JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    let sources = message.citedSources
    #expect(sources.count == 3)
    #expect(sources[0].name == "Tagesspiegel")
    #expect(sources[0].url == "https://tagesspiegel.de/a")
    #expect(sources[1].url == "https://rbb-online.de/b")
    // A file with no url is still a source worth listing, just not tappable.
    #expect(sources[2].name == "notes.pdf")
    #expect(sources[2].url == nil)
}

@Test @MainActor func pagingToAnOlderAnswerKeepsEverythingBelowIt() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    // The older answer is not the end of the story: a follow-up message and its
    // answer hang below it. Paging to that answer used to stop at the answer,
    // so the rest of the branch — a pasted screenshot and its reply, say —
    // disappeared, which reads as the app having deleted something.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"a2","messages":{
           "u1":{"id":"u1","role":"user","content":"hi","childrenIds":["a1","a2"]},
           "a1":{"id":"a1","role":"assistant","content":"first","parentId":"u1","childrenIds":["u2"]},
           "u2":{"id":"u2","role":"user","content":"and this?","parentId":"a1","childrenIds":["a3"]},
           "a3":{"id":"a3","role":"assistant","content":"third","parentId":"u2"},
           "a2":{"id":"a2","role":"assistant","content":"second","parentId":"u1"}}}}}
        """.utf8)
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
            transport: transport),
        hub: hub)
    await conversation.load()
    #expect(conversation.turns.map(\.id) == ["u1", "a2"])

    conversation.selectSibling(of: "u1", direction: -1)
    #expect(conversation.turns.map(\.id) == ["u1", "a1", "u2", "a3"])
    conversation.selectSibling(of: "u1", direction: 1)
    #expect(conversation.turns.map(\.id) == ["u1", "a2"])
}

@Test func anImageInsideTheMessageBodyCountsAsAnAttachment() throws {
    // The app's own uploads are stored with the picture in the message content
    // and no `files` entry at all, so a renderer that only reads `files` shows a
    // message with a photo in it and no photo - which is the bug this pins.
    let data = """
        {"id":"u1","role":"user","parent_id":null,"children_ids":[],
         "content":[{"type":"text","text":"what is this"},
                    {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,AAAA"}}]}
        """.data(using: .utf8)!
    let message = try JSONDecoder().decode(ChatMessage.self, from: data)
    let attachments = message.messageAttachments
    #expect(attachments.count == 1)
    #expect(attachments.first?.isImage == true)
    #expect(attachments.first?.dataURL == "data:image/jpeg;base64,AAAA")
    // The text is still the text; stealing it would blank the bubble.
    #expect(message.content.text == "what is this")
}

@Test func faviconsAreFoundWhereSitesActuallyPutThem() {
    // `/favicon.ico` is the guess and usually the wrong one; the real location
    // is a link tag in the head, sometimes relative, sometimes protocol-relative.
    let html = """
        <html><head>
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" type="image/png" href="/static/fav.png">
        <link rel="shortcut icon" href="//cdn.example.com/i.ico">
        <link rel="stylesheet" href="/style.css">
        </head><body>hi</body></html>
        """
    let links = FaviconCache.iconLinks(in: html, base: "https://example.com")
    #expect(links.contains("https://example.com/static/fav.png"))
    #expect(links.contains("https://cdn.example.com/i.ico"))
    #expect(!links.contains("https://example.com/style.css"))
}

// A rejected ask_user does not fail the request; the server writes its complaint
// into the call's output and carries on. Every one of these was visible on a
// real chat as a green tick next to the sentence saying it had failed.
@Test func toolOutputThatIsAnErrorIsNotAnAnswer() {
    func call(_ output: String) -> ToolCall? {
        ToolCall(.object([
            "type": .string("function_call_output"),
            "call_id": .string("c1"), "name": .string("ask_user"),
            "status": .string("completed"),
            "output": .array([.object(["type": .string("input_text"),
                                       "text": .string(output)])]),
        ]))
    }
    guard let plain = call("Error: Each question requires 2-3 options.") else {
        Issue.record("call should parse"); return
    }
    #expect(plain.failureText == "Each question requires 2-3 options.")
    #expect(plain.answerSummary == nil, "the error must not be presented as the user's choice")

    guard let answered = call(#"{"status":"answered","answers":{"q1":"Pizza"}}"#) else {
        Issue.record("call should parse"); return
    }
    #expect(answered.failureText == nil)
    #expect(answered.answerSummary == "Pizza")

    guard let structured = call(#"{"error":"Tool not available"}"#) else {
        Issue.record("call should parse"); return
    }
    #expect(structured.failureText == "Tool not available")
}

@Test func foldingAnErrorOutputMarksTheCallFailed() {
    let items: [JSONValue] = [
        .object(["type": .string("function_call"), "call_id": .string("c1"),
                 "name": .string("ask_user"), "status": .string("pending")]),
        .object(["type": .string("function_call_output"), "call_id": .string("c1"),
                 "name": .string("ask_user"), "status": .string("completed"),
                 "output": .array([.object(["type": .string("input_text"),
                                            "text": .string("Error: nope")])])]),
    ]
    let calls = ToolCall.calls(from: items)
    #expect(calls.count == 1, "a call and its output are one row, not two")
    #expect(calls[0].status == .failed)
    #expect(calls[0].isSettled)
}

// A finished message must never leave a question on screen. The bug this pins:
// a card reading "The model is asking a question" with no question, an empty
// field and a Send button that could not be pressed — below an answer that had
// already printed. A dead end the user cannot leave, on a turn that was over.
@Test func aFinishedMessageIsNeverWaitingOnTheUser() {
    let pending = ToolCall(.object([
        "type": .string("function_call"), "call_id": .string("c9"),
        "name": .string("ask_user"), "status": .string("pending"),
    ]))
    #expect(pending?.isAwaitingUser == true)

    #expect(Turn.reconciling([pending!], done: false).first?.isAwaitingUser == true,
            "while the run is live the question has to stay up")
    let settled = Turn.reconciling([pending!], done: true).first
    #expect(settled?.isAwaitingUser == false)
    #expect(settled?.isSettled == true)
}

// The model streams tool arguments as text, so the JSON is truncated for a
// moment. That is "not yet", not "unrecognisable", and the two need different
// screens — the old one was a box with no question and a Send button that could
// not be pressed, on a call that had three real questions arriving.
@Test func halfArrivedArgumentsAreNotAnUnrecognisedQuestion() {
    func call(_ arguments: String) -> ToolCall {
        ToolCall(.object([
            "type": .string("function_call"), "call_id": .string("c1"),
            "name": .string("ask_user"), "status": .string("pending"),
            "arguments": .string(arguments),
        ]))!
    }
    #expect(call(#"{"questions":[{"id":"a","question":"A?"}]"#).hasStructuredArguments == false,
            "truncated JSON must read as still-arriving")
    #expect(call(#"{"questions":[{"id":"a","question":"A?"}]}"#).hasStructuredArguments == true)
    #expect(call(#"{"nonsense":true}"#).hasStructuredArguments == true,
            "parsed but unrecognised is the case that gets the free-text fallback")
}
