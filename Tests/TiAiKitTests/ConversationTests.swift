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

/// A chat detail whose tree carries only the user turn — the streaming
/// assistant is not written yet, the way the server has it mid-run.
private func chatDetailWithoutAssistant(_ chatID: String) -> Data {
    Data("""
    {"id":"\(chatID)","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"user-1","messages":{
       "user-1":{"id":"user-1","role":"user","content":"first","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)
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
    private var _messageUpdateFailureAfter: Int?
    /// When set, the (N+1)th and later `updateMessage` POSTs throw instead of
    /// landing — the fixture for a trim that fails mid-way (issue #2): the
    /// first update lands, the next one does not.
    var messageUpdateFailureAfter: Int? {
        get { guarded { _messageUpdateFailureAfter } } set { guarded { _messageUpdateFailureAfter = newValue } }
    }
    private var _completionFailure: Error?
    private var _completionFailuresByID: [String: Error] = [:]

    /// When set, the completion POST throws this instead of returning the
    /// never-ending stream — the failed-POST path of issue #9. Settable so a
    /// test can arm the failure at a chosen moment (mid-stream, parked, stop).
    var completionFailure: Error? {
        get { guarded { _completionFailure } }
        set { guarded { _completionFailure = newValue } }
    }

    /// Arms a one-shot failure for the completion POST whose body carries
    /// this assistant message id (#25). Keyed rather than global: the global
    /// `completionFailure` is transport-global, so arming it after
    /// `awaitCompletion(2)` races the new POST's continuation hop — the stale
    /// POST may not have reached the failure check yet, or the new one may
    /// have. Keying to the stale run's assistant id is deterministic: only
    /// that run's POST can carry that id. Consumed at the same point the
    /// global flag is checked (after the completion gate's park), and
    /// consumed-once like the gates.
    func failCompletion(messageID: String, _ error: Error = APIError.unreachable("connection reset")) {
        guarded { _completionFailuresByID[messageID] = error }
    }

    /// When set, POST /files throws — the failed-upload path. Settable so a
    /// test can let the first upload land and fail the second.
    var failUploads: Bool {
        get { guarded { _failUploads } }
        set { guarded { _failUploads = newValue } }
    }

    var paths: [String] { guarded { _paths } }
    /// GET /api/v1/chats/{id} requests (the chat-detail refetch), counted.
    var chatFetchCount: Int {
        guarded { _paths.filter { $0.hasPrefix("/api/v1/chats/") && !$0.contains("/messages") }.count }
    }
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
    private let cooperativeMessageUpdateGate = CooperativeOneShotGate()
    private let uploadGate = OneShotGate()

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

    /// Makes the *next* POST /chats/{id}/messages/{id} wait inside the
    /// transport on a gate that is *cancellation-cooperative*: cancelling the
    /// waiting Task throws `CancellationError` out of the parked request,
    /// which is what a real URLSession-backed transport does. The plain
    /// `gateNextMessageUpdate()` deliberately never wakes on cancel, so the
    /// catch path of `edit()` — the issue #18 banner suppression — is only
    /// reachable through this variant.
    func gateNextMessageUpdateCancelThrows() { cooperativeMessageUpdateGate.arm() }
    /// True while a message-update POST is parked at the cooperative gate.
    var isCooperativeMessageUpdateGateParked: Bool { cooperativeMessageUpdateGate.isParked }
    /// Resumes the parked cooperative message-update POST (and disarms an
    /// unused gate). Only reachable on the path where nothing cancelled.
    func releaseCooperativeMessageUpdateGate() { cooperativeMessageUpdateGate.release() }

    /// Makes the *next* POST /files wait inside the transport until
    /// `releaseUpload()` — so a test can hold an upload on the wire while a
    /// send parks in `waitForUploads()` (issue #22). The parked request
    /// lives in the upload's own Task, not the run's, and this gate
    /// deliberately does not wake on cancellation: the upload outliving its
    /// run's stop is the non-cooperative shape #22 is about.
    func gateNextUpload() { uploadGate.arm() }
    /// True while an upload is parked at the gate.
    var isUploadGateParked: Bool { uploadGate.isParked }
    /// Resumes the parked upload (and disarms an unused gate).
    func releaseUpload() { uploadGate.release() }

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

    /// A one-shot gate that *is* cancellation-cooperative: cancelling the
    /// waiting Task resumes the parked waiter by throwing `CancellationError`,
    /// the way a real transport aborts an in-flight request when the run's
    /// Task is cancelled. `OneShotGate` above deliberately cannot do this (the
    /// race it exposes needs a sleep that does not wake); this variant exists
    /// so the *other* half of the same race — the catch path in `edit()` — can
    /// be reached at all. An unarmed gate is a no-op, even for an already
    /// cancelled Task: the throw is reserved for a request this gate held.
    fileprivate final class CooperativeOneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        /// Set by the cancellation handler so a cancel that lands *before* the
        /// continuation is registered still resolves the wait, by throwing.
        private var cancelRequested = false
        private var waiters: [CheckedContinuation<Void, any Error>] = []

        func arm() {
            lock.lock()
            armed = true
            cancelRequested = false
            lock.unlock()
        }

        /// Consume the arm in a synchronous helper: `NSLock.lock()` is
        /// `noasync`, so the async body cannot take the lock itself.
        private func takeArm() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard armed else { return false }
            armed = false
            cancelRequested = false
            return true
        }

        func parkIfArmed() async throws {
            // Consume the arm *before* any cancellation machinery is installed:
            // an unarmed gate must be a no-op even for a Task that is already
            // cancelled, or every cancelled run would trip this gate on
            // requests no test ever gated.
            guard takeArm() else { return }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (resume: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    // `Task.isCancelled` as well as `cancelRequested`: covers a
                    // cancel that landed in the window above, before the
                    // handler was installed, whatever the handler's ordering
                    // semantics are.
                    if cancelRequested || Task.isCancelled {
                        lock.unlock()
                        resume.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append(resume)
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                cancelRequested = true
                let parked = waiters
                waiters = []
                lock.unlock()
                for waiter in parked { waiter.resume(throwing: CancellationError()) }
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
            // Two gates on one route: the cooperative one is a no-op unless
            // armed, so the issue #13/#18 tests that use the plain gate are
            // untouched, and a Task that is merely already cancelled is not
            // thrown at by a gate that never held its request.
            try await cooperativeMessageUpdateGate.parkIfArmed()
            // Checked before recording: a rejected update never happened, so
            // it does not count toward the failure threshold either.
            if let after = guarded({ _messageUpdateFailureAfter }),
               guarded({ _messageUpdateBodies.count }) >= after {
                throw APIError.unreachable("message update rejected")
            }
            guarded { _messageUpdateBodies.append(request.httpBody ?? Data()) }
            return (Data("{}".utf8), response(for: request, 200))
        }
        if path.hasSuffix("/files") || path.hasSuffix("/files/") {
            // Park before recording, so `uploads` only grows once the test has
            // let the request through — the same contract the other gates keep.
            await uploadGate.parkIfArmed()
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
        // Per-message failure (#25), consumed at the same point as the global
        // flag — after the gate's park, so a test can arm it while the POST is
        // provably held. The id is parsed from this call's own body outside
        // the lock (the request is call-local; NSLock is not recursive), then
        // the lookup/removal is one guarded step.
        if let json = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
           let messageID = json["id"] as? String,
           let failure = guarded({ _completionFailuresByID.removeValue(forKey: messageID) }) {
            throw failure
        }
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

/// Issue #17: exchange's parked branch awaited `awaitQuestion` and then wrote
/// `phase = .ready` with no generation guard — the mirror of the resolve-side
/// R5 from #12. Abandoning a run that is parked *inside* the refetch loop, then
/// starting a fresh send, must leave the new run's phase untouched when the
/// stale refetch finally returns.
@Test @MainActor func abandoningDuringAParkedAwaitQuestionLeavesTheNextRunClean() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    // Arm the chat-fetch gate BEFORE the parking frame: `awaitQuestion`'s
    // first refetch is a GET /chats/{id}, and holding it open is what keeps
    // the parked branch inside its await long enough to be abandoned.
    transport.gateNextChatFetch()
    // Release on the way out no matter how the test ends: a failed #expect
    // must not leave a parked request (and its continuation) hanging the
    // suite.
    defer { transport.releaseChatFetchGate() }
    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))

    // The run has parked and `awaitQuestion` is now parked at the gate — so
    // the `.ready` stamp at the end of the parked branch has not happened.
    try await waitUntil { transport.isChatFetchGateParked }
    #expect(conversation.phase != .ready)
    #expect(conversation.turns.last?.questionIncoming == true)

    // Abandon: the generation bumps; the parked exchange task stays parked
    // (the transport gate ignores cancellation, by design).
    conversation.abandon()
    #expect(conversation.phase == .ready)

    // A brand-new send starts while the stale refetch is still in flight.
    conversation.draft = "second question"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    #expect(secondID != firstID)
    #expect(conversation.phase == .waiting)

    // Let the stale refetch land. The ask_user call on the abandoned turn has
    // structured arguments, so `awaitQuestion` returns after this refetch —
    // and its `defer` clearing `questionIncoming` is the deterministic signal
    // that the parked branch has resumed on a dead generation.
    transport.releaseChatFetchGate()
    try await waitUntil { conversation.turns[1].questionIncoming == false }
    // Every scheduling hop for the stale branch to stomp if it is going to.
    try await Task.sleep(for: .milliseconds(150))

    // The stale `.ready` must not have touched the new run: it is still
    // waiting for its first frame, not "finished".
    #expect(conversation.phase == .waiting)

    // The new run then streams and ends clean, as if the park never existed.
    for frame in Frames.run(chat: "chat-1", message: secondID, answer: "No need for pizza.") {
        hub.receive(frame)
    }
    try await waitUntil { conversation.phase == .ready }
    #expect(conversation.error == nil)
    #expect(conversation.turns.count == 4)  // user/assistant/user/assistant
    #expect(conversation.turns[3].text == "No need for pizza.")
    #expect(conversation.turns[3].streaming == false)
    #expect(conversation.turns[1].text != "No need for pizza.")

    // Nothing lands late either.
    try await Task.sleep(for: .milliseconds(250))
    #expect(conversation.phase == .ready)
    #expect(conversation.error == nil)
    #expect(conversation.turns.count == 4)
}

/// Issue #27: a superseded park must stand down promptly, not grind through
/// the refetch loop. Since #25 removed the accidental unblock (a superseded
/// POST failure's ungated `hub.expire` finishing the parked drain's
/// listener), a parked `awaitQuestion` that gets abandoned kept fetching
/// until its ten attempts ran out — bounded, but up to ~11s of pointless
/// GETs with the run's hub subscriber pinned alongside. The fix is the
/// G5/R5 ownership idiom one level earlier: generation/cancellation guards
/// inside the loop.
@Test @MainActor func abandonStandsDownAParkedRefetchPromptly() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    // AC #27: prove no timer is what saves the parked run. The watchdog
    // budget sits far outside the window this test asserts stand-down in.
    conversation.silenceLimit = .seconds(30)
    defer { conversation.silenceLimit = ConversationModel.silenceLimit }

    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)

    // Every refetch answers with a still-unreadable question (truncated
    // arguments -> `hasStructuredArguments == false`), so the loop can
    // never finish on its own merits: without the fix it runs all ten
    // attempts (~11s of sleeps, ten GETs) after the abandon.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"\(assistantID)","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["\(assistantID)"]},
           "\(assistantID)":{"id":"\(assistantID)","role":"assistant","content":"","parentId":"user-1","done":false,
             "output":[{"type":"function_call","call_id":"call_1","name":"ask_user","status":"pending",
                        "arguments":"{\\"questions\\":[{\\"id\\":\\"a\\",\\"question\\":\\"A?\\"}]"}]}}}}}
        """.utf8)

    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    // The park landed and the refetch loop is spinning (first GET done;
    // later attempts are behind 200ms+ sleeps).
    try await waitUntil { transport.chatFetchCount >= 1 }
    #expect(conversation.phase != .ready)

    conversation.abandon()
    // The listener half of the AC: abandon's own `hub.expire` ends the chat
    // stream at supersede time (true since #4 — pinned here as the AC asks).
    #expect(!hub.hasListener(for: "chat-1"),
            "the abandoned run's hub listener must be gone at supersede time")

    // The stand-down half: at most the one GET already in flight when
    // `run?.cancel()` landed may still complete; the loop itself must not
    // start another attempt. The unfixed code would add three or more GETs
    // inside this window (sleeps of 200/400/600ms).
    let baseline = transport.chatFetchCount
    try await Task.sleep(for: .milliseconds(1500))
    #expect(transport.chatFetchCount <= baseline + 1,
            "superseded refetch loop kept grinding: \(transport.chatFetchCount - baseline) extra GETs after abandon")
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

