import Foundation
import Testing

@testable import TiAiKit

private typealias Frame = ChatEventSocket.Frame

/// The offline outbox (issue #38): a send pressed with no connection is kept on
/// the phone and replayed when the connection comes back, and it is never sent
/// twice.
///
/// Everything here is driven the way the rest of the suite drives a run — a
/// scripted transport, frames fed into the hub by hand, no network. The one new
/// ingredient is a `UserDefaults` suite per test: the store's whole promise is
/// that it survives the app, and a second store built on the same suite *is*
/// that relaunch, with no fake filesystem in between to argue about.
///
/// The tests split into the three promises the feature makes. Capture: an
/// offline send becomes an entry and not a red banner (which is the issue #9
/// rollback's job and must stay its job). Replay: an entry goes out once, and
/// only once, when the chat is free. Durability: an entry outlives the store,
/// the run, and the attempts it has.

private let testServer = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")

/// A fresh durable store plus the suite name, so the test can clean up after
/// itself. Every test gets its own suite: entries are keyed by host, and two
/// tests sharing a suite would read each other's pending messages.
@MainActor
private func freshOutbox(host: String = "test.invalid") -> (store: OutboxStore, suite: String) {
    let suite = "outbox-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (OutboxStore(defaults: defaults, host: host), suite)
}

@MainActor
private func makeOutboxConversation(
    chatID: String? = "chat-1",
    incognito: Bool = false,
    transport: ScriptedTransport,
    hub: ChatEventHub,
    outbox: OutboxStore,
    queues: MessageQueueStore = MessageQueueStore()
) -> ConversationModel {
    ConversationModel(
        chatID: chatID,
        models: [ChatModel.stub("local-personal")],
        incognito: incognito,
        client: OWUIClient(server: testServer, transport: transport),
        hub: hub,
        // A ribbon singleton shared between tests would make two models in one
        // test fight over one Live Activity; this is the established seam.
        activity: GenerationActivity(),
        queues: queues,
        outbox: outbox)
}

@MainActor
private func makeOutboxFixture(
    chatID: String? = "chat-1"
) async throws -> (
    ConversationModel, ScriptedTransport, ChatEventHub, OutboxStore, MessageQueueStore, String
) {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let outbox = freshOutbox()
    let queues = MessageQueueStore()
    let conversation = makeOutboxConversation(
        chatID: chatID, transport: transport, hub: hub, outbox: outbox.store, queues: queues)
    return (conversation, transport, hub, outbox.store, queues, outbox.suite)
}

private enum OutboxProbeFailure: Error { case timeout }

@MainActor
private func waitUntilOutbox(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw OutboxProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Presses send and waits for the run to be over, however it ended.
@MainActor
private func sendAndSettle(_ conversation: ConversationModel, _ text: String) async throws {
    conversation.draft = text
    conversation.send()
    try await waitUntilOutbox { conversation.phase == .ready }
}

/// A transcript whose only message has the given id — the fixture for "the
/// server already has this message".
private func transcriptWithUserMessage(id: String, text: String) -> Data {
    Data(
        """
        {"id":"chat-1","title":"New Chat","updated_at":1,"created_at":1,
         "chat":{"models":["local-personal"],"history":{"currentId":"\(id)","messages":{
           "\(id)":{"id":"\(id)","role":"user","content":"\(text)","parentId":null,
                    "childrenIds":[],"timestamp":1760000000}}}}}
        """.utf8)
}

/// The user-message id the (n+1)th completion POST carried, read back out of
/// the recorded body — the id the entry has to carry for the dedup to mean
/// "this send", not "a send that reads the same".
private func userMessageID(inBody body: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let userMessage = json["user_message"] as? [String: Any]
    else { return nil }
    return userMessage["id"] as? String
}

// MARK: - 1: capture

@Test @MainActor func anOfflineSendIsParkedInsteadOfRolledBack() async throws {
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")

    try await sendAndSettle(conversation, "write this when I have signal")

    // The whole point: a message that will be sent is not an error. `recordPostError`
    // stamped a red banner before the fork ran, so an outbox arm that forgot to
    // clear it would show "Could not send" *and* "will send" about one message.
    #expect(conversation.error == nil,
            "the outbox strip is the affordance; the red banner must be gone: \(conversation.error ?? "nil")")
    #expect(conversation.turns.isEmpty, "the phantom turns are still rolled back")
    #expect(conversation.phase == .ready)
    // …and rolled back to the *outbox*, not to the composer: putting the text
    // back would let it be sent a second time by hand and a first time by the
    // replay.
    #expect(conversation.draft.isEmpty, "the text belongs to the outbox now, not the composer")
    #expect(queues.queue(for: "chat-1").isEmpty, "the in-memory #37 queue is a different promise")
    #expect(outbox.entries(for: "chat-1").map(\.text) == ["write this when I have signal"])
    #expect(conversation.pendingOutbox.map(\.text) == ["write this when I have signal"])

    // The dedup key is the id that went on the wire, not one invented afterwards.
    let entry = try #require(outbox.entries(for: "chat-1").first)
    let wire = try #require(transport.completionBodies.first)
    #expect(entry.userMessageID == userMessageID(inBody: wire),
            "the entry must carry the id the server was given, or the dedup cannot recognise it")
}

