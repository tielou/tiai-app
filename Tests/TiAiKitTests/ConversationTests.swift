import Foundation
import Testing

@testable import TiAiKit

private typealias Frame = ChatEventSocket.Frame

/// The conversation state machine, driven by a scripted transport and frames fed
/// into the hub by hand — no network, and no waiting on a model.
///
/// The sequence the server requires: no chat id on a first message (that is how
/// it knows to name the chat), the assistant message id, reading the socket while
/// the POST is still open, and treating `finish_reason` as the end.
@Test @MainActor func aFirstMessageLetsTheServerCreateAndNameTheChat() async throws {
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
    // No /chats/new. Pre-creating the chat made the server treat it as an
    // existing one, which is the gate that switches title generation off.
    #expect(!transport.paths.contains("/api/v1/chats/new"), "the server creates the chat")

    let completion = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: completion) as? [String: Any])
    // Without this id the server writes nothing to the transcript, and the
    // answer arrives and then never happened.
    let assistantID = try #require(json["id"] as? String)
    #expect(!assistantID.isEmpty)
    #expect(json["chat_id"] == nil, "absent, not null — that is what says 'new chat'")
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

/// Regression for the flaky stop race (issue #3).
///
/// `finishLocally` used to set `phase = .ready` while the streamed deltas were
/// still only in the drain buffer (`pending`); the buffer reached `turns` only
/// via the 60 ms flusher or drain's final flush, and under parallel-suite load
/// an observer of the first `.ready` could land in between and read the empty
/// placeholder turn. Two gates make that window the whole point of the test:
/// the stop POST is held so `finishLocally` cannot run early (when it wins
/// that race on its own the terminal frame is dropped and the bug hides), and
/// drain is then parked inside the `GET /chats/{id}` that `serverStillOpen`
/// does for the finish frame. Only then is the stop POST let through:
/// `finishLocally` declares `.ready` while drain — and with it the final flush
/// — is provably still stuck mid-round-trip, so whatever `turns` holds at the
/// first `.ready` is exactly what `.ready` is promising. The flusher is put
/// far out of reach (`flushInterval = .seconds(30)`) so it can never tick
/// during the test: the only thing allowed to publish the buffer at `.ready`
/// is `finishLocally` itself.
@Test @MainActor func stopPublishesTheBufferedTextBeforeDeclaringReady() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    // Longer than the whole test: a 60 ms flusher ticking under parallel load
    // would publish "1 2 3" on its own and let the buggy code pass by luck.

    conversation.flushInterval = .seconds(30)
    conversation.draft = "count to a hundred"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: assistantID,
                               inner: ["type": "response.output_text.delta", "delta": "1 2 3"]))

    // Hold the stop POST so `finishLocally` runs only when the test says so,
    // and park the chat fetch the finish frame triggers inside
    // `serverStillOpen`. Both waits are continuations, not sleeps, on
    // purpose: `finishLocally` cancels the run's Task, and a cancellable
    // wait would wake at once, let drain run its final flush, and hide the
    // very window this test exists to expose.
    transport.gateNextStop()
    transport.gateNextChatFetch()
    // Release on the way out no matter how the test ends: a failed #expect
    // must not leave a parked request (and its continuation) hanging the
    // suite.
    defer { transport.releaseStopGate(); transport.releaseChatFetchGate() }

    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { transport.paths.contains("/api/tasks/chat/chat-1/stop") }
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    // Drain has now taken the finish frame and is suspended in its
    // "is the server still open?" fetch — the buffer cannot be published
    // from here any more than the flusher's next tick.
    try await waitUntil { transport.isChatFetchGateParked }

    // Let the stop POST land: `finishLocally` now cancels the run, expires
    // the stream and declares `.ready` — while drain is still parked.
    transport.releaseStopGate()

    // Capture the text in the same main-actor hop as the first observation of
    // `.ready`, so the assertion measures what `.ready` implies rather than
    // whatever a later poll happens to see.
    var textAtFirstReady: String?
    try await waitUntil {
        guard conversation.phase == .ready else { return false }
        textAtFirstReady = conversation.turns.last?.text
        return true
    }
    // `.ready` must mean "the buffer is published": anything that reacts to
    // the first `.ready` — the UI, or this test — reads `turns`, and it must
    // not find the empty placeholder there.
    #expect(textAtFirstReady == "1 2 3")

    // The snapshot alone is not enough: drain is still parked, and its final
    // flush lands *after* `.ready`. Let it run and re-check the settled state
    // — a `pending = nil` in `finishLocally` would pass the snapshot above and
    // then flush an empty Turn over it here. Releasing the gate is idempotent;
    // the `defer` stays as the safety net for a failed #expect above.
    transport.releaseChatFetchGate()
    // The third GET /chats/{id} is the proof drain is on its way out: the
    // fixture never stores the message, so `serverStillOpen` burns all three
    // of its attempts (the parked one was the first; the cancelled run makes
    // the inter-attempt sleeps throw instantly). After the third response,
    // break → final flush is one main-actor hop away — the short settle below
    // gives it room to land before the re-check.
    try await waitUntil(timeout: .seconds(5)) {
        transport.paths.filter { $0 == "/api/v1/chats/chat-1" }.count >= 3
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(conversation.turns.last?.text == "1 2 3")
    #expect(conversation.turns.last?.streaming == false)
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

/// Thrown by `ScriptedTransport` when `failUploads` is set.
struct UploadFailure: Error {}

/// A transport that records the calls and answers well enough for a run to
/// proceed: chat creation succeeds, the completion body stays open (as it does
/// for real), and stop returns 200.
final class ScriptedTransport: APITransport, @unchecked Sendable {
    // `@unchecked Sendable` is a promise, not a guarantee, and this class was
    // breaking it: the transport is written from the model's Task and read from
    // the test's main actor, so the arrays were being appended on one thread
    // while a test polled them on another. That is a data race, and it showed up
    // the way data races do — an intermittent SIGSEGV/SIGABRT in the test
    // process rather than a failed assertion, in whichever two long-running
    // tests happened to overlap. Everything mutable goes through the lock.
    private let lock = NSLock()
    private func guarded<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    private var _paths: [String] = []
    private var _completionBodies: [Data] = []
    private var _uploads: [Data] = []
    private var _resolveBodies: [Data] = []
    private var _messageUpdateBodies: [Data] = []
    private var _chatDetailOverride: Data?
    private var _chatDetailQueue: [Data] = []
    private var _failUploads = false
    private var _completionFailure: Error?

    /// When set, the completion POST throws this instead of returning the
    /// never-ending stream — the failed-POST path of issue #9. Settable so a
    /// test can arm the failure at a chosen moment (mid-stream, parked, stop).
    var completionFailure: Error? {
        get { guarded { _completionFailure } }
        set { guarded { _completionFailure = newValue } }
    }

    /// When set, POST /files throws — the failed-upload path. Settable so a
    /// test can let the first upload land and fail the second.
    var failUploads: Bool {
        get { guarded { _failUploads } }
        set { guarded { _failUploads = newValue } }
    }

    var paths: [String] { guarded { _paths } }
    var completionBodies: [Data] { guarded { _completionBodies } }
    var uploads: [Data] { guarded { _uploads } }
    var resolveBodies: [Data] { guarded { _resolveBodies } }
    /// Bodies of POST /chats/{id}/messages/{id} — the `updateMessage` (edit) calls.
    var messageUpdateBodies: [Data] { guarded { _messageUpdateBodies } }
    var completionBody: Data? { guarded { _completionBodies.last } }

    /// Replaces what GET /chats/{id} returns, for tests that need a real tree.
    var chatDetailOverride: Data? {
        get { guarded { _chatDetailOverride } }
        set { guarded { _chatDetailOverride = newValue } }
    }
    /// Successive answers for GET /chats/{id}, for tests where the point is that
    /// the server's answer *changes* between reads.
    var chatDetailQueue: [Data] {
        get { guarded { _chatDetailQueue } }
        set { guarded { _chatDetailQueue = newValue } }
    }
    private func nextQueuedChatDetail() -> Data? {
        guarded { _chatDetailQueue.isEmpty ? nil : _chatDetailQueue.removeFirst() }
    }

    // MARK: - request gates
    //
    // Let a test park a request inside the transport at a chosen point — for
    // instance drain's `serverStillOpen` fetch, which is where a stop races
    // the finish frame. The wait is a `CheckedContinuation`, not a
    // `Task.sleep`, deliberately: `finishLocally` cancels the run's Task, and
    // a cancellable sleep would wake at once (the `try?` at those call sites
    // swallows it), drain would final-flush, and the race the gates exist to
    // expose would be papered over.
    private let chatFetchGate = OneShotGate()
    private let stopGate = OneShotGate()
    private let completionGate = OneShotGate()
    private let resolveGate = OneShotGate()
    private let messageUpdateGate = OneShotGate()

    /// Makes the *next* GET /chats/{id} wait until `releaseChatFetchGate()`.
    func gateNextChatFetch() { chatFetchGate.arm() }
    /// True while a chat fetch is parked at the gate.
    var isChatFetchGateParked: Bool { chatFetchGate.isParked }
    /// Resumes the parked chat fetch (and disarms an unused gate).
    /// Safe to call any number of times, from anywhere.
    func releaseChatFetchGate() { chatFetchGate.release() }

    /// Makes the *next* POST …/stop wait until `releaseStopGate()`.
    func gateNextStop() { stopGate.arm() }
    /// Resumes the parked stop request (and disarms an unused gate).
    func releaseStopGate() { stopGate.release() }

    /// Makes the *next* completion POST wait inside the transport until
    /// `releaseCompletion()` — so a test can hold the POST open while it puts
    /// the run into a chosen state (streaming, parked, stopping) and only then
    /// let the POST fail there.
    func gateNextCompletion() { completionGate.arm() }
    /// True while a completion POST is parked at the gate.
    var isCompletionGateParked: Bool { completionGate.isParked }
    /// Resumes the parked completion POST (and disarms an unused gate).
    func releaseCompletion() { completionGate.release() }

    /// Makes the *next* POST …/resolve wait inside the transport until
    /// `releaseResolve()` — so a test can hold a tool-answer resume open while
    /// it abandons the run, and only then let the resolve land (issue #12).
    func gateNextResolve() { resolveGate.arm() }
    /// True while a resolve POST is parked at the gate.
    var isResolveGateParked: Bool { resolveGate.isParked }
    /// Resumes the parked resolve POST (and disarms an unused gate).
    func releaseResolve() { resolveGate.release() }

    /// Makes the *next* POST /chats/{id}/messages/{id} — the edit's
    /// `updateMessage` — wait inside the transport until
    /// `releaseMessageUpdateGate()`, so a test can hold the edit open across
    /// the window the model must stay busy in (issue #13).
    func gateNextMessageUpdate() { messageUpdateGate.arm() }
    /// True while a message-update POST is parked at the gate.
    var isMessageUpdateGateParked: Bool { messageUpdateGate.isParked }
    /// Resumes the parked message-update POST (and disarms an unused gate).
    func releaseMessageUpdateGate() { messageUpdateGate.release() }

    /// A one-shot gate: `arm()` makes the next `parkIfArmed()` wait until
    /// `release()`. Cancelling the waiting task does not wake it — see the
    /// comment on the gates above for why that is the whole point.
    fileprivate final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func arm() {
            lock.lock(); armed = true; lock.unlock()
        }

        func parkIfArmed() async {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                // Consume the arm and register the waiter in one atomic step,
                // and resume on the spot when no gate is armed — so un-gated
                // requests pay only the lock they already paid.
                lock.lock()
                if armed {
                    armed = false
                    waiters.append(resume)
                    lock.unlock()
                } else {
                    lock.unlock()
                    resume.resume()
                }
            }
        }

        var isParked: Bool {
            lock.lock(); defer { lock.unlock() }
            return !waiters.isEmpty
        }

        func release() {
            lock.lock()
            armed = false
            let parked = waiters
            waiters = []
            lock.unlock()
            for waiter in parked { waiter.resume() }
        }
    }

    var chatDetail: Data {
        Data(
            """
            {"id":"chat-1","title":"New Chat","updated_at":1,"created_at":1,
             "chat":{"models":["local-personal"],"history":{"currentId":null,"messages":{}}}}
            """.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        guarded { _paths.append(path) }
        if path.hasSuffix("/chats/new") { return (chatDetailOverride ?? chatDetail, response(for: request, 200)) }
        if request.httpMethod == "GET", path.hasPrefix("/api/v1/chats/"),
           !path.hasSuffix("/messages") {
            await chatFetchGate.parkIfArmed()
            if let queued = nextQueuedChatDetail() {
                return (queued, response(for: request, 200))
            }
            return (chatDetailOverride ?? chatDetail, response(for: request, 200))
        }
        if path.hasSuffix("/stop") {
            await stopGate.parkIfArmed()
            return (Data("{}".utf8), response(for: request, 200))
        }
        if path.hasSuffix("/resolve") {
            // Park before recording, so `resolveBodies` only grows once the
            // test has let the request through — the same contract the other
            // gates keep.
            await resolveGate.parkIfArmed()
            guarded { _resolveBodies.append(request.httpBody ?? Data()) }
            return (Data(#"{"status":true}"#.utf8), response(for: request, 200))
        }
        if request.httpMethod == "POST", path.contains("/messages/") {
            // Park before recording, so `messageUpdateBodies` only grows once
            // the test has let the request through — the same contract the
            // other gates keep.
            await messageUpdateGate.parkIfArmed()
            guarded { _messageUpdateBodies.append(request.httpBody ?? Data()) }
            return (Data("{}".utf8), response(for: request, 200))
        }
        if path.hasSuffix("/files") || path.hasSuffix("/files/") {
            if failUploads { throw UploadFailure() }
            guarded { _uploads.append(request.httpBody ?? Data()) }
            return (Data(#"{"id":"file-1","filename":"notes.txt","type":"text/plain","updated_at":1}"#.utf8),
                    response(for: request, 200))
        }
        return (Data("{}".utf8), response(for: request, 200))
    }

    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        guarded {
            _paths.append(path)
            _completionBodies.append(request.httpBody ?? Data())
        }
        // Park first (issue #9 tests: the failure must land at a chosen point
        // of the run, not the instant the POST goes out), then fail if armed.
        await completionGate.parkIfArmed()
        if let failure = guarded { _completionFailure } { throw failure }
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
}

// The explicit-blind half of the old picture test, split out with a new
// contract: a model that has *said* it cannot see images (`vision: false` in a
// non-empty capability map) used to get the picture silently stripped from the
// persisted message. Silent loss is not an option — the send is refused out
// loud and nothing is consumed.
@Test @MainActor func aBlindModelIsRefusedThePictureItCannotSee() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-deep", caps: ["vision": false])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { conversation.attachments.count == 1 }
    conversation.draft = "and this?"
    conversation.send()
    // Give a wrongly-started run a chance to put anything on the wire.
    try await Task.sleep(for: .milliseconds(300))

    #expect(transport.completionBodies.isEmpty, "a refused send must not reach the server")
    #expect(conversation.phase == .ready)
    // Nothing was consumed: the user can pick a vision model and press send
    // again with everything still in the composer.
    #expect(conversation.draft == "and this?")
    #expect(conversation.attachments.count == 1)
    let message = try #require(conversation.error)
    #expect(message.contains("can't see images"), "\(message)")
}

// The screenshot regression: a model with *no* capability metadata is not a
// blind model. The old `?? false` treated "the server didn't say" as "it can't
// see", dropped the image blocks from the persisted message, and the photo
// vanished with no error anywhere. Empty capabilities means unknown — fail
// open, same idiom as `ChatModel.supports(_ feature:)`.
@Test @MainActor func aModelWithNoCapabilityMetadataStillGetsThePicture() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-quick", caps: [:])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { conversation.attachments.count == 1 }
    conversation.draft = "what is in this?"
    conversation.send()
    try await transport.awaitCompletion()

    let raw = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let user = try #require(messages.last { ($0["role"] as? String) == "user" })
    let blocks = try #require(user["content"] as? [[String: Any]],
                              "an unknown model gets the picture, not a text-only message")
    #expect(blocks.contains { ($0["type"] as? String) == "image_url" })
}