/// Regression for issue #18: a stop pressed during `edit()`'s `updateMessage`
/// window is acknowledged (`.stopping` → `.ready` via `finishLocally`) but must
/// not go on to start the re-run. `stop` cancels the run Task without bumping
/// the generation, so `exchange`'s generation guard cannot catch this — the
/// run Task itself has to refuse to continue once cancelled. The edit's save
/// surviving its own stop is the documented choice; the re-run is what the
/// user stopped.
@Test @MainActor func stopDuringAnInFlightEditSkipsTheReRun() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    // Same fixture as the issue #13 test: the edited message has to exist.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-2","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1","assistant-2"]},
           "assistant-2":{"id":"assistant-2","role":"assistant","content":"second","parentId":"user-1"}}}}}
        """.utf8)
    await conversation.load()

    transport.gateNextMessageUpdate()
    // A parked gate must never outlive the test, whatever the assertions do.
    defer { transport.releaseMessageUpdateGate() }
    conversation.edit(messageID: "user-1", text: "edited question")
    try await waitUntil { transport.isMessageUpdateGateParked }
    #expect(conversation.phase == .waiting)

    // Stop lands inside the update window: acknowledged up front as
    // `.stopping`, then `finishLocally` settles it once the stop POST returns.
    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { conversation.phase == .ready }

    // Let the parked update land. The save itself survives the stop (it
    // already happened server-side); the re-run must not start.
    transport.releaseMessageUpdateGate()
    try await waitUntil { transport.messageUpdateBodies.count == 1 }
    // Settle window: without the cancellation guard the run Task enters
    // `exchange` here and the completion POST is recorded near-instantly, so
    // this sleep is what the mutation trips on.
    try await Task.sleep(for: .milliseconds(150))

    #expect(transport.completionBodies.isEmpty,
            "the stopped edit must not POST a completion after stop was acknowledged")
    #expect(conversation.error == nil,
            "a stop the user asked for is not an error — no banner")
    #expect(conversation.phase == .ready,
            "the settled phase must stay settled")
    // The edit's save itself did land — the documented choice.
    #expect(transport.messageUpdateBodies.count == 1)
    #expect(conversation.turns.first?.text == "edited question")
}

/// The other half of issue #18, pinned by no amount of `OneShotGate` testing:
/// with a transport that *does* wake on cancellation — which is what a real
/// URLSession-backed transport is — the halted `updateMessage` surfaces in
/// `edit()`'s `catch` as a thrown `CancellationError`. A stop the user pressed
/// is not a failure, so that throw must not stamp an error banner; only the
/// `Task.isCancelled` branch of the catch stands between the user and a
/// "cancelled" banner flashing over a stop that had already been acknowledged.
@Test @MainActor func stopDuringEditWithCooperativeTransportShowsNoBanner() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    // Same fixture as `stopDuringAnInFlightEditSkipsTheReRun`: the edited
    // message has to exist.
    transport.chatDetailOverride = Data(
        """
        {"id":"chat-1","title":"T","updated_at":1,"created_at":1,"chat":{"models":["local-personal"],
         "history":{"currentId":"assistant-2","messages":{
           "user-1":{"id":"user-1","role":"user","content":"hi","childrenIds":["assistant-1","assistant-2"]},
           "assistant-2":{"id":"assistant-2","role":"assistant","content":"second","parentId":"user-1"}}}}}
        """.utf8)
    await conversation.load()

    transport.gateNextMessageUpdateCancelThrows()
    // Release covers the path where nothing cancelled (or a mutation removed
    // the guard and the run lived on); on the cancelled path the gate has
    // already been woken by the throw, and release is then a no-op.
    defer { transport.releaseCooperativeMessageUpdateGate() }
    conversation.edit(messageID: "user-1", text: "edited question")
    try await waitUntil { transport.isCooperativeMessageUpdateGateParked }
    #expect(conversation.phase == .waiting)

    // Stop lands inside the update window: `.stopping`, then `finishLocally`
    // cancels the run Task — which is what throws at the parked update.
    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { conversation.phase == .ready }

    // Settle window: without the catch-path guard the cancelled throw falls
    // through to the banner below, near-instantly.
    try await Task.sleep(for: .milliseconds(150))

    // Symptom 2 of issue #18: the cancel throw must not be reported as an
    // error. This is the assertion the whole test exists for.
    #expect(conversation.error == nil,
            "a stop the user asked for is not an error — no cancelled banner")
    #expect(conversation.phase == .ready,
            "the settled phase must stay settled (no restore wedge, no re-run)")
    #expect(transport.completionBodies.isEmpty,
            "the stopped edit must not POST a completion after stop was acknowledged")
    // The update never completed — it was thrown out of mid-flight, so nothing
    // was recorded as saved (unlike the non-cooperative gate above, where the
    // parked request is let through and the save does land).
    #expect(transport.messageUpdateBodies.isEmpty)
}

/// Regression for issue #22: a stop pressed while `send()` is parked in
/// `waitForUploads()` is acknowledged (`.stopping` → `.ready` via
/// `finishLocally`) but must not go on to post. The wait is not
/// cancellation-cooperative and `stop` never bumps the generation, so —
/// exactly like #18 for edit — the run Task itself has to refuse to continue
/// once the upload finally lands: cancellation *is* the marker. The ribbon
/// `send()` raised must be closed by the cancelled run (exchange's exits
/// never run), and no error banner may appear.
@Test @MainActor func stopDuringTheUploadWaitCancelsTheSend() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    // Injected seam (#15): the cancelled run has to close the ribbon it raised.
    let ribbon = GenerationActivity()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub, activity: ribbon)

    transport.gateNextUpload()
    // The upload must land after the stop whatever the assertions do — a
    // parked gate outliving the test would hang the transport for nobody.
    defer { transport.releaseUpload() }
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { transport.isUploadGateParked }

    conversation.draft = "hello"
    conversation.send()
    // The run is parked in `waitForUploads`: phase `.waiting`, upload still
    // on the wire, and the ribbon has gone up owned by this chat.
    #expect(conversation.phase == .waiting)
    try await waitUntil { ribbon.activeChatID == "chat-1" }

    // Stop lands inside the upload-wait window: acknowledged as `.stopping`,
    // then `finishLocally` settles to `.ready` once the stop POST returns —
    // cancelling the run Task on the way.
    conversation.stop()
    #expect(conversation.phase == .stopping)
    try await waitUntil { conversation.phase == .ready }

    // The upload lands — successfully, so no failure-abort branch fires.
    transport.releaseUpload()
    try await waitUntil { transport.uploads.count == 1 }
    // Settle window: without the cancellation guard the run Task enters
    // `exchange` here and the completion POST is recorded near-instantly,
    // so this sleep is what the mutation trips on.
    try await Task.sleep(for: .milliseconds(150))

    #expect(transport.completionBodies.isEmpty,
            "the stopped send must not POST a completion after stop was acknowledged")
    #expect(conversation.error == nil,
            "a stop the user asked for is not an error — no banner")
    #expect(conversation.phase == .ready,
            "the settled phase must stay settled — no flip back to .waiting")
    #expect(conversation.turns.isEmpty,
            "no phantom turns for a send that never posted")
    // The ribbon: closed by the cancelled run, token cleared.
    #expect(!ribbon.isRibbonActive, "the cancelled run must close the ribbon it raised")
    #expect(ribbon.activeChatID == nil)
    // Draft semantics, mirroring #8's abort: the message was never posted, so
    // the text goes back to the composer rather than into the void.
    #expect(conversation.draft == "hello")
    // Re-assert after the settle: nothing late re-posts, re-errors or re-raises.
    try await Task.sleep(for: .milliseconds(150))
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.error == nil)
    #expect(conversation.phase == .ready)
    #expect(!ribbon.isRibbonActive)
}

// The priority decision of #22, pinned: when a stop and an upload failure
// race, the stop wins and stays banner-free — `Task.isCancelled` takes
// precedence because the stop is the newer intent (the same priority #18
// decided for edit's catch). Without the ordering, the failure-abort branch
// would run first and stamp "A previous upload failed…" after the user's
// stop was already acknowledged.
@Test @MainActor func stopOutranksARacingUploadFailure() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let ribbon = GenerationActivity()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub, activity: ribbon)

    transport.gateNextUpload()
    defer { transport.releaseUpload() }
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { transport.isUploadGateParked }

    conversation.draft = "hello"
    conversation.send()
    #expect(conversation.phase == .waiting)

    conversation.stop()
    try await waitUntil { conversation.phase == .ready }

    // The upload now lands FAILING: both conditions are true at the wake —
    // cancelled and a new upload failure.
    transport.failUploads = true
    transport.releaseUpload()
    // Settle: the failed upload wakes `waitForUploads` and the run Task
    // resumes near-instantly; with the abort branch ahead of the cancel
    // guard, the failure banner lands in this window.
    try await Task.sleep(for: .milliseconds(250))

    #expect(conversation.error == nil || conversation.error!.hasPrefix("Could not attach"),
            "the send-abort banner must not appear after a stop; the attach path's own \"Could not attach\" note is the upload subsystem reporting a real failure, independent of the stopped send")
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.phase == .ready)
    #expect(!ribbon.isRibbonActive, "the cancelled run still closes the ribbon it raised")
    #expect(conversation.draft == "hello", "the stopped text returns to the composer either way")
}

// #28: the same window on a BRAND-NEW chat. `stop()` used to early-return for
// a model with no chat id — but there is no server chat to shout at in that
// window, so the button was simply dead: the chat sat in `.waiting` until the
// hung upload landed and then POSTed the message the user had just tried to
// abort. The abort is local: cancelling the run Task is the marker #22's
// guard in `send`'s upload wait reads, so the local-finish contract is the
// same one — draft back in the composer, ribbon closed, no banner, no POST.
@Test @MainActor func stopDuringTheUploadWaitOfANewChatAbortsLocally() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let ribbon = GenerationActivity()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal", caps: ["vision": true])],
        client: OWUIClient(server: server, transport: transport),
        hub: hub, activity: ribbon)

    transport.gateNextUpload()
    defer { transport.releaseUpload() }
    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntil { transport.isUploadGateParked }

    conversation.draft = "hello"
    conversation.send()
    #expect(conversation.phase == .waiting)
    // The ribbon went up unclaimed: a brand-new chat has no id to own it yet.
    try await waitUntil { ribbon.isRibbonActive }
    #expect(ribbon.activeChatID == nil)

    conversation.stop()
    // There is no round trip to wait for — nothing server-side knows about this
    // exchange — so the abort settles in the same main-actor turn. No
    // `.stopping` either: that state means "the server has been asked", and
    // here nobody was.
    try await waitUntil(timeout: .milliseconds(300)) { conversation.phase == .ready }

    // The upload lands successfully: the run wakes on the cancellation marker.
    transport.releaseUpload()
    try await waitUntil { transport.uploads.count == 1 }
    // Settle window: without the fix the run reaches `exchange` here — and
    // pre-fix `stop()` was a no-op, so the phase never left `.waiting` at all.
    try await Task.sleep(for: .milliseconds(150))

    #expect(transport.completionBodies.isEmpty,
            "a stopped brand-new chat must not POST a completion once its upload lands")
    #expect(transport.paths.contains { $0.contains("/stop") } == false,
            "there is no server chat to stop — the abort is local, so no stop route may be called")
    #expect(conversation.error == nil,
            "a stop the user asked for is not an error — no banner")
    #expect(conversation.phase == .ready,
            "the settled phase must stay settled — no flip back to .waiting")
    #expect(conversation.turns.isEmpty,
            "no phantom turns for a send that never posted")
    #expect(!ribbon.isRibbonActive, "the cancelled run must close the ribbon it raised")
    #expect(ribbon.activeChatID == nil)
    // The #22 local-finish contract: the message was never posted, so the text
    // goes back to the composer, and the picture that was still on the wire
    // lands as a chip (it was never consumed — the steal happens after the
    // cancellation guard), so a retry is one press away.
    #expect(conversation.draft == "hello")
    try await waitUntil { conversation.attachments.count == 1 }
    // Re-assert after the settle: nothing late re-posts, re-errors or re-raises.
    try await Task.sleep(for: .milliseconds(150))
    #expect(transport.completionBodies.isEmpty)
    #expect(conversation.error == nil)
    #expect(conversation.phase == .ready)
    #expect(!ribbon.isRibbonActive)
}

// #28, the last pre-chat window: the completion POST is open and the stream
// has not named the chat yet, so this model still has no id. Stop cannot ask
// the server, so the abort is local — and cancelling the run Task is not
// enough, because a `for await` over a hub stream does not observe
// cancellation: the hub teardown has to end it, or the stopped run keeps
// writing into a transcript whose phase already says `.ready`.
@Test @MainActor func stopOnANewChatWhoseIdTheStreamHasNotNamedEndsTheStream() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let ribbon = GenerationActivity()
    let conversation = ConversationModel(
        chatID: nil,
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub, activity: ribbon)

    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }
    conversation.draft = "hello"
    conversation.send()
    try await waitUntil { transport.isCompletionGateParked }
    #expect(conversation.chatID == nil)
    #expect(hub.hasWaitingListener, "the new chat's listener is waiting for its id")

    conversation.stop()
    try await waitUntil(timeout: .milliseconds(300)) { conversation.phase == .ready }
    #expect(!hub.hasWaitingListener,
            "the stopped run's waiting listener must be ended — nothing else closes the stream")

    // #34 (product call): a stop on a brand-new chat DISCARDS it — the
    // transcript goes back to empty and the text goes back to the composer,
    // as if the send had never happened.
    #expect(conversation.turns.isEmpty,
            "the phantom chat is discarded: \(conversation.turns)")
    #expect(conversation.draft == "hello",
            "the message returns to the composer")

    // The completion POST is let through: the server answers into a chat
    // nobody is listening to any more. Nothing may arrive late enough to
    // re-error, re-stream or re-raise.
    transport.releaseCompletion()
    try await Task.sleep(for: .milliseconds(200))
    #expect(conversation.phase == .ready)
    #expect(conversation.error == nil, "a stop the user asked for is not an error")
    #expect(!ribbon.isRibbonActive, "the stopped run must not leave the ribbon up")
    // The late POST landing must not resurrect the discarded chat: every
    // stream write resolves its message id at write time (#14), and the
    // discarded turns are gone.
    #expect(conversation.turns.isEmpty,
            "nothing from the stopped run may repopulate the discarded chat: \(conversation.turns)")
    // The discard must be durable against the stopped run's own unwind: a
    // dangling `leafID` would make the NEXT send post a parent id from the
    // discarded chat, and a late adopt would re-identify it.
    #expect(conversation.chatID == nil, "a stopped new chat stays unnamed")
    conversation.draft = "retry"
    conversation.send()
    try await transport.awaitCompletion(2)
    let body = try #require(transport.completionBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    // `.root` encodes an explicit null; a dangling leaf would be a string id.
    #expect(json?["parent_id"] is NSNull,
            "the send after a discard starts a fresh chat, no parent from the discarded one: \(json?["parent_id"] ?? "nil")")
}

// #30: stop() on an id-carrying chat must not sweep another model's
// brand-new-chat (nil-chatID) waiting listener off the shared per-server
// hub. The sweep in finishLocally could never reach its OWN chat's listener
// (stop refuses a chat with no id), so all it ever did was collateral.
@Test @MainActor func stopOnOneChatSparesAnotherModelsWaitingListener() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)

    // Model B: a brand-new chat parked on its first POST — its hub listener
    // is the waiting one (chatID == nil).
    let transportB = ScriptedTransport()
    let b = ConversationModel(
        chatID: nil, models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transportB), hub: hub)
    transportB.gateNextCompletion()
    defer { transportB.releaseCompletion() }
    b.draft = "new chat question"
    b.send()
    try await waitUntil { transportB.isCompletionGateParked }
    #expect(hub.hasWaitingListener, "B's waiting listener is registered while its POST is parked")

    // Model A: an established chat with a live run. Deliberately NO frames
    // are fed before the stop: a frame with a real chat id would be ADOPTED
    // by B's waiting listener (the hub names a waiting listener from the
    // first frame it sees — that is the design), which would defeat the
    // point of the test.
    let transportA = ScriptedTransport()
    let a = ConversationModel(
        chatID: "chat-30-stop", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transportA), hub: hub)
    a.draft = "hello"
    a.send()
    try await transportA.awaitCompletion()
    a.stop()
    try await waitUntil { a.phase == .ready }

    #expect(hub.hasWaitingListener,
            "a stop on chat-30-stop must not sweep B's brand-new-chat listener (#9 rule)")
}

// #36 (the root fix of the #30 family): the global waiting-listener sweep
// is gone, so this is structural, not gated. Two BRAND-NEW-CHAT models on
// one shared hub — the case #30 documented as the accepted residual (one
// Stop sweeping the other's pre-id listener). Each model now ends exactly
// the listener it installed, by the token it passed at install.
@Test @MainActor func stopOnOneNewChatSparesAnotherNewChatListener() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)

    let transportA = ScriptedTransport()
    let a = ConversationModel(
        chatID: nil, models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transportA), hub: hub)
    let transportB = ScriptedTransport()
    let b = ConversationModel(
        chatID: nil, models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transportB), hub: hub)
    transportA.gateNextCompletion()
    transportB.gateNextCompletion()
    defer { transportA.releaseCompletion(); transportB.releaseCompletion() }
    a.draft = "first question"
    a.send()
    b.draft = "second question"
    b.send()
    try await waitUntil { transportA.isCompletionGateParked && transportB.isCompletionGateParked }
    #expect(a.chatID == nil && b.chatID == nil)
    #expect(hub.hasWaitingListener, "both runs are pre-id listeners now")

    a.stop()
    try await waitUntil(timeout: .milliseconds(300)) { a.phase == .ready }

    // B's listener must be ALIVE, not merely present: the first frame
    // naming a chat is what adopts it. If A's stop had swept B's listener
    // off the hub (the old global-sweep behavior), nothing would be
    // listening and the adoption would never happen.
    for frame in Frames.run(chat: "chat-b", message: "m-b", answer: "b's answer") {
        hub.receive(frame)
    }
    try await waitUntil(timeout: .milliseconds(300)) { b.chatID == "chat-b" }
    #expect(b.chatID == "chat-b",
            "A's stop must not sweep B's brand-new-chat listener off the shared hub (#36)")
}

// #36: token-scoped expiry ends EXACTLY one listener — and it works after
// the listener has already adopted a real chat id, the documented residual
// the two id-based sweeps missed (a listener that adopted while the model's
// chatID was still nil was addressed by neither).
@Test @MainActor func expireWaitingTokenEndsExactlyOneAdoptedListener() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let tokenA = UUID()
    let tokenB = UUID()
    let streamA = hub.framesAwaitingChatID(token: tokenA) { _ in }
    let streamB = hub.framesAwaitingChatID(token: tokenB) { _ in }
    let aEnded = Task { () -> Bool in
        for await _ in streamA { }
        return true
    }
    let bCount = Task { () -> Int in
        var n = 0
        for await _ in streamB { n += 1 }
        return n
    }
    try await Task.sleep(for: .milliseconds(20))
    // Both listeners adopt "chat-x" from the first frame (the hub names
    // every waiting listener from the first frame carrying an id — that
    // is the design), so neither is "waiting" any more: the old
    // expireWaitingListeners() would now find nothing to sweep.
    for frame in Frames.run(chat: "chat-x", message: "m1", answer: "hi") {
        hub.receive(frame)
    }
    #expect(!hub.hasWaitingListener, "both adopted an id")

    hub.expire(waitingToken: tokenA)
    #expect(await aEnded.value,
            "A's stream ends on its token even though it adopted a chat id (the residual #36 closes)")

    // B is untouched and still receiving frames for the adopted chat.
    hub.receive(.fixture(kind: "response:completion", chatID: "chat-x", messageID: "m2",
                         inner: ["type": "response.output_text.delta", "delta": "more", "output_index": 1]))
    hub.expire(chatID: "chat-x")  // ends B, now keyed by the adopted id
    let n = await bCount.value
    #expect(n >= 4, "B kept receiving after A's token expired: got \(n)")
}

// #42, the live shape: a brand-new chat whose stream never names it.
// The hub hands a waiting listener nothing until a frame carries a
// chat_id (by design — unrelated chatter must not capture a new chat),
// so a run whose frames never arrive, or arrive without an id, leaves
// the model with chatID nil — and the old watchdog expired
// `chatID ?? ""`: nothing, ever. The run stayed "running" forever (the
// live case: an hour over a server record that had been done for fifty
// minutes). The watchdog must be able to end the run by TOKEN.
@Test @MainActor func aNewChatThatIsNeverNamedStillEndsOnTheWatchdog() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: nil, models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)
    conversation.silenceLimit = .milliseconds(300)
    defer { conversation.silenceLimit = ConversationModel.silenceLimit }
    conversation.draft = "make me a deck"
    conversation.send()
    try await transport.awaitCompletion()

    // A frame that carries text but no chat_id: the hub drops it for the
    // waiting listener (no adoption, no delivery), which is exactly the
    // dead-air shape the live incident streamed into.
    let aid = try #require(transport.assistantMessageID)
    let bare = ChatEventSocket.Frame([
        "message_id": aid,
        "data": ["type": "response:completion", "data": [
            "type": "response.output_text.delta", "delta": "slide one", "output_index": 1,
        ]],
    ])
    hub.receive(try #require(bare))
    #expect(conversation.chatID == nil, "nothing ever named this chat")

    // Pre-fix this never happens: the watchdog fires, expires "",
    // matches no subscriber, and the run hangs busy forever.
    try await waitUntil(timeout: .seconds(3)) { conversation.phase == .ready }
    #expect(conversation.phase == .ready,
            "a never-named new chat must settle when the silence watchdog fires (#42)")
}

// #42's backstop for the pathologies we have NOT diagnosed: a stream that
// keeps talking and never terminates outruns the silence watchdog (every
// frame re-arms it, #33). The run ceiling is never re-armed and ends the
// stream on wall-clock regardless; the caller's reconcile then reads the
// truth off the server record — the leave-and-re-enter recovery, on a bound.
@Test @MainActor func theRunCeilingEndsAStreamThatNeverStopsTalking() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-42", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)
    // The silence watchdog must be structurally unable to be the one that
    // ends this run; only the ceiling may.
    conversation.silenceLimit = .seconds(30)
    conversation.runCeiling = .milliseconds(400)
    // The ceiling unwinds the drain without a terminal, which lands in
    // reconcile; this transport stubs no chat-detail GET, and a failed
    // read just burns budget ticks — shrink the budget so the test does
    // not sit out five minutes of it.
    conversation.reconcileInterval = .milliseconds(20)
    conversation.reconcileBudget = 3
    defer {
        conversation.silenceLimit = ConversationModel.silenceLimit
        conversation.runCeiling = ConversationModel.runCeiling
        conversation.reconcileInterval = .seconds(2)
        conversation.reconcileBudget = 150
    }
    conversation.draft = "hello"
    conversation.send()
    try await transport.awaitCompletion()
    let aid = try #require(transport.assistantMessageID)

    func delta(_ word: String) {
        hub.receive(.fixture(kind: "response:completion", chatID: "chat-42", messageID: aid,
            inner: ["type": "response.output_text.delta", "delta": word, "output_index": 1]))
    }
    delta("one")
    try await waitUntil { conversation.turns.last?.text.contains("one") == true }
    // Chatter past the ceiling: a frame every 150 ms, a tenth of the
    // silence budget — the watchdog can never fire here.
    for word in ["two", "three", "four", "five"] {
        try await Task.sleep(for: .milliseconds(150))
        delta(word)
    }
    try await waitUntil(timeout: .seconds(3)) { conversation.phase == .ready }
    #expect(conversation.phase == .ready,
            "the ceiling must end a stream that never goes quiet and never terminates (#42)")
}

// #26: the temporary:/local:/incognito early return in load() used to stamp
// `.ready` unconditionally — mid-run, that unlocked the composer and
// disarmed reconcile's phase guard, the exact bug #19 closed for the plain
// paths.
@Test @MainActor func midRunLoadOfATemporaryChatLeavesThePhaseAlone() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "temporary:midrun-26", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    await conversation.load()   // hits the prefix early return
    #expect(conversation.phase == .waiting,
            "a mid-run load must not hand the composer back while the run is live")

    conversation.draft = "interloper"
    conversation.send()
    #expect(conversation.draft == "interloper",
            "a send during the live run is refused — the composer stayed locked")

    // The live run finishes normally.
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "temporary:midrun-26", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "answer"]]],
    ]))
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "temporary:midrun-26", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }
    #expect(conversation.turns.last?.text == "answer")
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

// Issue #14: a pull-to-refresh mid-run rebuilds `turns` wholesale — `load()`
// neither bumps the generation nor cancels the run, and it must not have to.
// Every write the stream performs resolves its destination by message id at
// write time, so a reloaded tree that inserts an older exchange and shifts
// every captured integer cannot redirect the stream onto another row.
@Test @MainActor func reloadMidRunCannotRedirectTheStreamToAnotherTurn() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-14-reload", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)

    conversation.draft = "second question"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-14-reload", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "first half, "]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("first half") == true }

    // Reload mid-run. The server's tree now carries an older exchange the
    // local array never saw — someone answered in the web UI — so the
    // streaming assistant sits two rows deeper than any captured index
    // remembers. The record is still open, exactly as a refresh during a
    // live run finds it.
    transport.chatDetailOverride = Data("""
    {"id":"chat-14-reload","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "old-user":{"id":"old-user","role":"user","content":"older question","done":true,"parentId":null,"childrenIds":["old-assistant"]},
       "old-assistant":{"id":"old-assistant","role":"assistant","content":"older answer","model":"local-personal","done":true,"parentId":"old-user","childrenIds":["user-1"]},
       "user-1":{"id":"user-1","role":"user","content":"second question","done":true,"parentId":"old-assistant","childrenIds":["\(id)"]},
       "\(id)":{"id":"\(id)","role":"assistant","content":"first half, ","model":"local-personal","done":false,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    await conversation.load()
    #expect(conversation.turns.count == 4)
    #expect(conversation.turns.firstIndex(where: { $0.id == id }) == 3,
            "the stream's turn moved out from under it")

    // The stream keeps going after the shift and ends normally.
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-14-reload", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "second half."]]],
    ]))
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-14-reload", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    // The server closes the record about when the stream does; leaving it
    // open would make the post-run reconcile poll for its whole five-minute
    // budget before the run reports ready.
    transport.chatDetailOverride = Data("""
    {"id":"chat-14-reload","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "old-user":{"id":"old-user","role":"user","content":"older question","done":true,"parentId":null,"childrenIds":["old-assistant"]},
       "old-assistant":{"id":"old-assistant","role":"assistant","content":"older answer","model":"local-personal","done":true,"parentId":"old-user","childrenIds":["user-1"]},
       "user-1":{"id":"user-1","role":"user","content":"second question","done":true,"parentId":"old-assistant","childrenIds":["\(id)"]},
       "\(id)":{"id":"\(id)","role":"assistant","content":"first half, ","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }

    // The stored record above deliberately stays SHORTER than the stream: the
    // grow-only reconcile would happily copy it up, so this assertion only
    // passes if the live flush itself landed on this turn.
    let mine = try #require(conversation.turns.first { $0.id == id })
    #expect(mine.text == "first half, second half.")
    #expect(!mine.streaming)
    let older = try #require(conversation.turns.first { $0.id == "old-assistant" })
    #expect(older.text == "older answer", "a shifted row must not be overwritten by the stream")
}

// Issue #19: a mid-run reload whose server tree does not (yet) contain the
// streaming assistant drops the row from `turns`, and nothing re-added it.
// flush skips writes for absent ids (#14, correct), and `apply(message,to:)`
// / `adoptStoredMessage` grow turns that exist but never insert a missing
// one — so the live transcript showed nothing for a run that visibly
// happened, until leaving the chat and coming back.
//
// The fix is in the two places that re-read the record after a run: the
// post-terminal-frame adopt (`adoptStoredMessage`) and `reconcileUntilClosed`
// (runs that ended without a terminal frame, and the heal-on-open). When the
// fetched detail HAS the message but `turns` lacks the row, they rebuild via
// `apply(detail)` — the same wholesale rebuild load() already does, safe now
// because every stream write resolves by id at write time. It also puts the
// row at the tree-correct position for free.
@Test @MainActor func reloadDroppingTheStreamingRowIsReAddedByReconcile() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-19-reload", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)
    conversation.reconcileInterval = .milliseconds(1)

    conversation.draft = "the question"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-reload", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "partial "]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("partial") == true }

    // Reload mid-run. The server has not written the assistant's message yet,
    // so its tree carries only the user turn — the streaming row leaves the
    // local array, and every later flush for this run is skipped (#14).
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-reload","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"user-1","messages":{
       "user-1":{"id":"user-1","role":"user","content":"the question","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)
    await conversation.load()
    #expect(conversation.turns.firstIndex(where: { $0.id == id }) == nil,
            "the reload must actually have dropped the streaming row")
    // A refresh during a live run must not unlock the composer: the run owns
    // the phase until it ends, whatever the reloaded tree looks like.
    #expect(conversation.phase.isBusy,
            "a mid-run reload must not hand the composer back while the run is live")

    // The stream keeps going; its writes are dropped (the row is gone), but
    // the server is accumulating the full answer.
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-reload", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "answer."]]],
    ]))
    // The server closes the record about when the stream does — and the
    // closed record now contains the assistant.
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-reload","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"the question","done":true,"parentId":null,"childrenIds":["\(id)"]},
       "\(id)":{"id":"\(id)","role":"assistant","content":"partial answer.","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-19-reload", messageID: id,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))

    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }
    // The post-run read of the record lands asynchronously (the adopt Task
    // spawned when the run finished; `reconcileUntilClosed` plays the same
    // role for runs that ended without a terminal frame).
    try await waitUntil(timeout: .seconds(4)) {
        conversation.turns.contains { $0.id == id }
    }
    let row = try #require(
        conversation.turns.first { $0.id == id },
        "the post-run read of the record must re-add the row the reload dropped")
    #expect(row.text == "partial answer.",
            "and land it with the stored text, without leaving the chat")
    #expect(!row.streaming)
    #expect(conversation.error == nil)
}

/// The same dropped row, on the other post-run read: a run that ends without
/// a terminal frame (iOS kills the socket on a background sojourn) falls
/// through to `reconcileUntilClosed`, which must re-add the row the same way.
@Test @MainActor func droppedSocketAfterReloadStillLandsTheAnswer() async throws {
    let hub = ChatEventHub(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"))
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-19-drop", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
                           transport: transport),
        hub: hub)
    conversation.reconcileInterval = .milliseconds(1)

    conversation.draft = "the question"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-drop", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "partial "]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("partial") == true }

    transport.chatDetailOverride = Data("""
    {"id":"chat-19-drop","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"user-1","messages":{
       "user-1":{"id":"user-1","role":"user","content":"the question","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)
    await conversation.load()
    #expect(conversation.turns.firstIndex(where: { $0.id == id }) == nil)

    // The server finishes writing the answer, then the socket dies — no
    // terminal frame ever arrives. The run falls through to the reconcile loop.
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-drop","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"the question","done":true,"parentId":null,"childrenIds":["\(id)"]},
       "\(id)":{"id":"\(id)","role":"assistant","content":"partial answer.","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    hub.expire(chatID: "chat-19-drop")

    try await waitUntil(timeout: .seconds(8)) { conversation.phase == .ready }
    let row = try #require(
        conversation.turns.first { $0.id == id },
        "the reconcile after a socket drop must re-add the dropped row too")
    #expect(row.text == "partial answer.")
    #expect(conversation.error == nil,
            "an answer that landed off the record is not an empty answer")
}