@Test @MainActor func aNonTransientFailureKeepsTheIssue9Rollback() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    // A 400 is the server refusing the message. Retrying it is refusing it
    // again, so this is the #9 rollback's case and always will be.
    transport.completionFailure = APIError.http(status: 400, message: "bad request")

    try await sendAndSettle(conversation, "no")

    #expect(outbox.isEmpty, "a refused message must not sit in the outbox forever")
    #expect(conversation.draft == "no", "and the composer still gets it back")
    let error = try #require(conversation.error)
    #expect(error.contains("Could not send"), "\(error)")
    #expect(error.contains("back in the composer"), "\(error)")
}

@Test @MainActor func theFlagOffIsByteIdenticalToTheRollback() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    conversation.outboxOverride = false
    transport.completionFailure = APIError.unreachable("connection reset")

    try await sendAndSettle(conversation, "write this when I have signal")

    #expect(outbox.isEmpty)
    #expect(conversation.draft == "write this when I have signal")
    #expect(conversation.error?.contains("Could not send") == true)
    #expect(conversation.pendingOutbox.isEmpty)
}

@Test @MainActor func aSendWithAttachmentsFallsBackToTheRollback() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")

    conversation.draft = "look at this"
    conversation.attach(
        data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    try await waitUntilOutbox { conversation.attachments.count == 1 }
    conversation.send()
    try await waitUntilOutbox { conversation.phase == .ready }

    // An attachment has no file id until its upload answers, and offline that
    // never happens — so there is nothing durable to store, and the #9 restore
    // (which puts the file back in the composer) is the honest answer.
    #expect(outbox.isEmpty)
    #expect(conversation.draft == "look at this")
    #expect(conversation.attachments.count == 1)
}

@Test @MainActor func aNewChatOfflineKeepsTheIssue9Rollback() async throws {
    let (conversation, transport, _, outbox, _, suite) =
        try await makeOutboxFixture(chatID: nil)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")

    try await sendAndSettle(conversation, "first message, no signal")

    // A brand-new chat has no id to key an entry under, and its offline failure
    // happens earlier than the fork, in `ensureChat`. Out of scope; the rollback
    // stays.
    #expect(outbox.isEmpty)
    #expect(conversation.draft == "first message, no signal")
}

// MARK: - 2: replay

@Test @MainActor func aReconnectReplaysTheEntryOnceAndClearsIt() async throws {
    let (conversation, transport, hub, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    try await sendAndSettle(conversation, "the pending question")
    transport.completionFailure = nil

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("the pending question"), "the replay carries the entry's text")
    // One run, not two: the replay is a send, so it owns the transcript the way
    // any send does.
    #expect(conversation.turns.filter { $0.role == "user" }.count == 1)

    // The entry is spent once the server has demonstrably heard it — here, the
    // first frame carrying the answer.
    let assistant = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistant, answer: "ok") {
        hub.receive(frame)
    }
    try await waitUntilOutbox { conversation.phase == .ready }
    #expect(outbox.isEmpty, "a message the server answered is not pending any more")
    #expect(conversation.pendingOutbox.isEmpty)
}