// The selected model id can be absent from `models` entirely — the list may
// not be loaded yet, or the id came from somewhere the picker never saw.
// Unknown is not blind.
@Test @MainActor func aModelTheAppHasNoMetadataForStillGetsThePicture() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.model = "mystery-model"
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
    #expect(blocks.contains { ($0["type"] as? String) == "image_url" })
}

// The id actually sent is often the one the server reported for the chat
// (`apply` takes `detail.models.first`), which may name a model the app's
// model list does not contain. That must not silently drop the picture either.
@Test @MainActor func aServerReportedModelMissingFromTheListStillGetsThePicture() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-vision-unknown","title":"T","updated_at":1,"created_at":1,
         "chat":{"models":["some-unknown"],"history":{"currentId":null,"messages":{}}}}
        """.utf8)
    let conversation = ConversationModel(
        chatID: "chat-vision-unknown",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    await conversation.load()
    // The server's answer won, and the app has no metadata for it.
    #expect(conversation.model == "some-unknown")

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
    #expect(blocks.contains { ($0["type"] as? String) == "image_url" })
}

// A failed upload never lands in `attachments`, so a send that carried on
// would ship a silently reduced set — the misrouted-pictures bug's second
// path. The send has to abort, put the draft back, and say so.
@Test @MainActor func aSendAbortsWhenAnUploadFailed() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.draft = "what is in this?"
    transport.failUploads = true
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { !conversation.uploading && conversation.error != nil }

    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    #expect(transport.completionBodies.isEmpty, "a send with a failed upload must not post")
    #expect(conversation.phase == .ready)
    #expect(conversation.draft == "what is in this?", "the draft comes back, not into the void")
    // The failed photo never landed, so there is no chip to "remove" — the
    // message has to name the actual choice: press again without it, or
    // re-attach.
    let message = try #require(conversation.error)
    #expect(message.contains("previous upload failed"), "\(message)")
    #expect(message.contains("press send again"), "\(message)")

    // A second send proceeds: the abort cleared the checkpoint, so one old
    // failure cannot block the chat forever. The user has been told once.
    conversation.send()
    try await transport.awaitCompletion()
}

// The multi-photo partial: one upload lands, one fails, and the message must
// not go out with just the lucky photo.
@Test @MainActor func oneFailedUploadAmongTwoPhotosAbortsTheWholeSend() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "a.jpg", mimeType: "image/jpeg")
    try await waitUntil { conversation.attachments.count == 1 }
    transport.failUploads = true
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "b.jpg", mimeType: "image/jpeg")
    try await waitUntil { !conversation.uploading }

    conversation.draft = "two photos"
    conversation.send()
    try await Task.sleep(for: .milliseconds(300))
    #expect(transport.completionBodies.isEmpty, "the landed photo must not go out alone")
    #expect(conversation.phase == .ready)
    #expect(conversation.attachments.count == 1, "the landed attachment is kept for a retry")
    #expect(conversation.draft == "two photos")
    // A chip *is* on screen here, so the fix names it — unlike the no-
    // attachment abort, where there is nothing to remove.
    let message = try #require(conversation.error)
    #expect(message.contains("Remove the failed attachment"), "\(message)")
}

// A /files POST that never answers — a transport ignoring the upload client's
// own 120s URLSession timeout — must not pin the send in `.waiting` with the
// draft already consumed. The wait is bounded; on timeout the send aborts in
// the same shape as the #6 upload-failure abort: draft back, error out loud,
// nothing posted.
@Test @MainActor func aHungUploadTimesOutAndRestoresTheSend() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = HangingTransport(hangUploads: true)
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    // Production waits 120s (the URLSession backstop); the test shrinks the
    // knob rather than sitting out two minutes.
    conversation.uploadWaitLimit = .milliseconds(150)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    // The upload never answers: still "uploading", no chip landed.
    try await Task.sleep(for: .milliseconds(50))
    #expect(conversation.uploading)
    #expect(conversation.attachments.isEmpty)

    conversation.draft = "hello"
    conversation.send()
    // The bounded wait fires in ~150ms. Without the bound this never arrives
    // and waitUntil throws — that is the regression this pins.
    try await waitUntil(timeout: .seconds(2)) { conversation.phase == .ready }

    #expect(conversation.draft == "hello", "the draft comes back, not into the void")
    let message = try #require(conversation.error)
    #expect(message.contains("too long"), "\(message)")
    #expect(conversation.turns.isEmpty, "no phantom user turn for a send that never posted")
    #expect(transport.completionBodies.isEmpty, "a timed-out send must not post")
    // The hung upload is deliberately NOT cancelled — the spinner stays on
    // and a late success would re-add the chip for a resend. This pins that
    // decision so a future "cleanup" cannot silently flip it.
    #expect(conversation.uploading, "the timed-out upload is left running, not faked as failed")

    // Second send with the same hung transport: the timed-out upload was
    // deliberately NOT cancelled and is no longer in `pendingUploads`, so
    // the second send does not wait for it — it proceeds with the text
    // alone (observed: it posts immediately; a late upload success would
    // re-add the chip for a third press). The requirement is that the chat
    // is not wedged, and it isn't.
    conversation.send()
    try await waitUntil(timeout: .seconds(2)) { !transport.completionBodies.isEmpty }
    #expect(conversation.phase.isBusy, "the second send is a live run, not a stuck one")
    // "Proceeds text-only" made concrete: the second completion carries no
    // file payload and no image block — the hung upload is not half-sent.
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(!body.contains("shot.jpg"), "no file entry for the hung upload: \(body)")
    #expect(!body.contains("image_url"), "no image block for bytes that never uploaded: \(body)")
}

// A camera or fileImporter callback can land while a run is in flight; the
// pick must not be swept into whatever message sends next.
@Test @MainActor func attachIsRefusedWhileARunIsInFlight() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    // No terminal frame sent: the run is still open, the phase is busy.
    #expect(conversation.phase.isBusy)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "late.jpg", mimeType: "image/jpeg")
    #expect(conversation.error?.contains("Wait for the current answer") == true,
            "\(conversation.error ?? "nil")")
    #expect(transport.uploads.isEmpty, "the pick never went to the server")
    #expect(conversation.attachments.isEmpty)
}

// MARK: - userContent, directly

// The static function keeps its contract (refusal happens at send); these pin
// the block shapes, including the image-only message with no text.
@Test @MainActor func anImageOnlyMessageIsBlocksToo() {
    let shot = ConversationModel.PendingAttachment(
        id: "f-1", name: "shot.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
    guard case .blocks(let blocks) = ConversationModel.userContent(text: "", files: [shot], vision: true)
    else { Issue.record("empty text with an image is still a blocks message"); return }
    #expect(blocks.count == 1, "no empty text block alongside the picture")
    guard case .object(let block) = blocks.first else { Issue.record("expected an object block"); return }
    #expect(block["type"] == .string("image_url"))
}

@Test @MainActor func userContentWithoutVisionKeepsOnlyTheText() {
    let shot = ConversationModel.PendingAttachment(
        id: "f-1", name: "shot.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
    let content = ConversationModel.userContent(text: "hi", files: [shot], vision: false)
    #expect(content == .text("hi"))
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

/// Issue #12: `resolve()` spawns a bare Task that is not stored in `run`, so
/// neither stop nor abandon can cancel it — it has to police itself by
/// generation. Abandoning while the resolve POST is parked, then starting a
/// fresh send, must leave the new run completely untouched once the stale
/// resolve finally lands.
@Test @MainActor func abandoningDuringAParkedResolveLeavesTheNextRunClean() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    // Park a run on an ask_user question (same fixture as the parked tests).
    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }
    let call = try #require(conversation.turns.last?.awaitingCall)

    // Answer it, but hold the resolve POST inside the transport.
    transport.gateNextResolve()
    conversation.resolve(
        messageID: firstID, call: call, action: .answer,
        answers: .object(["meal": .string("pizza")]))
    try await waitUntil { transport.isResolveGateParked }
    #expect(conversation.phase == .streaming)

    // The app goes to the background: abandon bumps the generation, and the
    // parked resolve Task — untracked, uncancellable — is now superseded.
    conversation.abandon()
    #expect(conversation.phase == .ready)

    // A brand-new send starts while the resolve is still parked, and must
    // stream and finish as if the resolve had never existed.
    conversation.draft = "second question"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    #expect(secondID != firstID)

    // Let the stale resolve land. It belongs to a dead generation.
    transport.releaseResolve()
    // Give the released Task its scheduling hops so a stale implementation
    // has every chance to stomp before the new run's frames arrive.
    try await Task.sleep(for: .milliseconds(150))

    for frame in Frames.run(chat: "chat-1", message: secondID, answer: "No need for pizza.") {
        hub.receive(frame)
    }
    try await waitUntil { conversation.phase == .ready }

    // The new run streamed clean: its answer is on its own turn, nothing was
    // stamped over it, and the abandoned turn kept its own state.
    #expect(conversation.error == nil)
    #expect(conversation.turns.count == 4)  // user/assistant/user/assistant
    #expect(conversation.turns[3].text == "No need for pizza.")
    #expect(conversation.turns[3].streaming == false)
    #expect(conversation.turns[1].text != "No need for pizza.")

    // And nothing lands late: a stale resolve writing after the fact is the
    // bug under test, so the state has to still be clean a beat later.
    try await Task.sleep(for: .milliseconds(250))
    #expect(conversation.phase == .ready)
    #expect(conversation.error == nil)
    #expect(conversation.turns.count == 4)
    #expect(conversation.turns[3].text == "No need for pizza.")
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

/// Regression for issue #13: `edit()` must hold the model busy for the whole
/// `updateMessage` window. If it stays `.ready`, a send pressed while the
/// server rewrite is in flight is not refused: it bumps the generation, the
/// edit's exchange then arrives generation-stale and silently no-ops — the
/// branch already truncated locally, the message already rewritten server-side,
/// and no answer ever generated for either run.
@Test @MainActor func sendDuringAnInFlightEditIsRefused() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    // Same fixture as `editingAMessageStoresItAndReRunsFromIt`: the edited
    // message has to exist, so the conversation is loaded from a fixture.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-2","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1","assistant-2"]},
           "assistant-2":{"id":"assistant-2","role":"assistant","content":"second","parentId":"user-1"}}}}}
        """.utf8)
    await conversation.load()

    transport.gateNextMessageUpdate()
    conversation.edit(messageID: "user-1", text: "edited question")
    try await waitUntil { transport.isMessageUpdateGateParked }
    #expect(conversation.phase == .waiting,
            "the model must be busy while updateMessage is in flight")

    // A send pressed in that window must be refused — and refused the way
    // send() refuses everything else: before anything is touched.
    conversation.draft = "interloper"
    conversation.send()
    #expect(conversation.draft == "interloper", "a refused send must not consume the draft")
    #expect(conversation.error == nil, "refused before anything is touched — no banner either")
    #expect(transport.completionBodies.isEmpty, "the refused send must not start a completion")
    #expect(conversation.phase == .waiting, "the edit's run still owns the phase")

    // Let the edit's write land: its run must proceed, not silently drop.
    transport.releaseMessageUpdateGate()
    try await transport.awaitCompletion()
    #expect(transport.messageUpdateBodies.count == 1)
    let body = try #require(transport.completionBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["parent_id"] as? String == "user-1", "the completion is the edit's re-run")
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(userMessage["content"] as? String == "edited question")

    // And the run completes: the answer arrives, the phase returns to ready.
    let assistant = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistant, answer: "an answer") {
        hub.receive(frame)
    }
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.first?.text == "edited question")
    #expect(conversation.turns.last?.text == "an answer")
    #expect(!conversation.turns.contains { $0.text == "interloper" },
            "the refused send left no trace in the transcript")
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