// Issue #19 review, warning 1: the heal-on-open must only fire when no run is
// live. A mid-run `load()` whose reloaded tree happens to end on the run's own
// open assistant used to stamp `.streaming` over the run's phase (`waiting`
// here, but `stopping` was worse) and spawn a SECOND `reconcileUntilClosed`
// on a message the live run is already watching — two loops, double GETs, one
// record. The live run owns its message; a refresh has nothing to heal.
@Test @MainActor func midRunLoadDoesNotHealTheLiveRunsOwnMessage() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-19-healrace", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)

    conversation.draft = "the question"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    // The record already carries both messages and still has the assistant
    // open — exactly the shape the heal-on-open looks for. But this app did
    // not mis-end that run: the run is live on the socket this very second.
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-healrace","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"the question","done":true,"parentId":null,"childrenIds":["\(id)"]},
       "\(id)":{"id":"\(id)","role":"assistant","content":"partial","model":"local-personal","done":false,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    // No frame has flushed yet, so the run sits at `.waiting` — the phase the
    // old heal clobbered on its way to `.streaming`.
    #expect(conversation.phase == .waiting)
    let chatFetches: () -> Int = {
        transport.paths.filter { $0 == "/api/v1/chats/chat-19-healrace" }.count
    }
    let before = chatFetches()
    await conversation.load()
    #expect(conversation.phase == .waiting,
            "a mid-run load must not restamp the live run's phase — the run owns it")
    // The heal is a spawned `reconcileUntilClosed`, and its first act is a
    // GET. The load's own fetch is the only one allowed to happen; a second
    // watcher on this message would have fetched again within the settle.
    try await Task.sleep(for: .milliseconds(250))
    #expect(chatFetches() == before + 1,
            "the heal must not spawn a second reconcile watching the live run's message")
    // And the live run is unharmed: its stream still drives the transcript.
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-healrace", messageID: id, inner: [
        "choices": [["index": 0, "delta": ["content": "answer."]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("answer.") == true }
}