@Test @MainActor func aParkedReplayStillClearsTheEntry() async throws {
    let (conversation, transport, hub, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    try await sendAndSettle(conversation, "book me a trip")
    transport.completionFailure = nil
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 2 }
    let assistant = try #require(transport.assistantMessageID)
    // A delta-less `ask_user` parks the run, and the parked path returns before
    // the end-of-run epilogue. The entry has to be gone anyway: the server has
    // the message, which is the only question the dedup asks.
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistant,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))
    try await waitUntilOutbox { conversation.phase == .ready }

    #expect(outbox.isEmpty,
            "a replay that parked on a question has been sent; keeping it sends it twice")
    #expect(conversation.turns.last?.awaitingCall?.name == "ask_user")
}

@Test @MainActor func aReplayThatFailsAgainReParksAndNeverTouchesTheQueue() async throws {
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    try await sendAndSettle(conversation, "still not sent")

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 2 }
    try await waitUntilOutbox { conversation.phase == .ready }

    // The mis-land this pins: a replay goes out through `beginRun(.taken)`, so
    // `queuedRun` is true, and without the replay marker its failure would fall
    // into `putBackInQueue` — the in-memory queue, which loses the message on
    // the next force-quit and draws a queue strip for a chat that is not
    // generating.
    #expect(queues.queue(for: "chat-1").isEmpty, "a failed replay must not be handed to the #37 queue")
    #expect(conversation.draft.isEmpty, "nor to the composer")
    #expect(conversation.error == nil, "and it is still not an error")
    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.text) == ["still not sent"], "it re-parks, durably")
    #expect(entries.first?.attempts == 1, "and the attempt counts")
    #expect(entries.first?.replaying == false, "and it is waiting, not in flight")
}

@Test @MainActor func aReplayThatRunsOutOfAttemptsGoesBackToTheComposer() async throws {
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    try await sendAndSettle(conversation, "three strikes")
    let entry = try #require(outbox.entries(for: "chat-1").first)
    // Two failures already spent, so the next one is the last.
    outbox.revertToPending(id: entry.id, burnsAttempt: true)
    outbox.revertToPending(id: entry.id, burnsAttempt: true)

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 2 }
    try await waitUntilOutbox { conversation.phase == .ready }

    // The #9 fallback, unchanged: after this there is nothing left to try, and
    // the message becomes the reader's problem again instead of a strip that
    // will never clear.
    #expect(outbox.isEmpty)
    #expect(queues.queue(for: "chat-1").isEmpty)
    #expect(conversation.draft == "three strikes")
    let error = try #require(conversation.error)
    #expect(error.contains("Could not send"), "\(error)")
    #expect(error.contains("back in the composer"), "\(error)")
}

@Test @MainActor func aReplayRefusesToSupersedeALiveRun() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    outbox.add(chatID: "chat-1", userMessageID: "pending-1", text: "queued while away")

    // A run the user started by hand, still open inside the transport.
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }
    conversation.draft = "the live one"
    conversation.send()
    try await transport.awaitCompletion()
    #expect(conversation.phase.isBusy)

    conversation.replayOutboxIfNeeded()
    try await Task.sleep(for: .milliseconds(120))

    // `beginRun` has no phase guard of its own, so the gate has to be here: a
    // replay that claimed and then began would bump the generation and eat the
    // run in flight.
    #expect(transport.completionBodies.count == 1, "no second completion behind a live run")
    #expect(conversation.turns.contains { $0.text == "the live one" })
    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.text) == ["queued while away"])
    #expect(entries.first?.replaying == false, "and it was not even claimed")
}