// Incognito is Open WebUI's own feature, and its contract is read from the
// server's own bundle: a chat id of `temporary:<socket sid>` is never written to
// the database. These pin the two client-side promises that go with it.
@Test @MainActor func incognitoDoesNotSeedMemory() {
    let model = ChatModel.stub("local-personal", caps: ["web_search": true, "memory": true])
    #expect(model.supports(.memory))
    #expect(ConversationModel.seedFeatures(for: model).keys.contains(ChatFeature.memory.rawValue),
            "memory is on by default where the model supports it")
    #expect(!ConversationModel.seedFeatures(for: model, incognito: true)
        .keys.contains(ChatFeature.memory.rawValue),
        "a chat that is supposed to vanish must not leave memories behind")
}

/// The web UI leaves web search on for new chats, and that preference lives in
/// browser localStorage — there is nothing on the server to read (model
/// `default_feature_ids` is null, `/users/user/settings` returns only `ui`).
/// The capability is the only signal a client can see, so a model that advertises
/// search starts with it switched on.
@Test @MainActor func webSearchIsOnByDefaultWhereTheModelHasIt() {
    let searcher = ChatModel.stub("local-personal", caps: ["web_search": true])
    #expect(ConversationModel.seedFeatures(for: searcher)[ChatFeature.webSearch.rawValue] == true)

    let plain = ChatModel.stub("local-quick", caps: ["web_search": false])
    #expect(ConversationModel.seedFeatures(for: plain)[ChatFeature.webSearch.rawValue] != true,
            "a model that cannot search must not come with the toggle switched on")

    let incognito = ConversationModel.seedFeatures(for: searcher, incognito: true)
    #expect(incognito[ChatFeature.webSearch.rawValue] != true,
            "incognito should not be phoning a search engine")
}