// Issue #19 review, warning 2: the wholesale `apply(detail)` rebuild in
// `adoptStoredMessage` is gated on the run generation precisely because it
// replaces `turns` with the fetched tree — which deletes every row that tree
// does not contain yet, including a NEWER run's local-only placeholders. This
// test makes the rebuild lose that race on purpose: the adopt's GET is parked
// in the transport, a new run starts (bumping the generation and appending
// placeholder rows no server tree has), and only then does the stale fetch
// land. Remove the `runGeneration == gen` gate and the new run's rows are
// clobbered out from under it.
@Test @MainActor func staleAdoptRebuildDoesNotClobberTheNewerRun() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-19-adoptclob", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)
    conversation.reconcileInterval = .milliseconds(1)

    // Run 1 ends the #19 way — a mid-run reload drops the streaming row, so
    // the post-run adopt takes its rebuild branch (row absent locally,
    // present in the record).
    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-adoptclob", messageID: firstID, inner: [
        "choices": [["index": 0, "delta": ["content": "partial "]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("partial") == true }
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-adoptclob","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"user-1","messages":{
       "user-1":{"id":"user-1","role":"user","content":"first","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)
    await conversation.load()
    #expect(conversation.turns.firstIndex(where: { $0.id == firstID }) == nil,
            "the reload must have dropped the streaming row (the rebuild branch precondition)")

    // The record now HAS the finished answer — the adopt fetch will want to
    // rebuild from it. Park that fetch inside the transport so the rebuild is
    // provably in flight at the moment the new run starts.
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-adoptclob","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(firstID)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"first","done":true,"parentId":null,"childrenIds":["\(firstID)"]},
       "\(firstID)":{"id":"\(firstID)","role":"assistant","content":"partial answer.","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    // Two GETs want to land on the terminal frame: drain's `serverStillOpen`
    // probe (which holds the run at `.streaming` until it answers) and, once
    // the run ends, the adopt's own fetch. Park the probe first, then re-arm
    // in the same main-actor turn — nothing else can slip a GET between them —
    // so the fetch that ends up parked, and loses the race, is the adopt's.
    transport.gateNextChatFetch()
    defer { transport.releaseChatFetchGate() }
    hub.receive(Frame.fixture(kind: "chat:completion", chatID: "chat-19-adoptclob", messageID: firstID,
                              inner: ["choices": [["index": 0, "finish_reason": "stop"]]]))
    try await waitUntil { transport.isChatFetchGateParked }
    transport.releaseChatFetchGate()
    transport.gateNextChatFetch()
    // The record says `done`, so the probe answers "not still open", the run
    // ends, and the adopt Task's GET is the next one through the door.
    try await waitUntil { transport.isChatFetchGateParked }
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    // A NEW run starts while the rebuild is parked mid-round-trip. Its user
    // and assistant rows are local-only — no server tree contains them yet.
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-adoptclob", messageID: secondID, inner: [
        "choices": [["index": 0, "delta": ["content": "two"]]],
    ]))
    try await waitUntil { conversation.turns.last?.text == "two" }

    // Let the stale fetch land. Its tree ends at run 1's answer and contains
    // neither of run 2's rows; the generation gate must make it refuse.
    transport.releaseChatFetchGate()
    // Proof the fetch actually landed and raced: the mid-run load's GET, the
    // `serverStillOpen` probe, and the adopt's GET.
    try await waitUntil(timeout: .seconds(5)) {
        transport.paths.filter { $0 == "/api/v1/chats/chat-19-adoptclob" }.count >= 3
    }
    try await Task.sleep(for: .milliseconds(150))

    let survivor = try #require(
        conversation.turns.first { $0.id == secondID },
        "the superseded adopt must not rebuild away the newer run's placeholder")
    #expect(survivor.text == "two",
            "the newer run's streamed text must survive the stale rebuild")
    #expect(conversation.phase.isBusy, "the newer run is still live")
    // The rebuild was refused outright, not applied-then-patched: run 1's row
    // stays where the reload left it (absent) until the next real load.
    #expect(conversation.turns.firstIndex(where: { $0.id == firstID }) == nil)
}