@Test @MainActor func twoTriggersInOneTickSendExactlyOneCompletion() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    try await sendAndSettle(conversation, "one message, two cues")
    transport.completionFailure = nil

    // A reconnect that is also a foreground is the normal case, and both cues
    // fire in the same main-actor turn.
    conversation.replayOutboxIfNeeded()
    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 2 }
    try await Task.sleep(for: .milliseconds(120))

    #expect(transport.completionBodies.count == 2,
            "the claim is the mutex: two triggers, one completion")
    #expect(outbox.entries(for: "chat-1").count == 1, "still in flight, so still there")
}

// MARK: - 3: durability and dedup

@Test @MainActor func anEntrySurvivesTheStoreThatWroteIt() async throws {
    let outbox = freshOutbox()
    defer { UserDefaults.standard.removePersistentDomain(forName: outbox.suite) }
    let defaults = UserDefaults(suiteName: outbox.suite)!
    outbox.store.add(chatID: "chat-1", userMessageID: "u-1", text: "typed before the crash")

    // A second store on the same suite *is* the relaunch: same host, same
    // process, nothing in common with the first but the bytes on disk.
    let relaunched = OutboxStore(defaults: defaults, host: "test.invalid")
    let entries = relaunched.entries(for: "chat-1")
    #expect(entries.map(\.text) == ["typed before the crash"])
    #expect(entries.first?.userMessageID == "u-1")

    // And a fresh model can do the only thing that matters with it: send it.
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeOutboxConversation(transport: transport, hub: hub, outbox: relaunched)
    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    let body = String(decoding: try #require(transport.completionBody), as: UTF8.self)
    #expect(body.contains("typed before the crash"))
}

@Test @MainActor func aMessageAlreadyInTheTranscriptIsNotSentAgain() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    outbox.add(chatID: "chat-1", userMessageID: "u-landed", text: "it did go through")
    // The server has the message — the app just never heard the answer.
    transport.chatDetailOverride = transcriptWithUserMessage(id: "u-landed", text: "it did go through")

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { outbox.isEmpty }

    #expect(transport.completionBodies.isEmpty,
            "a message the transcript already has must not be asked twice")
    #expect(conversation.turns.map(\.text) == ["it did go through"],
            "and the transcript it refetched is shown instead")
}

@Test @MainActor func dedupIsByIdSoTheSameTextTwiceStillSends() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    // Two entries, identical text, different ids: "ok" typed twice in a chat is
    // two messages, and a dedup that reads text would eat the second one.
    outbox.add(chatID: "chat-1", userMessageID: "u-first", text: "ok")
    outbox.add(chatID: "chat-1", userMessageID: "u-second", text: "ok")
    transport.chatDetailOverride = transcriptWithUserMessage(id: "u-first", text: "ok")

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }

    let body = String(decoding: try #require(transport.completionBody), as: UTF8.self)
    #expect(body.contains("ok"))
    #expect(outbox.entries(for: "chat-1").map(\.userMessageID) == ["u-second"],
            "the first was deduped by its id; the second has a different one")
    #expect(userMessageID(inBody: try #require(transport.completionBody)) == "u-second",
            "and it goes out under its own id, so the next dedup can tell them apart")
}

@Test @MainActor func aReplayWhoseDedupCheckCannotBeMadeDoesNotBurnAnAttempt() async throws {
    // The rule under test: a replay that could not check the transcript has not
    // been refused by anything, so it must not spend an attempt. Counting those
    // is how a long flight with three app foregrounds empties the outbox into
    // the composer with a red banner on every message in it.
    //
    // The check is made to fail with an unreadable response rather than a real
    // offline transport on purpose: `OWUIClient` rides a six-try ladder over
    // ~17 s for anything that smells like a connectivity failure, and the ladder
    // is not what this pins — the fact that no answer came back is.
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    transport.chatDetailOverride = Data("this is not a chat".utf8)
    try await sendAndSettle(conversation, "on a long flight")
    #expect(outbox.entries(for: "chat-1").first?.attempts == 0)

    // Five triggers, five failed attempts, none of them the server's answer.
    for trigger in 1...5 {
        conversation.replayOutboxIfNeeded()
        try await waitUntilOutbox { transport.completionBodies.count == 1 + trigger }
        try await waitUntilOutbox { conversation.phase == .ready }
    }

    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.text) == ["on a long flight"],
            "five offline attempts, zero of them the server's answer")
    #expect(entries.first?.attempts == 0, "and none of them counted")
    #expect(conversation.error == nil)
}