@Test @MainActor func incognitoIsAChoiceOnlyAtTheStart() {    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    #expect(ConversationModel.canChangeIncognito(given: []))
    #expect(!ConversationModel.canChangeIncognito(given: [Turn(id: "u1", role: "user", text: "sent")]),
            "messages already on the server cannot be unsent by switching it on now")
    #expect(!ConversationModel.canChangeIncognito(
        given: [Turn(id: "a1", role: "assistant", text: "an answer")]),
        "a saved answer cannot be un-saved either")
    _ = server
}

// The model does not send a `recommended` flag; it writes "(recommended)" into
// the label, so the hint arrives as a parenthetical inside a place name. The
// web UI prints that verbatim.
@Test func recommendationHintIsReadOutOfTheLabel() {
    #expect(AskUserPrompt.splitRecommendation("Slovenia (recommended)") == ("Slovenia", true))
    #expect(AskUserPrompt.splitRecommendation("Crete (Recommended)") == ("Crete", true))
    #expect(AskUserPrompt.splitRecommendation("Alpine lakes — recommended") == ("Alpine lakes", true))
    #expect(AskUserPrompt.splitRecommendation("Transylvania") == ("Transylvania", false),
            "an ordinary label must come back untouched")
    #expect(AskUserPrompt.splitRecommendation("Best (recommended) overall")
        == ("Best (recommended) overall", false),
        "a parenthetical in the middle of a phrase is not a marker")
}

@Test func optionFromRealArgumentsCarriesTheRecommendation() {
    let prompt = AskUserPrompt(arguments: .object([
        "questions": .array([.object([
            "id": .string("dest"), "question": .string("Where?"),
            "options": .array([
                .object(["label": .string("Slovenia (recommended)"),
                         "description": .string("Alpine lakes")]),
                .object(["label": .string("Transylvania")]),
            ]),
        ])]),
    ]))
    let options = prompt?.questions.first?.options ?? []
    #expect(options.count == 2)
    #expect(options[0].label == "Slovenia", "the label should not still say (recommended)")
    #expect(options[0].recommended)
    #expect(options[1].recommended == false)
    // The value goes back to the tool, so it keeps the original text: the tool
    // matches on what it sent, not on what the badge made it look like.
    #expect(options[0].value == "Slovenia (recommended)")
}

// An upstream that drops mid-image and a run that actually failed look the same
// in one frame and completely different by the end. The user saw the first one
// rendered as the second: "empty reply from server" in a red banner, the spinner
// off, and the full answer waiting when they reopened the chat.
@Test @MainActor func anErrorFrameAlongsideAnAnswerIsNotAFailure() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "what is in this picture?"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["error": "Empty reply from server"]))
    for piece in ["A ", "screenshot ", "of ", "a router."] {
        hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: id, inner: [
            "choices": [["index": 0, "delta": ["content": piece]]],
        ]))
    }
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    // The app waits a few seconds after an errored "finish" to see if the run
    // resumes, because that is exactly what the server does here.
    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }

    #expect(conversation.turns.last?.text == "A screenshot of a router.")
    #expect(conversation.error == nil,
            "the answer arrived; the hiccup that produced it is not the user's problem")
}

@Test @MainActor func anErrorFrameWithNothingElseIsStillAnError() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "what is in this picture?"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["error": "Empty reply from server"]))
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }

    #expect(conversation.error == "Empty reply from server",
            "with no answer at all, the error is the only useful thing to say")
}

/// A finish frame is the app's guess about the end of a turn; the stored
/// message's `done` flag is the server's answer. On long runs with several tool
/// calls they disagree, and settling on the guess left the composer showing a
/// finished prompt over half an answer — which the user then saw complete itself
/// after leaving and re-entering the chat.
@Test @MainActor func aFinishFrameTheServerDisagreesWithIsNotTheEnd() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "look up three things and compare them"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    func stored(done: Bool, content: String) {
        transport.chatDetailOverride = Data("""
        {"id":"chat-1","title":"t","updated_at":1,"created_at":1,
         "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
           "\(id)":{"id":"\(id)","role":"assistant","content":"\(content)","model":"local-personal",
                    "done":\(done),"parentId":null,"childrenIds":[]}}}}}
        """.utf8)
    }

    stored(done: false, content: "half an answer")
    for piece in ["half ", "an ", "answer"] {
        hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: id, inner: [
            "choices": [["index": 0, "delta": ["content": piece]]],
        ]))
    }
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await Task.sleep(for: .milliseconds(500))
    #expect(conversation.phase.isBusy,
            "the server still has the message open, so a finish frame must not end the run")

    // The rest of the turn arrives under the same message id.
    stored(done: true, content: "half an answer, and the rest of it")
    for piece in [", and the rest of it"] {
        hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: id, inner: [
            "choices": [["index": 0, "delta": ["content": piece]]],
        ]))
    }
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }
    #expect(conversation.turns.last?.text == "half an answer, and the rest of it")
}