// The same race against the OTHER wholesale rebuild: `reconcileUntilClosed`.
// The discriminating detail is the loop's own phase guard — it passes on
// `phase == .streaming`, and after an `abandon` + new send the NEW run is
// streaming, so the guard waves the stale loop through. `isCurrent(gen)` is
// the only thing left standing between the fetched tree and the newer run's
// rows. Remove it and the rebuild deletes them.
@Test @MainActor func staleReconcileRebuildDoesNotClobberTheNewerRun() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-19-recclob", models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport), hub: hub)
    conversation.reconcileInterval = .milliseconds(1)

    // Run 1: dropped row again, but it ends by the socket dying — no terminal
    // frame — so `reconcileUntilClosed` is the one holding the fetch.
    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-recclob", messageID: firstID, inner: [
        "choices": [["index": 0, "delta": ["content": "partial "]]],
    ]))
    try await waitUntil { conversation.turns.last?.text.contains("partial") == true }
    transport.chatDetailOverride = Data("""
    {"id":"chat-19-recclob","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"user-1","messages":{
       "user-1":{"id":"user-1","role":"user","content":"first","done":true,"parentId":null,"childrenIds":[]}}}}}
    """.utf8)
    await conversation.load()
    #expect(conversation.turns.firstIndex(where: { $0.id == firstID }) == nil)

    let fullTree = Data("""
    {"id":"chat-19-recclob","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(firstID)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"first","done":true,"parentId":null,"childrenIds":["\(firstID)"]},
       "\(firstID)":{"id":"\(firstID)","role":"assistant","content":"partial answer.","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
    // Two watchers read the record when the socket dies: the adopt Task and
    // the reconcile loop. The one-shot gate parks whichever GET arrives
    // first; the other must NOT rebuild while its generation is still
    // current (that would put the row back and take the grow-only branch
    // later, never the rebuild). So the first answer out of the queue is a
    // detail without the assistant — the early watcher exits finding
    // nothing — and the parked one gets the full tree once run 2 is live.
    transport.chatDetailQueue = [chatDetailWithoutAssistant(firstID), fullTree]
    transport.chatDetailOverride = fullTree
    transport.gateNextChatFetch()
    defer { transport.releaseChatFetchGate() }
    hub.expire(chatID: "chat-19-recclob")
    // A GET is parked. (The gate's continuation is deliberately not
    // cancellation-cooperative, so the abandon below cannot wake it early —
    // the race stays where the test put it.)
    try await waitUntil { transport.isChatFetchGateParked }

    // Supersede run 1 while its reconcile fetch is parked, then start run 2.
    conversation.abandon()
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(kind: "response:completion", chatID: "chat-19-recclob", messageID: secondID, inner: [
        "choices": [["index": 0, "delta": ["content": "two"]]],
    ]))
    try await waitUntil { conversation.turns.last?.text == "two" }
    // The stale loop's `phase == .streaming` guard will pass — this is run 2's
    // streaming, not the run the loop belongs to. That is exactly why the
    // generation gate exists.
    #expect(conversation.phase == .streaming)

    transport.releaseChatFetchGate()
    // load + the two post-run watchers, all answered.
    try await waitUntil(timeout: .seconds(5)) {
        transport.paths.filter { $0 == "/api/v1/chats/chat-19-recclob" }.count >= 3
    }
    try await Task.sleep(for: .milliseconds(150))

    let survivor = try #require(
        conversation.turns.first { $0.id == secondID },
        "the superseded reconcile must not rebuild away the newer run's rows")
    #expect(survivor.text == "two",
            "the newer run's streamed text must survive the stale rebuild")
    #expect(conversation.turns.firstIndex(where: { $0.id == firstID }) == nil,
            "the rebuild was refused outright, not applied and re-patched")
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
    let stream = hub.framesAwaitingChatID(token: UUID()) { adopted = $0 }
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
    _ = hub.framesAwaitingChatID(token: UUID()) { adopted = $0 }
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
    // This wait IS the regression. A new chat's pre-id listener is
    // addressed by the token #36 installed; the 60 s silence watchdog
    // expires "" and never matches it. Without the token expiry in
    // `recordPostError` this times out — the run hangs forever on a POST
    // that already failed.
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

/// Issue #25, the waiting case. A superseded run's POST dying after a NEW
/// run took the `post` slot must not touch the newer run: no banner, no
/// #9 rollback, no expiring the newer listener. The supersede here goes
/// through `abandon()` (the load hole this test used to exploit is closed
/// since #26) — which means the inertness under test now comes from
/// abandon's `post?.cancel()` plus the catch's `Task.isCancelled`
/// self-silence rather than from `recordPostError`'s gen guard; that guard
/// remains defense-in-depth for any future supersede path that leaves the
/// stale POST uncancelled (see its doc). What this pins end-to-end: a
/// stopped-and-replaced run's late POST failure is invisible to the newer
/// run.
@Test @MainActor func supersededPostFailureDoesNotKillTheNewerRun() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "temporary:sid-1")
    transport.gateNextCompletion()

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion(1)
    // Proof run 1's POST is the one held open inside the transport.
    #expect(transport.isCompletionGateParked)
    // Run 1's assistant id, read from the recorded POST body.
    let firstID = try #require(transport.assistantMessageID)

    // The supersede. `abandon` bumps the generation and settles the phase
    // while run 1's POST stays parked (the gate ignores cancellation — the
    // same non-cooperative wait #22 lives off).
    conversation.abandon()
    #expect(conversation.phase == .ready)

    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)

    // The stale POST dies — keyed to run 1's message id so only that request
    // can consume it (the global flag would race run 2's continuation hop).
    // can consume it (the global flag would race run 2's continuation hop).
    transport.failCompletion(messageID: firstID)
    transport.releaseCompletion()
    // Give the superseded POST's catch a chance to misfire into the newer
    // run (same catch-window idiom as `parkedRunDoesNotRollback`).
    try await Task.sleep(for: .milliseconds(150))

    // Asserted BEFORE any frames are injected for run 2: pre-fix the late
    // failure stamped its banner on run 2's `.waiting` phase, expired run 2's
    // listener, and the rollback gate then fired — red in both orderings.
    #expect(conversation.error == nil,
            "a superseded run's POST failure must not stamp the newer run: \(conversation.error ?? "nil")")
    #expect(conversation.turns.contains { $0.isUser && $0.text == "second" },
            "the newer run's user turn must not be rolled back")
    #expect(conversation.draft.isEmpty, "nothing is put back in the composer")

    // And run 2 must still be able to finish: its listener survived.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "temporary:sid-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "temporary:sid-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) {
        conversation.phase == .ready && conversation.turns.last?.text == "two"
    }
    #expect(conversation.error == nil)
}

/// Issue #25, the streaming case. Same supersede, but the newer run is
/// already `.streaming` when the orphaned POST dies — `phase.isBusy` passes
/// there too, and the banner lands even though no rollback fires (the
/// rollback gate wants `.waiting`).
@Test @MainActor func supersededPostFailureDoesNotStampAStreamingRun() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "temporary:sid-1")
    transport.gateNextCompletion()

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion(1)
    #expect(transport.isCompletionGateParked)
    let firstID = try #require(transport.assistantMessageID)

    // Supersede via abandon(); see the waiting test for why (#26 closed the
    // load hole this test used to exploit).
    conversation.abandon()
    #expect(conversation.phase == .ready)

    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)

    // Put run 2 into `.streaming` before the stale POST dies.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "temporary:sid-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    try await waitUntil { conversation.phase == .streaming }

    transport.failCompletion(messageID: firstID)
    transport.releaseCompletion()
    try await Task.sleep(for: .milliseconds(150))
    #expect(conversation.error == nil,
            "a superseded run's POST failure must not stamp the streaming run: \(conversation.error ?? "nil")")

    // Run 2 finishes untouched — its listener was not expired either.
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "temporary:sid-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) {
        conversation.phase == .ready && conversation.turns.last?.text == "two"
    }
    #expect(conversation.error == nil)
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

@Test @MainActor func abandonMidStreamDoesNotPoisonTheNextRunsBuffer() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "first"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "one"]))
    // Proof run 1's drain is alive inside the frame loop: the delta reached
    // the buffer and the flusher published it.
    try await waitUntil { conversation.turns.last?.text == "one" }

    // The bug: `abandon` bumps the generation, but neither expires the hub
    // nor cancels frame iteration — run 1's drain KEEPS iterating, and its
    // writes target the model-level `pending`, which is about to belong to
    // run 2 (issue #16).
    conversation.abandon()

    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    #expect(secondID != firstID)
    // Run 2's drain has installed its own `pending` by now.
    try await Task.sleep(for: .milliseconds(100))

    // A stale delta for run 1's message, arriving after run 2 installed its
    // buffer. Run 2's drain filters it out by message id; run 1's drain is
    // the one that reads it — and must not write it anywhere.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "STALE-"]))

    // Run 2's own delta and terminal frame.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    #expect(conversation.turns.count == 4)
    // Without the guard: "STALE-two" — run 1's drain appended the stale
    // delta into run 2's buffer.
    #expect(conversation.turns[3].text == "two",
            "a superseded drain must not write into the newer run's buffer: \(conversation.turns[3].text)")
    #expect(conversation.turns[1].text == "one")
    #expect(conversation.error == nil)
    // Nothing lands late via the abandoned run's flusher or watchdog either.
    try await Task.sleep(for: .milliseconds(200))
    #expect(conversation.turns[3].text == "two")
    #expect(conversation.phase == .ready)
}

/// Issue #16, the reachable path. An exchange's drain lives inside `run`,
/// which `abandon` cancels — but cancelling the iterating task does NOT
/// end the `AsyncStream` loop (iteration ignores cancellation); the
/// exchange path unwinds because the loop-top id guard breaks when a
/// newer run installs its buffer. The RESOLVE's drain is the exposed
/// one: `resolve()` runs it in a bare Task that is not
/// stored in `run` (issue #12), so abandon cannot cancel it, and abandon
/// neither expires the hub nor ends the frame iteration. The stale resolve
/// keeps looping, and its writes target the model-level `pending` — which
/// the next run has just installed. Without drain's id guard a stale delta
/// for the parked message lands inside the NEW run's answer.
@Test @MainActor func abandonMidResolveStreamDoesNotPoisonTheNextRunsBuffer() async throws {
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

    // Answer it. The resolve's hub subscriber is installed synchronously
    // inside `resolve()` (before the POST), so the delta below is buffered and
    // the resumed drain — running under the SAME assistant message id —
    // cannot miss it.
    conversation.resolve(
        messageID: firstID, call: call, action: .answer,
        answers: .object(["meal": .string("pizza")]))
    try await waitUntil { !transport.resolveBodies.isEmpty }
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "one"]))
    // Proof the resolve's drain is alive in the frame loop: the delta reached
    // the buffer and the flusher published it.
    try await waitUntil { conversation.turns.last?.text == "one" }

    // The bug: abandon bumps the generation, but the resolve Task is
    // untracked and uncancellable and the hub is not expired — the drain
    // KEEPS iterating, and `pending` is about to belong to run 2.
    conversation.abandon()
    #expect(conversation.phase == .ready)

    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    #expect(secondID != firstID)
    // Run 2's drain has installed its own `pending` by now.
    try await Task.sleep(for: .milliseconds(100))

    // A stale delta for the parked message, arriving after run 2 installed
    // its buffer. Run 2's drain filters it out by message id; the resolve's
    // drain is the one that reads it — and must not write it anywhere.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "STALE-"]))

    // Run 2's own delta and terminal frame.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    #expect(conversation.turns.count == 4)
    // Without the guard: "STALE-two" — the stale resolve's drain appended
    // the stale delta into run 2's buffer.
    #expect(conversation.turns[3].text == "two",
            "a superseded resolve drain must not write into the newer run's buffer: \(conversation.turns[3].text)")
    #expect(conversation.turns[1].text == "one")
    #expect(conversation.error == nil)
    // Nothing lands late via the stale resolve's flusher or watchdog either.
    try await Task.sleep(for: .milliseconds(200))
    #expect(conversation.turns[3].text == "two")
    #expect(conversation.phase == .ready)
}

/// Issue #21: a resolve's drain runs in a bare Task that `abandon` cannot
/// cancel, and a superseded drain that receives no further frames never
/// reaches the #16 loop-top guard — the only thing left in it is the
/// silence watchdog. Before the fix that watchdog was ungated: when its
/// budget ran out it fired `hub.expire(chatID:)` on the shared chat and
/// killed the NEWER run's listener, so the next answer never arrived. The
/// watchdog is now gated on the generation and on still owning `pending`,
/// and the budget is an instance knob so a test can actually wait it out.
@Test @MainActor func supersededResolveWatchdogDoesNotExpireTheNewerRun() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    // Park a run on an ask_user question (same fixture as #16's test).
    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }
    let call = try #require(conversation.turns.last?.awaitingCall)

    // The stale watchdog's whole budget. It is read when the resolve's drain
    // installs the timer, so it must be set before the resolve starts.
    conversation.silenceLimit = .milliseconds(300)

    conversation.resolve(
        messageID: firstID, call: call, action: .answer,
        answers: .object(["meal": .string("pizza")]))
    try await waitUntil { !transport.resolveBodies.isEmpty }
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "one"]))
    // Proof the resolve's drain is alive in the frame loop.
    try await waitUntil { conversation.turns.last?.text == "one" }

    // Supersede the resolve. Its drain keeps waiting for frames that never
    // come — no frame means no loop-top guard, so the watchdog is the only
    // thing in it that can still act.
    conversation.abandon()

    // Restore the production budget BEFORE run 2 starts: whatever fires
    // during this test can then only ever be the stale resolve's timer.
    conversation.silenceLimit = ConversationModel.silenceLimit

    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    let secondID = try #require(transport.assistantMessageID)
    // Run 2's listener and buffer are installed; now sit well past the stale
    // watchdog's budget. Pre-fix this is where `hub.expire(chatID:)` killed
    // run 2's listener and its answer never arrived.
    try await Task.sleep(for: .milliseconds(500))

    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    #expect(conversation.turns.last?.text == "two",
            "a stale resolve watchdog must not expire the newer run's listener: got \"\(conversation.turns.last?.text ?? "nil")\"")
    #expect(conversation.error == nil)
    #expect(conversation.phase == .ready)
}

/// The other side of #21's gates: they must not turn the silence watchdog
/// into a no-op. A CURRENT run that goes silent must still be expired —
/// same expectations as `aSilentStreamIsEndedRatherThanWaitingForever`,
/// which simulates the firing with a manual `hub.expire`; this one lets
/// the real watchdog do it on a short budget.
@Test @MainActor func silenceWatchdogStillExpiresTheRunItOwns() async throws {
    let (conversation, transport, _) = makePostFailureFixture(chatID: "chat-1")
    conversation.silenceLimit = .milliseconds(150)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    // No frames ever. The watchdog belongs to this run — generation current,
    // buffer owned — so it must still fire and settle the run with an error.
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }
    #expect(conversation.error != nil,
            "the watchdog of the run that owns the chat must still expire it")
    #expect(conversation.turns.last?.streaming == false)
}

/// #21's discriminating case: why `isCurrent(gen)` is needed ON TOP OF the
/// pending-id check. A stale resolve drain is superseded by a NEW resolve
/// on the SAME parked message id whose POST is still in flight (parked at
/// the transport's resolve gate). In that window the new resolve has its
/// hub listener installed but its drain has not installed a buffer yet,
/// and `abandon` does not clear `pending` — so a pending-id-only gate
/// walks straight into it: the stale watchdog's id check matches, the
/// shared chat expires, and the new resolve's listener dies before its
/// first frame. Only the generation gate closes this window.
@Test @MainActor func staleResolveWatchdogDoesNotExpireASlowNewResolve() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")

    conversation.draft = "book me a trip"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntil { conversation.phase == .ready }
    let call = try #require(conversation.turns.last?.awaitingCall)

    conversation.silenceLimit = .milliseconds(250)
    conversation.resolve(
        messageID: firstID, call: call, action: .answer,
        answers: .object(["meal": .string("pizza")]))
    try await waitUntil { !transport.resolveBodies.isEmpty }
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "one"]))
    try await waitUntil { conversation.turns.last?.text == "one" }

    // Supersede the first resolve. `abandon` bumps the generation but
    // leaves `pending` holding the first resolve's buffer for `firstID`.
    conversation.abandon()

    // Start a second resolve on the SAME message and park its POST inside
    // the transport: `resolve()` subscribes before the POST, so its
    // listener is live while `pending?.id` is still `firstID` — the exact
    // window the generation gate exists for.
    transport.gateNextResolve()
    conversation.resolve(
        messageID: firstID, call: call, action: .answer,
        answers: .object(["meal": .string("pasta")]))
    try await waitUntil { transport.isResolveGateParked }

    // Sit past the stale watchdog's budget with the new resolve's listener
    // alive and the id check matching.
    try await Task.sleep(for: .milliseconds(500))

    // Restore the production budget so the SECOND resolve's own watchdog
    // cannot fire while its frames are still on their way.
    conversation.silenceLimit = ConversationModel.silenceLimit
    transport.releaseResolve()
    try await waitUntil { transport.resolveBodies.count == 2 }
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: firstID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    // With the generation gate the second resolve's listener survived and
    // its own delta arrived. With only the pending-id gate the stale
    // watchdog expired the chat during the window and the second resolve's
    // stream closed before its first frame: the text would stay "one".
    #expect(conversation.turns.last?.text.contains("two") == true,
            "the new resolve's listener must survive a stale resolve's watchdog: got \"\(conversation.turns.last?.text ?? "nil")\"")
    #expect(conversation.error == nil)
}

/// Issue #4: `abandon` ended the run without publishing the pending buffer
/// and without expiring the hub. Text streamed between two flusher ticks was
/// lost from the transcript until a reload, and the abandoned run's hub
/// listener stayed registered indefinitely — with no newer run to trip the
/// #16 id guard, and the #21 generation-gated watchdog correctly never
/// firing for a superseded run, nothing ended the stream.
@Test @MainActor func abandonPublishesTheBufferAndEndsTheChatsStream() async throws {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    // Injected seam (#15): the drain's per-frame ribbon update is the only
    // deterministic signal that a delta reached `pending` while the flusher
    // is asleep (below) — `turns` cannot show buffered text by design.
    let ribbon = GenerationActivity()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub, activity: ribbon)
    // The flusher must never tick during this test: the only way text may
    // reach `turns` is `abandon`'s own publish. The instance knob (#11/#21
    // precedent) is read per tick, so arming it before the send puts the
    // drain's first sleep past the end of the test.
    conversation.flushInterval = .seconds(60)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let firstID = try #require(transport.assistantMessageID)
    try await waitUntil { hub.hasListener(for: "chat-1") }
    try await waitUntil { ribbon.activeChatID == "chat-1" }

    let updatesBefore = ribbon.acceptedUpdates
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: firstID,
        inner: ["type": "response.output_text.delta", "delta": "held text"]))
    // Proof the delta reached the buffer: the drain's per-frame ribbon update
    // fired. Proof it is still buffered: the sleeping flusher published
    // nothing, so the turn is the empty placeholder.
    try await waitUntil { ribbon.acceptedUpdates > updatesBefore }
    #expect(conversation.turns.last?.text == "",
            "the flusher is asleep; nothing may be on screen before abandon")

    conversation.abandon()
    // Acceptance 1: the buffer is published BEFORE `.ready` — the streamed
    // text is visible, the phase is ready, and the abandoned turn is settled
    // (no spinner): the streaming flag was cleared and the non-final publish
    // preserved it.
    #expect(conversation.phase == .ready)
    #expect(conversation.turns.last?.text == "held text")
    #expect(conversation.turns.last?.streaming == false)
    // Acceptance 2: the hub teardown. The abandoned run's listener is gone;
    // its drain wakes on the finished stream, final-flushes the same text
    // (id-gated, `pending` deliberately not nilled by abandon), and unwinds
    // generation-inert.
    #expect(!hub.hasListener(for: "chat-1"),
            "abandon must end the abandoned run's hub stream")

    // And the chat is reusable: a following send re-subscribes and streams
    // as if nothing had been abandoned.
    conversation.flushInterval = ConversationModel.flushInterval
    conversation.draft = "second"
    conversation.send()
    try await transport.awaitCompletion(2)
    try await waitUntil { hub.hasListener(for: "chat-1") }
    let secondID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: secondID,
        inner: ["type": "response.output_text.delta", "delta": "two"]))
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: secondID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) {
        conversation.turns.last?.text == "two" && conversation.phase == .ready
    }
    #expect(conversation.error == nil)
    // The abandoned turn kept its text and stayed settled throughout.
    let abandoned = try #require(conversation.turns.first { $0.id == firstID })
    #expect(abandoned.text == "held text")
    #expect(abandoned.streaming == false)
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

// MARK: - Issue #33: the drain watchdog is a silence detector, not a run cap

/// A chat detail whose tree carries the assistant's message already written
/// and `done: true` — the shape the server has once the run finished on its
/// side. Used by the #33 tests to make the reconcile fallback observable:
/// text that only exists here could only have arrived via the record, not
/// the live stream.
private func chatDetailWithStoredAnswer(_ chatID: String, messageID: String, text: String) -> Data {
    Data("""
    {"id":"\(chatID)","title":"t","updated_at":1,"created_at":1,
     "chat":{"models":["local-personal"],"history":{"currentId":"\(messageID)","messages":{
       "user-1":{"id":"user-1","role":"user","content":"go","done":true,"parentId":null,"childrenIds":["\(messageID)"]},
       "\(messageID)":{"id":"\(messageID)","role":"assistant","content":"\(text)","model":"local-personal","done":true,"parentId":"user-1","childrenIds":[]}}}}}
    """.utf8)
}

/// Issue #33: the watchdog was installed once per drain and never re-armed,
/// so it was an absolute cap on live streaming — any run longer than
/// `silenceLimit` got `hub.expire(chatID:)` fired at it mid-generation while
/// tokens were still flowing, and fell into the chunky reconcile fallback
/// (truncated text, false banners) even though the server was writing every
/// word. A steady trickle of frames for THIS message must keep the live
/// stream alive indefinitely: each frame re-arms the budget.
@Test @MainActor func steadyFramesKeepTheStreamAlivePastTheSilenceLimit() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    // The budget is read when the drain installs its timer, so it must be
    // set before the run starts (instance-knob contract from #21).
    conversation.silenceLimit = .milliseconds(300)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    // Ten deltas ~90 ms apart: ~900 ms of wall time, three times the
    // watchdog budget, with a gap no wider than a third of it. Pre-fix the
    // watchdog fires at 300 ms regardless of the frames, the live listener
    // dies, and the text truncates.
    var expected = ""
    for i in 0..<10 {
        hub.receive(Frame.fixture(
            kind: "response:completion", chatID: "chat-1", messageID: id,
            inner: ["type": "response.output_text.delta", "delta": "t\(i)-"]))
        expected += "t\(i)-"
        // Per-frame proof the live stream is still publishing this run's text.
        // 5 s, not the 2 s default: publishing is main-actor work (drain
        // consuming the frame, then the 60 ms flusher) and on a loaded CI
        // runner that queues behind every other @MainActor test, so the tight
        // default flakes with no real defect. Matches the phase waits below.
        try await waitUntil(timeout: .seconds(5)) { conversation.turns.last?.text == expected }
        try await Task.sleep(for: .milliseconds(90))
    }
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: id,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }

    #expect(conversation.turns.last?.text == expected,
            "a run with steady frames must stream live past the silence limit, not be expired: got \"\(conversation.turns.last?.text ?? "nil")\"")
    #expect(conversation.error == nil,
            "a healthy long run must not fall into the reconcile fallback: \(conversation.error ?? "nil")")
}

/// The other side of #33: re-arming must not turn the watchdog into a no-op.
/// One frame proves the run was alive and buys exactly one more budget; when
/// nothing follows it, the watchdog still fires and the run settles via the
/// reconcile fallback on what the server stored. The stored text grows past
/// the streamed text, so landing it proves the record — not the live stream —
/// ended the run.
@Test @MainActor func oneFrameThenSilenceStillExpiresIntoTheStoredAnswer() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    conversation.silenceLimit = .milliseconds(200)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)
    // The server finishes writing the full answer on its side; only the
    // reconcile fetch can bring it here.
    transport.chatDetailOverride =
        chatDetailWithStoredAnswer("chat-1", messageID: id, text: "partial answer.")

    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: id,
        inner: ["type": "response.output_text.delta", "delta": "partial "]))
    // 5 s for the main-actor-scheduling reason documented in the ten-frame
    // test above (the CI runner starves the drain + flusher past 2 s).
    try await waitUntil(timeout: .seconds(5)) { conversation.turns.last?.text == "partial " }

    // Then silence. The frame re-armed the watchdog once; the re-armed timer
    // must still fire.
    try await waitUntil(timeout: .seconds(5)) { conversation.phase == .ready }
    let row = try #require(conversation.turns.first { $0.id == id })
    #expect(row.text == "partial answer.",
            "a run that goes silent after one frame must still settle via the stored record: got \"\(row.text)\"")
    #expect(!row.streaming)
    #expect(conversation.error == nil,
            "an answer that landed off the record is not an empty answer: \(conversation.error ?? "nil")")
}

/// Issue #33's filter rule: only frames for THIS run's message re-arm the
/// watchdog. Frames for another message id on the same chat are already
/// filtered out of the drain's accounting (`sawAnyFrame` ignores them, #9);
/// they must not buy the run silence budget either, or a chatty neighbour
/// would keep a dead run's listener alive forever. The pace below (a frame
/// every ~70 ms against a 250 ms budget) would keep a re-arming watchdog
/// permanently unarmed if foreign frames counted — the run must still fall
/// back to reconcile on schedule.
@Test @MainActor func foreignFramesDoNotReArmTheSilenceWatchdog() async throws {
    let (conversation, transport, hub) = makePostFailureFixture(chatID: "chat-1")
    conversation.silenceLimit = .milliseconds(250)

    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)
    transport.chatDetailOverride =
        chatDetailWithStoredAnswer("chat-1", messageID: id, text: "partial answer.")

    // One frame for THIS message — the run is genuinely live and the
    // watchdog is armed from it.
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: id,
        inner: ["type": "response.output_text.delta", "delta": "partial "]))
    // 5 s for the main-actor-scheduling reason documented in the ten-frame
    // test above (the CI runner starves the drain + flusher past 2 s).
    try await waitUntil(timeout: .seconds(5)) { conversation.turns.last?.text == "partial " }

    // Then ONLY FOREIGN frames, faster than the budget, for ~1.4 s — far
    // beyond silenceLimit. This is the discriminator: the fixed code must
    // settle ~silenceLimit after the last OWN frame, i.e. WHILE the foreign
    // burst is still arriving. If foreign frames re-armed, the watchdog
    // would only fire after the burst ended (~1.4 s + budget), past the
    // 1 s ceiling below — so a regression fails on the timeout, not on the
    // text assertions.
    let burst = Task { @MainActor in
        for _ in 0..<20 {
            hub.receive(Frame.fixture(
                kind: "response:completion", chatID: "chat-1", messageID: "some-other-message",
                inner: ["type": "response.output_text.delta", "delta": "foreign-"]))
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    try await waitUntil(timeout: .seconds(1)) { conversation.phase == .ready }
    await burst.value
    let row = try #require(conversation.turns.first { $0.id == id })
    #expect(row.text == "partial answer.",
            "foreign frames must not keep this run's live listener alive: the run must fall back to the record: got \"\(row.text)\"")
    #expect(row.text.contains("foreign") == false,
            "a foreign frame's text must never reach this message: \(row.text)")
    #expect(conversation.error == nil,
            "settling on the stored record is not a failure: \(conversation.error ?? "nil")")
}

// MARK: - session-run preferences (issue #35)

/// A conversation wired like every other test here, but sharing a caller-owned
/// `RunPreferences` so stickiness across chats is observable.
@MainActor
private func prefsConversation(
    models: [ChatModel], incognito: Bool = false, prefs: RunPreferences
) -> ConversationModel {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    return ConversationModel(
        chatID: nil, models: models, incognito: incognito,
        client: OWUIClient(server: server, transport: ScriptedTransport()),
        hub: ChatEventHub(server: server),
        prefs: prefs)
}

@Test @MainActor func aFeatureSwitchedOnInOneChatSticksAcrossChats() {
    // image_generation is the one toggle seedFeatures never seeds, so a true
    // in chat B can only come from the session intent.
    let model = ChatModel.stub("m1", caps: ["image_generation": true, "web_search": true])
    let prefs = RunPreferences()
    let a = prefsConversation(models: [model], prefs: prefs)
    #expect(a.features[ChatFeature.imageGeneration.rawValue] == nil)
    a.setFeature(ChatFeature.imageGeneration.rawValue, on: true)
    #expect(a.features[ChatFeature.imageGeneration.rawValue] == true)

    let b = prefsConversation(models: [model], prefs: prefs)
    #expect(b.features[ChatFeature.imageGeneration.rawValue] == true,
            "a feature switched on this session must be on in the next chat too")
}

@Test @MainActor func aFeatureSwitchedOffInOneChatStaysOffInLaterChats() {
    let model = ChatModel.stub("m2", caps: ["web_search": true])
    let prefs = RunPreferences()
    let a = prefsConversation(models: [model], prefs: prefs)
    #expect(a.features[ChatFeature.webSearch.rawValue] == true, "seeded on by the capability")
    a.setFeature(ChatFeature.webSearch.rawValue, on: false)
    #expect(a.features[ChatFeature.webSearch.rawValue] == false)

    let b = prefsConversation(models: [model], prefs: prefs)
    #expect(b.features[ChatFeature.webSearch.rawValue] == false,
            "the seed says on, the session says off — the session wins")
}

@Test @MainActor func aToolSwitchedOffStaysOffWhenTheNextChatSeeds() {
    let prefs = RunPreferences()
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let a = ConversationModel(
        chatID: nil, client: OWUIClient(server: server, transport: ScriptedTransport()),
        hub: ChatEventHub(server: server), prefs: prefs)
    a.seedTools(defaultIDs: ["pdf", "reader"])
    #expect(a.tools == ["pdf", "reader"])
    a.setTool("pdf", on: false)
    #expect(a.tools == ["reader"])

    let b = ConversationModel(
        chatID: nil, client: OWUIClient(server: server, transport: ScriptedTransport()),
        hub: ChatEventHub(server: server), prefs: prefs)
    b.seedTools(defaultIDs: ["pdf", "reader"])
    #expect(b.tools == ["reader"], "the pref-false pdf must not come back in a new chat")
}

@Test @MainActor func aSessionFeatureTheModelDoesNotSupportStaysAbsentNotFalse() {
    // The send path ships `features` wholesale; a key the model never
    // advertised must not ride along, not even as a false.
    let prefs = RunPreferences()
    prefs.features[ChatFeature.webSearch.rawValue] = true
    let unsupported = ChatModel.stub("no-web", caps: ["vision": true])
    let b = prefsConversation(models: [unsupported], prefs: prefs)
    #expect(b.features[ChatFeature.webSearch.rawValue] == nil,
            "unsupported pref-true must stay absent: \(b.features)")
}

@Test @MainActor func incognitoKeepsMemoryOutOfTheOverlay() {
    // seedFeatures keeps memory out of incognito chats; the session overlay
    // must not smuggle it back in.
    let prefs = RunPreferences()
    prefs.features[ChatFeature.memory.rawValue] = true
    let model = ChatModel.stub("mem", caps: ["memory": true])
    let b = prefsConversation(models: [model], incognito: true, prefs: prefs)
    #expect(b.features[ChatFeature.memory.rawValue] == nil,
            "a chat that leaves no trace does not remember: \(b.features)")
}

@Test @MainActor func incognitoDoesNotWriteMemoryOrSearchIntoTheSessionEither() {
    // The mirror of the overlay guard on the WRITE side: toggling memory or
    // web_search on inside an incognito chat updates that chat only — the
    // session intent must stay clean, or the intent would land in every
    // later normal chat.
    let prefs = RunPreferences()
    let model = ChatModel.stub("mem", caps: ["memory": true, "web_search": true])
    let b = prefsConversation(models: [model], incognito: true, prefs: prefs)
    b.setFeature(ChatFeature.memory.rawValue, on: true)
    b.setFeature(ChatFeature.webSearch.rawValue, on: true)
    #expect(b.features[ChatFeature.memory.rawValue] == true,
            "the incognito chat itself still honours the toggle")
    #expect(prefs.features[ChatFeature.memory.rawValue] == nil)
    #expect(prefs.features[ChatFeature.webSearch.rawValue] == nil)
    // A non-excluded feature still writes through from an incognito chat.
    b.setFeature(ChatFeature.codeInterpreter.rawValue, on: true)
    #expect(prefs.features[ChatFeature.codeInterpreter.rawValue] == true)
}

@Test @MainActor func aSessionToolNeedingSignInIsNotSeeded() {
    // An unauthenticated MCP server cannot serve anything; seeding it on
    // would put a broken tool in every request.
    let prefs = RunPreferences()
    prefs.tools["server:mcp:1"] = true
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let b = ConversationModel(
        chatID: nil, client: OWUIClient(server: server, transport: ScriptedTransport()),
        hub: ChatEventHub(server: server), prefs: prefs)
    b.seedTools(defaultIDs: [], available: [(id: "server:mcp:1", available: true, needsAuth: true)])
    #expect(b.tools.isEmpty, "needsAuth gates the pref-true: \(b.tools)")
}

@Test @MainActor func selectingAModelReseedsFromTheModelNotTheSession() {
    // Pinned behavior: a model change means "this model's defaults", so the
    // session overlay is deliberately NOT applied there.
    let prefs = RunPreferences()
    let first = ChatModel.stub("first", caps: ["web_search": true])
    let second = ChatModel.stub("second", caps: ["memory": true])
    let a = prefsConversation(models: [first], prefs: prefs)
    a.setFeature(ChatFeature.webSearch.rawValue, on: false)
    let prefsBefore = prefs.features

    a.select(model: "second", from: [first, second])
    #expect(a.features == ConversationModel.seedFeatures(for: second, incognito: false),
            "the reseed is the new model's pure seed: \(a.features)")
    #expect(a.features[ChatFeature.webSearch.rawValue] == nil)
    #expect(prefs.features == prefsBefore, "reseeding must not rewrite the session intent")
}

/// A credential store that forgets everything, so the test never touches the
/// real keychain.
private struct NoopCredentials: CredentialStore {
    func readToken() -> String? { "token-1" }
    func writeToken(_ token: String) {}
    func readPassword() -> String? { nil }
    func writePassword(_ password: String) {}
    func clearPassword() {}
    func clearAll() {}
}

@Test @MainActor func runPreferencesSurviveATokenRefreshButNotAServerChange() {
    let suite = "runprefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = SessionStore(credentials: NoopCredentials(), defaults: defaults)
    session.setURL("https://a.invalid")
    let first = session.runPreferences()
    #expect(session.runPreferences() === first, "one instance per server")

    // A token refresh changes the token, not the server: the user's toggles
    // from five minutes ago are still their toggles.
    session.signOut()  // clears the token in place; baseURL untouched
    #expect(session.runPreferences() === first,
            "a token change must not throw away the session's intent")

    session.setURL("https://b.invalid")
    #expect(session.runPreferences() !== first,
            "another instance's tools and features are not these ones")
}