@Test @MainActor func deletingAChatTakesItsPendingMessagesWithIt() throws {
    let outbox = freshOutbox()
    defer { UserDefaults.standard.removePersistentDomain(forName: outbox.suite) }
    outbox.store.add(chatID: "chat-1", userMessageID: "u-1", text: "for the doomed chat")
    outbox.store.add(chatID: "chat-1", userMessageID: "u-2", text: "also doomed")
    outbox.store.add(chatID: "chat-2", userMessageID: "u-3", text: "for another chat")

    outbox.store.removeAll(for: "chat-1")

    #expect(outbox.store.entries(for: "chat-1").isEmpty)
    #expect(outbox.store.entries(for: "chat-2").map(\.text) == ["for another chat"],
            "one chat's deletion is not the other's")
}

// MARK: - 4b: the review findings (dedup under a live run, cancel mid-flight, incognito, two models)

@Test @MainActor func aDedupHitRefusesToOverwriteALiveRun() async throws {
    // The refetch is a real await: the user can press send while it is in
    // flight, and a dedup hit that then applies the refetched transcript would
    // replace a live run's turns, rewind its leaf and swap its model from
    // under it — the exact mid-run-supersede class #19/#26 closed. The
    // non-dedup path already re-checks `phase == .ready` before `beginRun`;
    // the dedup path must re-check it before `apply`.
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    outbox.add(chatID: "chat-1", userMessageID: "u-landed", text: "it did go through")
    transport.chatDetailOverride = transcriptWithUserMessage(id: "u-landed", text: "it did go through")
    transport.gateNextChatFetch()

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.isChatFetchGateParked }

    // The dedup refetch is parked; the user sends by hand. The run is live
    // inside the transport when the refetch finally returns its landed
    // transcript.
    transport.gateNextCompletion()
    defer { transport.releaseCompletion() }
    conversation.draft = "the live one"
    conversation.send()
    try await transport.awaitCompletion()
    #expect(conversation.phase.isBusy)

    transport.releaseChatFetchGate()
    try await waitUntilOutbox { outbox.entries(for: "chat-1").first?.replaying == false }
    try await Task.sleep(for: .milliseconds(120))

    #expect(conversation.turns.contains { $0.text == "the live one" },
            "the live run's transcript must survive the dedup hit")
    #expect(!conversation.turns.contains { $0.text == "it did go through" },
            "the refetched transcript must not be swapped in under a live run")
    #expect(transport.completionBodies.count == 1,
            "the dedup hit must not send anything either — the bail is total")
    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.userMessageID) == ["u-landed"], "the entry reverts to pending")
    #expect(entries.first?.attempts == 0, "and a bailed check does not burn an attempt")
}

@Test @MainActor func cancellingDuringTheReplayRefetchDoesNotSendTheMessage() async throws {
    // Cancel during the refetch window: the marker clears and the entry is
    // gone, but `replay()` used to never re-check that the entry still exists
    // — it proceeded to `beginRun` and sent the cancelled text.
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let entry = outbox.add(chatID: "chat-1", userMessageID: "u-cancel-refetch", text: "never mind")
    transport.gateNextChatFetch()

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.isChatFetchGateParked }

    conversation.cancelOutbox(id: entry.id)
    transport.releaseChatFetchGate()
    try await Task.sleep(for: .milliseconds(150))

    #expect(transport.completionBodies.isEmpty,
            "a cancelled message must not go out behind the refetch that was checking it")
    #expect(outbox.isEmpty)
    #expect(queues.queue(for: "chat-1").isEmpty, "nor reappear in the queue")
    #expect(conversation.draft.isEmpty, "nor in the composer")
    #expect(conversation.error == nil, "a cancellation is not an error")
    #expect(conversation.phase == .ready)
}