/// When the stream dies for good, the stored message is the only copy of the
/// tail. Adopting it is what turns the refetch from "the workaround the user
/// discovered" into a safety net.
@Test @MainActor func aStoredAnswerLongerThanTheStreamIsAdopted() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "long question"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    transport.chatDetailOverride = Data("""
    {"id":"chat-1","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "\(id)":{"id":"\(id)","role":"assistant","content":"the full answer, all of it",
                "model":"local-personal","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-1", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "the full an"]]],
    ]))
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-1", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }
    try await waitUntil(timeout: .seconds(4)) {
        conversation.turns.last?.text == "the full answer, all of it"
    }
}

// A long flight of newlines in a message renders as a tall empty column, which
// reads as the end of the chat and is the same habit the web renderer has.
@Test func runsOfBlankLinesCollapseToOne() {
    let source = "the answer\n\n\n\n\n\n\n\n\n\n\n\n\n\nis: train 09:42"
    let blocks = Markdown.blocks(source)
    #expect(blocks.count == 1, "one paragraph, not a column of air")
    guard case .prose(let text)? = blocks.first else {
        Issue.record("expected prose, got \(blocks)"); return
    }
    #expect(text == "the answer\n\nis: train 09:42")
}

@Test func leadingAndTrailingBlankLinesAreNotBlocksAtAll() {
    #expect(Markdown.blocks("\n\n\n\njust this\n\n\n").count == 1)
    #expect(Markdown.blocks("\n\n\n   \n\t\n").isEmpty, "a message of nothing stays invisible")
}

// Source code keeps its spacing. Collapsing there would corrupt the one place
// blank lines carry meaning.
@Test func blankLinesInsideACodeFenceSurvive() {
    let source = "```swift\nlet a = 1\n\n\nlet b = 2\n```"
    let blocks = Markdown.blocks(source)
    guard case .code(_, let code)? = blocks.first(where: {
        if case .code = $0 { return true }; return false
    }) else { Issue.record("expected a code block"); return }
    #expect(code == "let a = 1\n\n\nlet b = 2")
}

// The picker hands the bytes over immediately; the upload answers a moment
// later. Pressing send inside that gap used to produce a message with no photo
// and no error — the reported "image with the first message never reaches the
// backend". Send has to wait for what is still in flight.
@Test @MainActor func sendWaitsForAnUploadStillInFlight() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    // Deliberately no wait. The upload has been started and has not landed.
    #expect(conversation.attachments.isEmpty, "nothing has come back yet")
    #expect(conversation.uploading, "and the app knows it")

    conversation.draft = "what is in this?"
    conversation.send()
    try await transport.awaitCompletion()

    let raw = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let user = try #require(messages.last { ($0["role"] as? String) == "user" })
    let blocks = try #require(user["content"] as? [[String: Any]])
    #expect(blocks.contains { ($0["type"] as? String) == "image_url" },
            "the photo must be in the message that was sent")

    let files = try #require(json["files"] as? [Any])
    #expect(!files.isEmpty, "and in the files list the retrieval pipeline reads")
}

@Test @MainActor func sendIsAllowedWhileAnUploadIsInFlight() {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: ScriptedTransport()),
        hub: ChatEventHub(server: server))
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    // Disabled-while-uploading would read as a broken picker; the button stays
    // live and the send waits.
    #expect(conversation.canSend)
}

@Test func pipeTablesBecomeAGrid() {
    let source = """
    | Train | Departs | Platform |
    |---|:---:|---:|
    | RJ 612 | 09:42 | 3 |
    | RJ 814 | 10:12 | 1 |
    """
    let blocks = Markdown.blocks(source)
    guard case .table(let headers, let rows)? = blocks.first else {
        Issue.record("expected a table, got \(blocks)"); return
    }
    #expect(headers == ["Train", "Departs", "Platform"])
    #expect(rows.count == 2)
    #expect(rows[1] == ["RJ 814", "10:12", "1"])
}

// A line with a pipe in it is not a table. Without the separator requirement
// every `a | b` in prose would be drawn as a grid.
@Test func aLineWithAPipeIsNotATable() {
    let blocks = Markdown.blocks("either | or\nand then some prose")
    #expect(!blocks.contains { if case .table = $0 { return true }; return false })
}

@Test func horizontalRulesAreRules() {
    if case .rule? = Markdown.blocks("---").first {} else {
        Issue.record("expected a rule")
    }
    #expect(Markdown.blocks("wait-- hold on").first.map {
        if case .rule = $0 { return false }; return true
    } ?? false, "dashes inside a sentence stay prose")
}

@Test func spacedRulesAreRulesToo() {
    // `* * *` is the form models emit most often. It used to arrive as a bullet
    // reading "* *", because the bullet test ran first and only matched the
    // leading "* ".
    func isRule(_ text: String) -> Bool {
        Markdown.blocks(text).contains { if case .rule = $0 { return true }; return false }
    }
    for form in ["***", "* * *", "- - -", "___", "  ---  "] {
        #expect(isRule(form), "\(form) should be a rule")
    }
    // Emphasis is not a rule, and a bullet is still a bullet.
    #expect(!isRule("***bold***"))
    #expect(!isRule("* just a point"))
}

@Test func taskListItemsCarryTheirState() {
    let blocks = Markdown.blocks("- [ ] book the ticket\n- [x] pack the bag")
    let tasks = blocks.compactMap { if case .task(let done, let text) = $0 { (done, text) } else { nil } }
    #expect(tasks.count == 2)
    #expect(tasks[0] == (false, "book the ticket"))
    #expect(tasks[1] == (true, "pack the bag"))
}

// The server does not summarise a chat's title on its own — it does it because
// the completion asked. Omit `tasks` and the chat keeps the truncated first line,
// which is exactly what made app-created chats look different from browser ones.
@Test @MainActor func newChatAsksTheServerForAGeneratedTitle() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil, models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.draft = "which train goes to Salzburg"
    conversation.send()
    try await transport.awaitCompletion()

    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    // The key is the whole lesson: the server pops `background_tasks` and never
    // looks at a top-level `tasks`, so an ask filed under the wrong key is ignored
    // in complete silence.
    let tasks = try #require(json["background_tasks"] as? [String: Any],
                             "the server only reads `background_tasks`")
    // Truthy, not merely present: the server does `if tasks[TASKS.TITLE_GENERATION]:`
    // and `{}` is falsy in Python.
    #expect(tasks["title_generation"] as? Bool == true,
            "must be true, not just present: {} is falsy server-side")
    #expect(json["tasks"] == nil, "a stray `tasks` key is dead weight at best")
    // The other half of the contract: the server only honours the ask when it
    // reads the exchange as a new chat, which it decides from `parent_id` being
    // present and null with no `chat_id` at all. A pre-created chat, or a missing
    // `parent_id` key, and the title silently stays the placeholder.
    #expect(json["chat_id"] == nil, "a chat_id makes the server treat this as an existing chat")
    #expect(json.keys.contains("parent_id"), "parent_id must be present...")
    #expect(json["parent_id"] is NSNull, "...and null")
}

@Test @MainActor func anExistingChatDoesNotRegenerateItsTitle() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: ChatEventHub(server: server))
    conversation.draft = "and the return?"
    conversation.send()
    try await transport.awaitCompletion()

    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["tasks"] == nil, "a second message must not rename the chat")
}

// A chat the server creates has no id the app can subscribe with, so the listener
// has to adopt one from the traffic. Without this the first message of a new chat
// would stream into nowhere.
@Test @MainActor func aDroppedSocketEndsRunsSoTheyReconcile() async throws {
    // The bug this pins: the socket dies, and nothing told the hub — so a run sat
    // on a frame stream that would never see another frame, stuck on "streaming"
    // until the silence watchdog fired. The user's workaround was to leave the
    // chat and come back, which refetches.
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let stream = hub.frames(for: "c1")
    let collector = Task { () -> Int in
        var n = 0
        for await _ in stream { n += 1 }
        return n
    }
    try await Task.sleep(for: .milliseconds(20))
    for frame in Frames.run(chat: "c1", message: "m1", answer: "partial") { hub.receive(frame) }
    hub.expireAll()
    // The stream ends rather than hanging, which is what lets the run fall
    // through to reading the finished answer off the server record.
    #expect(await collector.value > 0)
}

@Test @MainActor func aWaitingListenerAdoptsTheChatItHearsFrom() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    var adopted: String?
    let stream = hub.framesAwaitingChatID { adopted = $0 }
    let collector = Task { () -> [String] in
        var kinds: [String] = []
        for await frame in stream { kinds.append(frame.kind) }
        return kinds
    }

    try await Task.sleep(for: .milliseconds(20))
    for frame in Frames.run(chat: "server-made", message: "m1", answer: "hi") {
        hub.receive(frame)
    }
    hub.expire(chatID: "server-made")
    let seen = await collector.value

    #expect(adopted == "server-made", "the listener learned which chat it belongs to")
    #expect(!seen.isEmpty, "and it received the frames")
}

// Frames for an unrelated chat must not be adopted, or a background update would
// capture the new conversation.
@Test @MainActor func aWaitingListenerIgnoresFramesWithoutAChat() throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    var adopted: String?
    _ = hub.framesAwaitingChatID { adopted = $0 }
    // A frame that cannot name its chat adopts nothing.
    let bare = Frame([
        "data": ["type": "chat:completion", "data": ["done": false]],
    ])
    hub.receive(try #require(bare))
    #expect(adopted == nil)
}

// Real payload from a run that paused on `ask_user` and never resumed. The web UI
// shows the question card; the app showed none. The questions are in the stored
// message's `output` array, so this pins whether the app can see them at all.
@Test func aPendingAskUserLoadedFromTheServerIsVisible() throws {
    let url = try #require(
        Bundle.module.url(forResource: "chat-pending-ask-user", withExtension: "json",
                          subdirectory: "Fixtures"))
    let detail = try JSONDecoder().decode(ChatDetail.self, from: Data(contentsOf: url))
    let assistant = detail.messages.values.first { $0.role == "assistant" }
    let message = try #require(assistant)

    #expect(message.done == false, "the server agrees the run is parked, not finished")
    let calls = message.toolCalls
    #expect(!calls.isEmpty, "the stored output array must yield the tool calls")
    let ask = calls.first { $0.isAskUser }
    let call = try #require(ask, "the pending ask_user must be recognised")
    #expect(call.isAwaitingUser, "and it must be offered to the user to answer")
}

/// Opening a chat the app had given up on used to show the truncated answer and
/// an unlocked composer, with the rest of the reply appearing only after another
/// leave-and-return. The stored message says `done: false`, and that is now
/// treated as "still running" rather than "finished, apparently".
@Test @MainActor func openingAChatTheServerStillHasOpenKeepsWatchingIt() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
            transport: transport),
        hub: hub)

    func stored(_ content: String, _ done: String) -> Data {
        let template = """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-1","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1"]},
           "assistant-1":{"id":"assistant-1","role":"assistant","content":"__TEXT__",
             "parentId":"user-1","done":__DONE__}}}}}
        """
        return Data(template.replacingOccurrences(of: "__TEXT__", with: content)
                             .replacingOccurrences(of: "__DONE__", with: done).utf8)
    }
    // First read: half an answer, still open. Second: the whole thing, closed.
    transport.chatDetailQueue = [stored("half an answ", "false"),
                                 stored("half an answer, finished.", "true")]
    await conversation.load()

    for _ in 0..<200 {
        if conversation.turns.last?.text == "half an answer, finished." { break }
        try await Task.sleep(for: .milliseconds(50))
    }

    #expect(conversation.turns.last?.text == "half an answer, finished.",
            "an answer the server is still writing must keep growing on screen")
    #expect(conversation.phase == .ready, "and the composer unlocks when it closes")
}

/// A chat abandoned server-side keeps `done: false` for ever. Watching that
/// forever would hang a spinner over a dead chat, so the loop gives up once the
/// answer stops growing — and leaves the partial answer on screen.
@Test @MainActor func aRunThatStoppedGrowingIsNotWatchedForever() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
            transport: transport),
        hub: hub)
    conversation.reconcileInterval = .milliseconds(1)
    conversation.reconcileStallLimit = 5

    let stuck = Data("""
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-1","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1"]},
           "assistant-1":{"id":"assistant-1","role":"assistant","content":"abandoned here",
             "parentId":"user-1","done":false}}}}}
        """.utf8)
    transport.chatDetailQueue = Array(repeating: stuck, count: 40)
    await conversation.load()

    for _ in 0..<200 {
        if conversation.phase == .ready { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(conversation.phase == .ready, "a dead run must not hold the composer hostage")
    #expect(conversation.turns.last?.text == "abandoned here", "and the partial answer stays")
}

/// The terminal sandbox is what makes the model able to hand you a file. Off, it
/// cannot write one — and the web UI has it on, so the app being off by default
/// would silently drop a whole class of answer.
@Test @MainActor func codeInterpreterStartsOnWhereTheModelHasIt() {
    let model = ChatModel.stub("local-personal",
                               caps: ["memory": true, "code_interpreter": true])
    let seeded = ConversationModel.seedFeatures(for: model)
    #expect(seeded["code_interpreter"] == true)
    #expect(seeded["memory"] == true)
}

/// A model that says it has no sandbox must not get a toggle that lies about it.
/// A model that said *nothing at all* is different and still gets one — see
/// `ChatModel.supports(_:)`: silence is not a refusal.
@Test @MainActor func codeInterpreterIsNotForcedOnForModelsThatRefuseIt() {
    let model = ChatModel.stub("local-fast",
                               caps: ["code_interpreter": false, "memory": false])
    let seeded = ConversationModel.seedFeatures(for: model)
    #expect(seeded["code_interpreter"] == nil)
    #expect(seeded["memory"] == nil)
}

/// `local-personal` reports `code_interpreter: false` and `terminal: true`, and
/// it is the model the web UI runs shell commands with. Gating the toggle on
/// `code_interpreter` alone told the user code execution was unavailable for a
/// model that had been using it all along.
@Test @MainActor func terminalCapabilityIsWhatOffersCodeExecution() {
    let model = ChatModel.stub(
        "local-personal",
        caps: ["terminal": true, "code_interpreter": false, "memory": true])
    #expect(model.supports(.codeInterpreter))
    #expect(ConversationModel.seedFeatures(for: model)[ChatFeature.codeInterpreter.rawValue] == true)
}

/// A model that reports neither flag gets no toggle.
@Test @MainActor func noTerminalMeansNoCodeExecutionToggle() {
    let model = ChatModel.stub("local-fast", caps: ["terminal": false, "code_interpreter": false])
    #expect(!model.supports(.codeInterpreter))
    #expect(ConversationModel.seedFeatures(for: model)[ChatFeature.codeInterpreter.rawValue] == nil)
}

// An empty answer used to get one message whatever happened, and the commonest
// cause — iOS killing the socket during a background sojourn while the server
// carries on writing — was reported as the server having failed.
@Test func anUnfinishedMessageIsNotBlamedOnTheServer() {
    #expect(ConversationModel.emptyAnswerFailure(reported: nil, serverStillWriting: true)
        .contains("connection dropped"),
        "our dead socket must not be reported as the server sending nothing")
    #expect(ConversationModel.emptyAnswerFailure(reported: nil, serverStillWriting: false)
        == "The server sent nothing.",
        "a message the server itself closed empty really is the server's fault")
    #expect(ConversationModel.emptyAnswerFailure(reported: "Empty reply from server",
                                                 serverStillWriting: true)
        == "Empty reply from server",
        "the server's own reason always wins over our guess")
}

// MARK: - regenerate/edit keep the pictures (issue #7)
//
// The completion handler *overwrites* the stored user message with whatever
// `user_message` and `files` the request carries. A regenerate or edit that
// resent `content: "text"` with `files: []` therefore did not merely fail to
// add a picture — it deleted the one that was stored, and every later request
// rebuilt a history without it.

/// A chat detail whose user message carries a `data:` image block in `content`
/// *and* a `files` entry — the shape the server actually stores for an
/// app-sent photo. (`imageChatDetail` in ImageBudgetTests has no `files`
/// entries, and the `files` half is where part of the bug lived.)
private func imageMessageChatDetail(chatID: String) -> Data {
    Data(
        """
        {"id":"\(chatID)","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-1","messages":{
           "user-1":{"id":"user-1","role":"user","done":true,"childrenIds":["assistant-1"],
             "content":[{"type":"text","text":"what is in this pic"},
                        {"type":"image_url","image_url":{"url":"data:image/png;base64,QUlE"}}],
             "files":[{"type":"file","id":"file-img","name":"shot.png",
                       "file":{"id":"file-img","filename":"shot.png",
                               "meta":{"name":"shot.png","content_type":"image/png"}}}]},
           "assistant-1":{"id":"assistant-1","role":"assistant","done":true,"parentId":"user-1",
                          "childrenIds":[],"content":"a cat"}}}}}
        """.utf8)
}

/// Simulates the server's overwrite semantics.
///
/// The completion handler stores the user message from `user_message` plus the
/// top-level `files`, replacing the stored row wholesale. Asserting only the
/// outgoing body proves the request; decoding what the server would have
/// *stored* from that body is what proves the acceptance criterion — the
/// stored record still carries the image.
private func storedUserMessage(id: String, content: Any?, files: Any?) throws -> ChatMessage {
    var record: [String: Any] = ["id": id, "role": "user", "content": content ?? ""]
    if let files { record["files"] = files }
    return try JSONDecoder().decode(
        ChatMessage.self, from: JSONSerialization.data(withJSONObject: record))
}

/// The record as the server would store it after this completion request.
private func storedUserMessage(afterCompletionBody body: Data) throws -> ChatMessage {
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    return try storedUserMessage(
        id: try #require(userMessage["id"] as? String),
        content: userMessage["content"], files: json["files"])
}

/// The record as the server would store it after this updateMessage request.
private func storedUserMessage(afterUpdateBody body: Data, messageID: String) throws -> ChatMessage {
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try storedUserMessage(id: messageID, content: json["content"], files: json["files"])
}

private func imageURLs(inContent content: Any?) -> [String] {
    guard let blocks = content as? [[String: Any]] else { return [] }
    return blocks.compactMap { $0["image_url"] as? [String: Any] }.compactMap { $0["url"] as? String }
}

/// The acceptance assertion: what the server would store after this request
/// still knows about the image, in the content blocks and in the file list.
private func expectStoredImage(_ message: ChatMessage, _ source: String) {
    #expect(!message.contentImageURLs.isEmpty,
            "\(source): the stored user message lost its image block")
    #expect(message.messageAttachments.contains { $0.isImage },
            "\(source): the stored user message lost its image file")
}

/// (a) The primary repro: regenerate in-session, without a reload in between.
/// The carried turn is the one appended locally at send time — no stored
/// message was ever adopted (the adopt fetch finds nothing in the default
/// transport fixture), so the resend has to work from local state alone.
@Test @MainActor func regenerateResendsTheImagesOfTheMessageItReRuns() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-insession",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.png", mimeType: "image/png")
    try await waitUntil { conversation.attachments.count == 1 }
    conversation.draft = "what is in this pic"
    conversation.send()
    try await transport.awaitCompletion()
    let assistant = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-7-regen-insession", message: assistant, answer: "a cat") {
        hub.receive(frame)
    }
    try await waitUntil { conversation.phase == .ready }

    conversation.regenerate()
    try await transport.awaitCompletion(2)
    let body = try #require(transport.completionBodies.dropFirst().first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])

    let urls = imageURLs(inContent: userMessage["content"])
    #expect(urls.count == 1,
            "the regenerated user message must carry its image block, got: \(userMessage["content"] ?? "nil")")
    #expect(urls.first?.hasPrefix("data:image/png;base64,") == true,
            "the image is resent verbatim, not refetched or re-encoded: \(urls)")
    let blocks = try #require(userMessage["content"] as? [[String: Any]])
    #expect(blocks.contains { ($0["text"] as? String) == "what is in this pic" },
            "the edited-free text survives alongside the image")
    let files = try #require(json["files"] as? [[String: Any]],
                            "the file entry has to be resent or the server drops it")
    #expect(files.first?["id"] as? String == "file-1")

    expectStoredImage(try storedUserMessage(afterCompletionBody: body), "regenerate completion")
}

/// (b) Regenerate after the stream errored: the adopt that would copy the
/// stored message onto the turn is skipped for failed runs, so again only the
/// locally-appended turn's state is available to the resend.
@Test @MainActor func regenerateAfterAnErroredStreamStillResendsTheImages() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-errored",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.png", mimeType: "image/png")
    try await waitUntil { conversation.attachments.count == 1 }
    conversation.draft = "what is in this pic"
    conversation.send()
    try await transport.awaitCompletion()
    hub.expire(chatID: "chat-7-regen-errored")  // what the silence watchdog does
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.error != nil, "the errored run is what skips the adopt")

    conversation.regenerate()
    try await transport.awaitCompletion(2)
    let body = try #require(transport.completionBodies.dropFirst().first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(imageURLs(inContent: userMessage["content"]).count == 1,
            "a regenerate after a dead stream must still carry the image")
    expectStoredImage(try storedUserMessage(afterCompletionBody: body), "post-error regenerate")
}

/// (c) The resend is about the *stored* record, not this model's eyes: even a
/// model that explicitly reports `vision: false` must get the image back, or
/// regenerating under a blind model destroys a picture a sighted model will
/// later need. (The send path refuses blind models out loud; regenerate is
/// storage preservation, so it fails open.)
@Test @MainActor func regenerateWithABlindModelStillResendsTheStoredImages() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-blind",
        models: [ChatModel.stub("local-blind", caps: ["vision": false])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    transport.chatDetailOverride = imageMessageChatDetail(chatID: "chat-7-regen-blind")
    await conversation.load()
    #expect(conversation.turns.count == 2)

    conversation.regenerate()
    try await transport.awaitCompletion()
    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(imageURLs(inContent: userMessage["content"]) == ["data:image/png;base64,QUlE"],
            "the stored image block is passed through verbatim")
    // The `data:` pseudo-attachment Chat.swift synthesizes from the content
    // block is content-derived, not a file id — sending it under `files` is
    // garbage. Only the real file entry goes back.
    let files = try #require(json["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files.first?["id"] as? String == "file-img")
    expectStoredImage(try storedUserMessage(afterCompletionBody: body), "blind-model regenerate")
}

/// (d) Text-only regenerate must stay exactly what it was: a bare string, not
/// a one-block array.
@Test @MainActor func textOnlyRegenerateStaysPlainText() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-textonly",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)

    conversation.draft = "plain question"
    conversation.send()
    try await transport.awaitCompletion()
    let assistant = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-7-regen-textonly", message: assistant, answer: "plain answer") {
        hub.receive(frame)
    }
    try await waitUntil { conversation.phase == .ready }

    conversation.regenerate()
    try await transport.awaitCompletion(2)
    let body = try #require(transport.completionBodies.dropFirst().first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(userMessage["content"] as? String == "plain question",
            "a text-only regenerate stays a plain string, not an empty-blocks array")
    #expect(json["files"] == nil, "nothing to resend, nothing on the wire")
}

/// (e) Editing the text of an image-bearing message keeps the image in *both*
/// writes: the updateMessage POST (which overwrites the stored row) and the
/// completion's user_message.
@Test @MainActor func editKeepsTheImagesInTheStoredRecord() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-edit-images",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    transport.chatDetailOverride = imageMessageChatDetail(chatID: "chat-7-edit-images")
    await conversation.load()

    conversation.edit(messageID: "user-1", text: "actually: what breed is the cat")
    try await transport.awaitCompletion()

    // The updateMessage POST — this is the write that overwrote the picture.
    let update = try #require(transport.messageUpdateBodies.first)
    let updateJSON = try #require(JSONSerialization.jsonObject(with: update) as? [String: Any])
    #expect(imageURLs(inContent: updateJSON["content"]) == ["data:image/png;base64,QUlE"],
            "the updateMessage content must be multimodal or the stored row loses the image")
    let updateBlocks = try #require(updateJSON["content"] as? [[String: Any]])
    #expect(updateBlocks.contains { ($0["text"] as? String) == "actually: what breed is the cat" },
            "the new text is the text block")
    let updateFiles = try #require(updateJSON["files"] as? [[String: Any]])
    #expect(updateFiles.first?["id"] as? String == "file-img")
    expectStoredImage(
        try storedUserMessage(afterUpdateBody: update, messageID: "user-1"), "edit updateMessage")

    // The completion's user_message — the second overwrite vector.
    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(imageURLs(inContent: userMessage["content"]) == ["data:image/png;base64,QUlE"])
    expectStoredImage(try storedUserMessage(afterCompletionBody: body), "edit completion")

    // Locally only the text was replaced: the UI keeps showing the picture.
    let turn = try #require(conversation.turns.first)
    #expect(turn.text == "actually: what breed is the cat")
    #expect(!turn.contentImageURLs.isEmpty)
    #expect(turn.attachments.contains { $0.isImage })
}

/// (f) Failure-inertness: the updateMessage write happens first, and even when
/// the re-run afterwards fails, what the server stored from that write is
/// still multimodal — a failed regenerate must not be a way to lose pictures.
@Test @MainActor func editStoresTheImagesEvenWhenTheRerunFails() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-edit-fail",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    transport.chatDetailOverride = imageMessageChatDetail(chatID: "chat-7-edit-fail")
    await conversation.load()
    // The exchange refuses to run without a model — the failure after the write.
    conversation.model = ""

    conversation.edit(messageID: "user-1", text: "still a cat question")
    try await waitUntil { conversation.error != nil }

    #expect(transport.completionBodies.isEmpty, "the re-run failed before posting")
    #expect(conversation.phase == .ready, "a failed re-run must not wedge the composer busy")
    let update = try #require(transport.messageUpdateBodies.first)
    expectStoredImage(
        try storedUserMessage(afterUpdateBody: update, messageID: "user-1"),
        "edit whose re-run failed")
}

/// A chat detail whose user message carries an image file **and** a non-image
/// file (a PDF). The overwrite semantics do not care about the file type:
/// whatever the resend omits is what the server deletes.
private func mixedFilesChatDetail(chatID: String) -> Data {
    Data(
        """
        {"id":"\(chatID)","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-1","messages":{
           "user-1":{"id":"user-1","role":"user","done":true,"childrenIds":["assistant-1"],
             "content":[{"type":"text","text":"summarize the pdf with the chart"},
                        {"type":"image_url","image_url":{"url":"data:image/png;base64,QUlE"}}],
             "files":[
               {"type":"file","id":"file-shot","name":"chart.png",
                "file":{"id":"file-shot","filename":"chart.png",
                        "meta":{"name":"chart.png","content_type":"image/png"}}},
               {"type":"file","id":"file-report","name":"report.pdf",
                "file":{"id":"file-report","filename":"report.pdf",
                        "meta":{"name":"report.pdf","content_type":"application/pdf"}}}]},
           "assistant-1":{"id":"assistant-1","role":"assistant","done":true,"parentId":"user-1",
                          "childrenIds":[],"content":"here you go"}}}}}
        """.utf8)
}

/// (g) The resend is not image-only. A regenerate of a message that carries a
/// PDF alongside a picture must put *both* file entries back, or the server's
/// overwrite silently destroys the document.
@Test @MainActor func regenerateResendsNonImageAttachmentsToo() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-mixed",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    transport.chatDetailOverride = mixedFilesChatDetail(chatID: "chat-7-regen-mixed")
    await conversation.load()
    #expect(conversation.turns.count == 2)

    conversation.regenerate()
    try await transport.awaitCompletion()
    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let files = try #require(json["files"] as? [[String: Any]],
                            "the resend must carry every stored file, not just the images")
    #expect(Set(files.compactMap { $0["id"] as? String }) == ["file-shot", "file-report"],
            "the image and the PDF both survive the regenerate: \(files)")
    // The stored record after the server's overwrite still knows about both.
    let stored = try storedUserMessage(afterCompletionBody: body)
    expectStoredImage(stored, "mixed-file regenerate")
    #expect(stored.messageAttachments.contains { $0.name == "report.pdf" },
            "the PDF must survive the overwrite, not just the image")
}

/// A chat detail whose image block references the uploaded file by id
/// (`file_id://…`) instead of inlining the bytes — the other shape the server
/// stores for a picture.
private func fileIDImageChatDetail(chatID: String) -> Data {
    Data(
        """
        {"id":"\(chatID)","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-1","messages":{
           "user-1":{"id":"user-1","role":"user","done":true,"childrenIds":["assistant-1"],
             "content":[{"type":"text","text":"what is in this pic"},
                        {"type":"image_url","image_url":{"url":"file_id://file-shot"}}],
             "files":[{"type":"file","id":"file-shot","name":"shot.png",
                       "file":{"id":"file-shot","filename":"shot.png",
                               "meta":{"name":"shot.png","content_type":"image/png"}}}]},
           "assistant-1":{"id":"assistant-1","role":"assistant","done":true,"parentId":"user-1",
                          "childrenIds":[],"content":"a cat"}}}}}
        """.utf8)
}

/// (h) The `file_id://` scheme passes through verbatim — the resend neither
/// resolves the id nor rewrites the url — and the file entry's
/// `meta.content_type` round-trips from the stored record instead of being
/// guessed.
@Test @MainActor func regenerateResendsFileIDSchemeImageVerbatim() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-7-regen-fileid",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    transport.chatDetailOverride = fileIDImageChatDetail(chatID: "chat-7-regen-fileid")
    await conversation.load()
    #expect(conversation.turns.count == 2)

    conversation.regenerate()
    try await transport.awaitCompletion()
    let body = try #require(transport.completionBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let userMessage = try #require(json["user_message"] as? [String: Any])
    #expect(imageURLs(inContent: userMessage["content"]) == ["file_id://file-shot"],
            "the file_id:// url must be resent byte-for-byte")

    // The file entry keeps the stored mime; nothing is guessed from the name.
    let files = try #require(json["files"] as? [[String: Any]])
    #expect(files.count == 1)
    let entry = try #require(files.first)
    #expect(entry["id"] as? String == "file-shot")
    #expect(entry["name"] as? String == "shot.png")
    let inner = try #require(entry["file"] as? [String: Any])
    let meta = try #require(inner["meta"] as? [String: Any])
    #expect(meta["content_type"] as? String == "image/png",
            "the mime round-trips from the stored meta.content_type")

    let stored = try storedUserMessage(afterCompletionBody: body)
    #expect(stored.contentImageURLs == ["file_id://file-shot"])
    expectStoredImage(stored, "file_id:// regenerate")
}

// MARK: - issue #9: a POST that fails before the first frame rolls the send back
//
// The completion POST stays open for the whole generation, so "the POST threw"
// means different things at different moments. Before any frame it means the
// exchange never reached the server — the local user turn and the empty
// assistant placeholder are a fiction, and leaving them behind showed the user
// a question with a dead bubble under a self-clearing banner. The rollback:
// drop both turns, put the message and its attachments back in the composer,
// and leave a persistent, dismissible error. It must NOT fire on a stop, a
// mid-stream drop, or a parked run — each of those has its own story.

/// The shared setup: a conversation on a scripted transport whose completion
/// POST can be made to fail at a chosen moment.
@MainActor
private func makePostFailureFixture(chatID: String?) -> (
    ConversationModel, ScriptedTransport, ChatEventHub
) {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: chatID,
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    return (conversation, transport, hub)
}

@Test @MainActor func rollbackFiresOnNewChatPostFailure() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: nil)
    transport.completionFailure = APIError.unreachable("connection reset")

    conversation.draft = "hi"
    conversation.attach(
        data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { conversation.attachments.count == 1 }

    conversation.send()
    // This wait IS the regression. A new chat's `framesAwaitingChatID`
    // listener has chatID nil; the 60 s silence watchdog expires "" and never
    // matches it. Without `expireWaitingListeners` in `recordPostError` this
    // times out — the run hangs forever on a POST that already failed.
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.isEmpty,
            "a POST that never reached the server must not leave phantom turns behind")
    #expect(conversation.draft == "hi", "the failed message goes back in the composer")
    #expect(conversation.attachments.count == 1, "and so do its attachments")
    #expect(conversation.title == "New Chat",
            "a chat that was never created gets its pre-send name back")

    let error = try #require(conversation.error)
    #expect(error.contains("Could not send"), "\(error)")
    #expect(error.contains("connection reset"), "\(error)")
    #expect(error.contains("back in the composer"), "\(error)")
    // The drain's empty-answer guess ("The server sent nothing.") must not
    // overwrite the real cause after the fact either — the rollback returns
    // before that path runs.
    try await Task.sleep(for: .milliseconds(150))
    #expect(conversation.error == error)
}

@Test @MainActor func rollbackFiresOnExistingChatPostFailure() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    transport.completionFailure = APIError.http(status: 503, message: "server is restarting")

    conversation.draft = "hi"
    conversation.send()
    // The existing-chat regression: without the expire in `recordPostError`
    // the drain sits out the 60 s watchdog, then `emptyAnswerFailure` stamps
    // "The server sent nothing." over the true cause.
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.isEmpty)
    #expect(conversation.draft == "hi")
    let error = try #require(conversation.error)
    #expect(error.contains("Could not send"), "\(error)")
    #expect(error.contains("503"), "\(error)")
    try await Task.sleep(for: .milliseconds(150))
    #expect(conversation.error == error)
    #expect(conversation.error?.contains("The server sent nothing") == false)
}

@Test @MainActor func textOnlyRollbackAfterMidRunRetypeDoesNotClaimTheComposer() async throws {
    // The draft is editable mid-run. If the user typed while the POST was
    // in flight, the failed text is dropped (no-clobber wins) and a
    // text-only send has no attachments to put back — so the banner must
    // not claim anything came back.
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.draft = "the original message"
    conversation.send()
    try await transport.awaitCompletion()

    conversation.draft = "something typed while waiting"
    transport.completionFailure = APIError.http(status: 503, message: "server is restarting")
    transport.releaseCompletion()
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.isEmpty, "the phantom turns are still rolled back")
    #expect(conversation.draft == "something typed while waiting",
            "the re-typed text is never clobbered by the failed message")
    let error = try #require(conversation.error)
    #expect(error.contains("Could not send"), "\(error)")
    #expect(error.contains("back in the composer") == false,
            "nothing was actually restored — the banner must not claim it: \(error)")
    #expect(error.contains("Attachments are back") == false, "\(error)")
}

@Test @MainActor func stopDoesNotRollback() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()

    conversation.stop()
    #expect(conversation.phase == .stopping)
    // The POST dies *after* the stop — with a failure armed, so a rollback
    // that keyed only on "the POST failed" would fire here. It must not: a
    // stop is the user ending a real run, not a send that never happened.
    transport.completionFailure = APIError.unreachable("connection reset")
    transport.releaseCompletion()
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.count == 2, "the user turn and its answer survive a stop")
    #expect(conversation.draft.isEmpty, "nothing is put back in the composer")
}

@Test @MainActor func midStreamDropDoesNotRollback() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["type": "response.output_text.delta", "delta": "partial answer"]))
    try await waitUntil { conversation.phase == .streaming }

    transport.completionFailure = APIError.unreachable("connection reset")
    transport.releaseCompletion()
    // The drop that takes the POST down also takes the socket with it — in the
    // test the hub is the socket, so ending the listener is what simulates it.
    hub.expire(chatID: "chat-1")
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.count == 2, "a partial answer is the answer the user got")
    #expect(conversation.turns.last?.text == "partial answer")
    #expect(conversation.draft.isEmpty, "a mid-stream drop is not a send that never happened")
}

@Test @MainActor func parkedRunDoesNotRollback() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    // A delta-less `ask_user` frame parks the run: `phase` goes to `.ready`,
    // so `recordPostError`'s `isBusy` guard drops the late POST failure long
    // before the rollback gate is consulted. This test pins the parked-run
    // guard chain, NOT `sawAnyFrame` — the frame here would satisfy that
    // flag, but the flag is never reached. The gate itself is pinned by
    // `seenFrameBeforePostFailureDoesNotRollback`.
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.last?.awaitingCall?.name == "ask_user")

    transport.completionFailure = APIError.unreachable("connection reset")
    transport.releaseCompletion()
    // Give the POST's catch a chance to misfire into the rollback.
    try await Task.sleep(for: .milliseconds(150))

    #expect(conversation.turns.count == 2, "the parked question must survive")
    #expect(conversation.turns.last?.awaitingCall?.name == "ask_user")
    #expect(conversation.draft.isEmpty, "nothing is put back in the composer")
}

@Test @MainActor func seenFrameBeforePostFailureDoesNotRollback() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    // A bare ack-style opener: it carries *this* message's id — proof the
    // server heard the exchange — but it deltas no text and parks no call,
    // so the phase stays `.waiting`. This is the only state that reaches the
    // rollback gate with `sawAnyFrame` set: stop, mid-stream and parked are
    // each blocked by earlier guards. Delete `!outcome.sawAnyFrame` from the
    // gate and this is the test that goes red.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["id": "chatcmpl-1", "object": "chat.completion.chunk",
                "model": "local-personal",
                "choices": [["index": 0, "delta": ["content": "", "role": "assistant"]]]]))
    // Wait for the drain to have *consumed* the frame — proof it was seen,
    // not a sleep. The frame's model reaches the turn only through the
    // pending buffer the frame loop filled.
    try await waitUntil { conversation.turns.last?.model == "local-personal" }
    #expect(conversation.phase == .waiting,
            "an empty-content frame must not flip the run to .streaming — that is what makes this the sawAnyFrame test, not another mid-stream one")

    transport.completionFailure = APIError.unreachable("connection reset")
    transport.releaseCompletion()
    try await waitUntil { conversation.phase == .ready }

    // No rollback: a frame was seen, so the exchange reached the server and
    // the transcript is the truth. The drain's own no-answer verdict is fine
    // here; the rollback's "Could not send" framing would be a lie.
    #expect(conversation.turns.count == 2, "a seen frame means the server heard the send")
    #expect(conversation.turns.first?.text == "go")
    #expect(conversation.draft.isEmpty, "nothing is put back in the composer")
    #expect(conversation.error?.contains("Could not send") == false,
            "\(conversation.error ?? "nil")")
}

@Test @MainActor func unauthorizedPostFailureRollsBackWithSignedOut() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    transport.completionFailure = APIError.unauthorized

    conversation.draft = "hi"
    conversation.send()
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.isEmpty, "a 401 before any frame is still a send that never happened")
    #expect(conversation.draft == "hi")
    let error = try #require(conversation.error)
    #expect(error.contains("Signed out."), "\(error)")
    // "Could not send — Signed out." read wrong; the 401 stands alone,
    // unwrapped, with only the composer note appended.
    #expect(error.hasPrefix("Signed out."), "\(error)")
    #expect(!error.contains("Could not send"), "\(error)")
}

@Test @MainActor func regeneratePostFailureKeepsTurns() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let firstAssistant = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstAssistant,
        inner: ["type": "response.output_text.delta", "delta": "one"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstAssistant,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.turns.count == 2)

    // Now the regenerate's POST fails before any frame. The user turn it is
    // re-running is pre-existing transcript, not a phantom — the rollback must
    // keep its hands off it.
    transport.completionFailure = APIError.unreachable("connection reset")
    conversation.regenerate()
    try await waitUntil { conversation.phase == .ready }

    #expect(conversation.turns.count == 2, "the regenerate failure must not eat the user's message")
    #expect(conversation.turns.first?.isUser == true)
    #expect(conversation.turns.first?.text == "first")
    #expect(conversation.draft.isEmpty)
}

@Test @MainActor func dismissErrorClearsBanner() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    transport.completionFailure = APIError.unreachable("connection reset")

    conversation.draft = "hi"
    conversation.send()
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.error != nil)

    conversation.dismissError()
    #expect(conversation.error == nil)
    // And it stays gone — nothing about the rollback re-raises it.
    try await Task.sleep(for: .milliseconds(150))
    #expect(conversation.error == nil)
}

@Test @MainActor func abandonThenSendNotPoisoned() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    conversation.abandon()
    #expect(conversation.phase == .ready)
    // No settle sleep here any more (issue #11): `abandon` bumps the run
    // generation, so the cancelled run's exchange unwinds generation-aware and
    // is inert by construction — it cannot stamp its no-answer verdict on the
    // next run, and its cancelled POST cannot leave a failure flag behind. The
    // next send may start immediately.

    // An abandoned run cancels a still-open POST, and the cancellation lands as
    // a throw in its catch. If that throw records a failure, the flag poisons
    // the next run — which must roll back only a POST that really failed.
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: second,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: second,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.turns.last?.text == "two" && conversation.phase == .ready }

    #expect(conversation.error == nil,
            "the abandoned first run must not leak a failure into the second: \(conversation.error ?? "nil")")
    #expect(conversation.draft.isEmpty, "the second send went out; nothing was rolled back")
    #expect(conversation.turns.last?.text == "two")
}

// MARK: - issue #11 / #5: run generation

@Test @MainActor func abandonedRunUnwindDoesNotPoisonTheNextRun() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let first = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: first,
        inner: ["type": "response.output_text.delta", "delta": "one"]))

    // Park run 1's unwind inside drain's "is the server still open?" fetch —
    // the same idiom as `stopPublishesTheBufferedTextBeforeDeclaringReady`:
    // the gate is a continuation, so cancelling the run does not wake it, and
    // `isChatFetchGateParked` is proof of exactly where run 1 is suspended.
    transport.gateNextChatFetch()
    defer { transport.releaseChatFetchGate() }
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: first,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { transport.isChatFetchGateParked }

    // Abandon while run 1 is provably parked mid-unwind, then start run 2.
    conversation.abandon()
    #expect(conversation.phase == .ready)
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: second,
        inner: ["type": "response.output_text.delta", "delta": "two"]))

    // Let run 1's unwind run to completion. It must be inert: no phase write,
    // no error stamp, no cancel of run 2's POST slot.
    transport.releaseChatFetchGate()
    try await Task.sleep(for: .milliseconds(100))
    #expect(conversation.phase != .ready,
            "the abandoned run's unwind must not declare the newer run finished")
    #expect(conversation.error == nil,
            "the abandoned run's unwind must not stamp an error onto the newer run: \(conversation.error ?? "nil")")

    // Run 2 finishes normally, untouched by run 1's exit.
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: second,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) {
        conversation.turns.last?.text == "two" && conversation.phase == .ready
    }
    #expect(conversation.error == nil)
    #expect(conversation.draft.isEmpty, "the second send went out; nothing was rolled back")
    #expect(conversation.turns.count == 4)
}

@Test @MainActor func slowStopDoesNotKillTheNewerRun() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let first = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: first,
        inner: ["type": "response.output_text.delta", "delta": "one"]))

    // Hold both halves of the stop: the stop POST (so `finishLocally` lands
    // only when the test says so) and the chat fetch the finish frame parks
    // drain on. Both gates are continuations — `abandon` cancelling the run
    // does not wake either.
    transport.gateNextStop()
    transport.gateNextChatFetch()
    defer { transport.releaseStopGate(); transport.releaseChatFetchGate() }
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: first,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { transport.isChatFetchGateParked }

    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { transport.paths.contains("/api/tasks/chat/chat-1/stop") }

    // Give up on the stopping run and start a newer one, then let the slow
    // stop POST land: its `finishLocally` belongs to the abandoned run and
    // must not touch the state the newer run now owns (issue #5).
    conversation.abandon()
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: second,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    try await waitUntil { conversation.phase == .streaming }

    transport.releaseStopGate()
    try await Task.sleep(for: .milliseconds(100))
    #expect(conversation.phase.isBusy,
            "the slow stop must not finish the run that started after it")
    #expect(conversation.error == nil,
            "the slow stop must not stamp an error onto the newer run: \(conversation.error ?? "nil")")

    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: second,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) {
        conversation.turns.last?.text == "two" && conversation.phase == .ready
    }
    #expect(conversation.error == nil)
}