@Test @MainActor func cancellingDuringTheReplayPostDoesNotResurrectTheMessage() async throws {
    // Cancel during the replay POST: the marker used to be dropped here, so
    // the POST's failure fell through the fork's outbox arm (blocked by
    // `queuedRun`) into the #9 arm — `putBackInQueue` — and the just-cancelled
    // message was drained and sent. A gone entry must mean "discard this run".
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    transport.completionFailure = APIError.unreachable("connection reset")
    let entry = outbox.add(chatID: "chat-1", userMessageID: "u-cancel-post", text: "cancelled mid-flight")
    transport.gateNextCompletion()

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }

    conversation.cancelOutbox(id: entry.id)
    transport.releaseCompletion()
    try await waitUntilOutbox { conversation.phase == .ready }

    #expect(queues.queue(for: "chat-1").isEmpty,
            "a cancelled replay must not hand its message to the #37 queue")
    #expect(conversation.draft.isEmpty, "nor to the composer")
    #expect(conversation.error == nil, "and it must not leave a banner behind")
    #expect(outbox.isEmpty)
    #expect(conversation.turns.isEmpty, "the replay's phantom turns are gone with it")
    try await Task.sleep(for: .milliseconds(120))
    #expect(transport.completionBodies.count == 1, "and nothing goes out afterwards")
}

@Test @MainActor func anIncognitoOfflineSendKeepsTheIssue9Rollback() async throws {
    // Incognito sends get a derived `temporary:<sid>` chat id, so the
    // `chatID != nil` capture gate passes and an offline incognito send used
    // to park its text in UserDefaults — violating the incognito promise.
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture(chatID: nil)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    conversation.incognito = true
    // The seam that stands in for the socket's sid, without which `ensureChat`
    // cannot build the `temporary:` id this bug needs.
    conversation.incognitoSessionIDOverride = "sid-1"
    transport.completionFailure = APIError.unreachable("connection reset")

    try await sendAndSettle(conversation, "nothing here is saved")

    #expect(outbox.entries.isEmpty,
            "an incognito send must never reach the durable store: \(outbox.entries.map(\.text))")
    #expect(conversation.draft == "nothing here is saved", "today's #9 rollback instead")
    #expect(conversation.error?.contains("Could not send") == true)
}

@Test @MainActor func twoModelsOnOneChatReplayTheEntryOnlyOnce() async throws {
    // Two `ConversationModel`s bound to the same chat (navigation pushing the
    // same chat twice) share the store, and `claimNext` ignored `replaying`,
    // so both could claim and send the same entry without a user gesture. The
    // fix is a per-store in-process claim set; a *fresh* process must still
    // recover a force-quit `.replaying` entry, so the set is memory-only.
    let outbox = freshOutbox()
    defer { UserDefaults.standard.removePersistentDomain(forName: outbox.suite) }
    outbox.store.add(chatID: "chat-1", userMessageID: "u-once", text: "replayed once")
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let first = makeOutboxConversation(transport: transport, hub: hub, outbox: outbox.store)
    let second = makeOutboxConversation(transport: transport, hub: hub, outbox: outbox.store)

    first.replayOutboxIfNeeded()
    second.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    try await Task.sleep(for: .milliseconds(120))

    #expect(transport.completionBodies.count == 1,
            "one entry, one completion: a claimed entry is not claimable by a second model in-process")
    #expect(userMessageID(inBody: try #require(transport.completionBody)) == "u-once")

    // And the recovery semantics survive: a second store on the same suite is
    // a force-quit and relaunch, and must be able to retry the in-flight entry.
    let defaults = UserDefaults(suiteName: outbox.suite)!
    let relaunched = OutboxStore(defaults: defaults, host: "test.invalid")
    #expect(relaunched.claimNext(for: "chat-1")?.userMessageID == "u-once",
            "a fresh process still recovers an entry left `.replaying` by a force quit")
}

// MARK: - 4c: the strip's two buttons

@Test @MainActor func sendNowReplaysThatOneEntry() async throws {
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let entry = outbox.add(chatID: "chat-1", userMessageID: "u-now", text: "send it now")

    conversation.sendOutboxNow(id: entry.id)
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    #expect(userMessageID(inBody: try #require(transport.completionBody)) == "u-now")
}

@Test @MainActor func aDedupHitRefusesToOverwriteACompletedRun() async throws {
    // The sibling of `aDedupHitRefusesToOverwriteALiveRun`: that test stops the
    // user's run *inside* the refetch window, so `phase == .ready` still
    // catches the interleaving. This one lets the run start AND finish under
    // the refetch — a slow GET, a fast answer. Phase is back to `.ready` when
    // the refetch returns, so the phase check alone passes and `apply(detail)`
    // installs a transcript snapshot taken *before* the run: the leaf rewinds
    // and the just-completed exchange vanishes — the #19/#26 class again,
    // wearing a `.ready` mask. The guard has to pin the generation, not
    // just the phase.
    let (conversation, transport, hub, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    outbox.add(chatID: "chat-1", userMessageID: "u-landed", text: "it did go through")
    transport.chatDetailOverride = transcriptWithUserMessage(id: "u-landed", text: "it did go through")
    transport.gateNextChatFetch()

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.isChatFetchGateParked }

    // A full send under the parked refetch: it starts and reaches its terminal
    // frame before the refetch ever comes back.
    conversation.draft = "the live one"
    conversation.send()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    let assistant = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistant, answer: "answered in full") {
        hub.receive(frame)
    }
    try await waitUntilOutbox { conversation.phase == .ready }

    // Now the refetch returns its landed transcript — a snapshot from before
    // the run that just completed.
    transport.releaseChatFetchGate()
    try await waitUntilOutbox { outbox.entries(for: "chat-1").first?.replaying == false }
    try await Task.sleep(for: .milliseconds(120))

    #expect(conversation.turns.contains { $0.text == "the live one" },
            "the completed exchange must survive a dedup hit that predates it")
    #expect(conversation.turns.contains { $0.text == "answered in full" },
            "both halves of it, not just the question")
    #expect(!conversation.turns.contains { $0.text == "it did go through" },
            "the stale refetched transcript must not be swapped in")
    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.userMessageID) == ["u-landed"], "the entry reverts to pending")
    #expect(entries.first?.attempts == 0, "and a bailed check does not burn an attempt")
}

@Test @MainActor func aBailedReplayDoesNotClearAnotherEntrysClaim() async throws {
    // The marker is a single slot, and two claims can queue up behind it:
    // claim A (gen nil) -> A's refetch parks -> cancel A (the cancel clears
    // the marker, since a gen-nil claim belongs to no fork) -> a trigger
    // claims B and B's run goes live -> A's refetch finally returns, its
    // guard fails, and the bail used to `outboxReplayContext = nil`
    // unconditionally — clobbering *B's* marker. B's fork then cannot
    // recognise itself, its failure falls out of the outbox arm into the #9
    // queue put-back, and the entry wedges `.replaying` with a copy in the
    // queue. The bail may only clear the marker if it still names its own
    // entry.
    let (conversation, transport, _, outbox, queues, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let entryA = outbox.add(chatID: "chat-1", userMessageID: "u-a", text: "first out")
    outbox.add(chatID: "chat-1", userMessageID: "u-b", text: "second out")
    transport.gateNextChatFetch()

    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.isChatFetchGateParked }

    conversation.cancelOutbox(id: entryA.id)

    // The next trigger claims B; B's refetch is ungated and B's run begins,
    // parking its POST at the completion gate so it is live and unfinished
    // when A's refetch finally returns.
    transport.gateNextCompletion()
    conversation.replayOutboxIfNeeded()
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    #expect(conversation.phase.isBusy, "B's run is live when A's refetch returns")

    // Arm the failure now: the transport checks it *after* the completion
    // gate's park, so it catches B's parked POST the moment it resumes.
    transport.completionFailure = APIError.unreachable("connection reset")
    transport.releaseChatFetchGate()
    try await Task.sleep(for: .milliseconds(120))
    transport.releaseCompletion()
    try await waitUntilOutbox { conversation.phase == .ready }

    // With B's claim intact, B's failure is a replay failure: the entry
    // re-parks durably. If A's bail clobbered the marker, B falls into the
    // #9 queue put-back instead — a durable entry wedged `.replaying` *and*
    // a second copy in the in-memory queue.
    #expect(queues.queue(for: "chat-1").isEmpty,
            "B's claim survived A's bail, so its failure belongs to the outbox")
    let entries = outbox.entries(for: "chat-1")
    #expect(entries.map(\.userMessageID) == ["u-b"], "B is still the only entry")
    #expect(entries.first?.replaying == false, "and B re-parked instead of wedging")
    #expect(entries.first?.attempts == 1, "the failed POST counted as B's attempt")
    try await Task.sleep(for: .milliseconds(120))
    #expect(transport.completionBodies.count == 1, "B replayed exactly once")
}

@Test @MainActor func sendNowStillSendsWhileTheFlagIsOff() async throws {
    // The strip gates on the entries, not the flag — with entries on disk and
    // the toggle off, it still says "will send when you're back" (false: every
    // automatic trigger is off) and used to offer a "Send now" that was a
    // silent no-op, because `sendOutboxNow` required `outboxEnabled`. The
    // user pressing "Send now" *is* the "the network is back" assertion the
    // flag is an opinion about, so the button bypasses the flag and the strip
    // stays honest and actionable. Capture stays gated: the flag still
    // refuses to *take on* new entries.
    let (conversation, transport, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    conversation.outboxOverride = true
    let entry = outbox.add(chatID: "chat-1", userMessageID: "u-flag-off", text: "send it anyway")
    conversation.outboxOverride = false

    // The strip is still honest about the entry: it is real and it is there.
    #expect(conversation.pendingOutbox.map(\.userMessageID) == ["u-flag-off"])

    conversation.sendOutboxNow(id: entry.id)
    try await waitUntilOutbox { transport.completionBodies.count == 1 }
    #expect(userMessageID(inBody: try #require(transport.completionBody)) == "u-flag-off",
            "\"Send now\" is the override; the flag must not dead-button it")
}

@Test @MainActor func cancelThrowsTheEntryAwayQuietly() async throws {
    let (conversation, _, _, outbox, _, suite) = try await makeOutboxFixture()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let entry = outbox.add(chatID: "chat-1", userMessageID: "u-cancel", text: "never mind")

    conversation.cancelOutbox(id: entry.id)

    #expect(outbox.isEmpty)
    #expect(conversation.pendingOutbox.isEmpty)
    #expect(conversation.error == nil, "the user changed their mind; that is not an error")
}

// MARK: - 5: signing out

@Test @MainActor func anExplicitSignOutClearsTheOutboxAndAnExpiredTokenDoesNot() throws {
    final class NoopCredentials: CredentialStore, @unchecked Sendable {
        func readToken() -> String? { "token-1" }
        func writeToken(_ token: String) {}
        func readPassword() -> String? { nil }
        func writePassword(_ password: String) {}
        func clearPassword() {}
        func clearAll() {}
    }
    let suite = "outbox-signout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = SessionStore(credentials: NoopCredentials(), defaults: defaults)
    session.setURL("https://test.invalid")
    session.outbox().add(chatID: "chat-1", userMessageID: "u-1", text: "unsent")

    // A 401 is not a decision to leave; the message was typed against this
    // instance and the token dying is nobody's fault.
    session.signOut(preserveOutbox: true)
    #expect(session.outbox().entries(for: "chat-1").map(\.text) == ["unsent"],
            "an expired token must not vaporise a message")

    // Leaving *is* a decision, and messages addressed to a server you have left
    // are nobody's.
    session.signOut()
    #expect(session.outbox().isEmpty)
}
