import Foundation
import Testing

@testable import TiAiKit

private typealias Frame = ChatEventSocket.Frame

/// The send-while-generating queue (issue #37).
///
/// The behaviour under test is the promise the queue makes and the order it keeps
/// it in: a message pressed while the assistant is still talking is *kept*, it
/// stays visible, and it goes out — combined with whatever else is waiting, as
/// one message — the moment the chat can take it. Everything here is driven the
/// way the rest of the suite drives a run: a scripted transport, frames fed into
/// the hub by hand, and no network.
///
/// The queue lives on the session rather than on the model, so the tests inject
/// a `MessageQueueStore` — the same object two model instances share when the
/// user leaves the chat and comes back.

private let testServer = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")

@MainActor
private func makeQueueConversation(
    chatID: String?,
    transport: ScriptedTransport,
    hub: ChatEventHub,
    models: [ChatModel] = [ChatModel.stub("local-personal", caps: ["vision": true])],
    queues: MessageQueueStore = MessageQueueStore()
) -> ConversationModel {
    ConversationModel(
        chatID: chatID,
        models: models,
        client: OWUIClient(server: testServer, transport: transport),
        hub: hub,
        // A ribbon singleton shared between tests would make two models in one
        // test fight over one Live Activity; this is the established seam.
        activity: GenerationActivity(),
        queues: queues)
}

@MainActor
private func waitUntilQueue(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw QueueProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum QueueProbeFailure: Error { case timeout }

/// Starts a run and leaves it streaming, returning the assistant message id the
/// frames have to be addressed to.
@MainActor
private func startOpenRun(
    _ conversation: ConversationModel, transport: ScriptedTransport, hub: ChatEventHub,
    text: String = "first"
) async throws -> String {
    conversation.draft = text
    conversation.send()
    try await transport.awaitCompletion()
    return try #require(transport.assistantMessageID)
}

@MainActor
private func finishRun(chat: String, message: String, hub: ChatEventHub, answer: String = "ok") {
    for frame in Frames.run(chat: chat, message: message, answer: answer) {
        hub.receive(frame)
    }
}

// MARK: - 1: the basic shape

@Test @MainActor func aMessageSentWhileTheAssistantIsGeneratingIsQueuedAndSentAfter() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)

    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)
    hub.receive(Frame.fixture(
        kind: "response:completion", chatID: "chat-1", messageID: assistant,
        inner: ["type": "response.output_text.delta", "delta": "Hel"]))
    #expect(conversation.phase.isBusy)

    conversation.draft = "and one more thing"
    conversation.send()

    // Queued, not sent, and not lost: the composer is empty, the queue holds it,
    // and no second completion has gone out.
    #expect(conversation.draft.isEmpty, "the queued message left the composer")
    #expect(conversation.queue.items.map(\.text) == ["and one more thing"])
    #expect(transport.completionBodies.count == 1, "a queued message must not post")
    // The bug this is the other half of: a busy send used to no-op *after*
    // reading the draft in some paths. Here nothing was consumed except into
    // the queue, so the transcript still holds exactly the one exchange.
    #expect(conversation.turns.count == 2, "no phantom turn for a message that has not been sent")
    #expect(conversation.error == nil, "queueing is not an error")

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    #expect(conversation.queue.isEmpty, "the drain empties the queue")
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("and one more thing"))
    // The queued message is a new question, not a continuation of the answer
    // it waited behind: it goes out as its own user turn.
    #expect(conversation.turns.filter { $0.role == "user" }.count == 2)
}

// MARK: - 2: everything waiting goes out as one message

@Test @MainActor func severalQueuedMessagesGoOutAsOneMessage() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)

    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)
    conversation.draft = "a"
    conversation.send()
    conversation.draft = "b"
    conversation.send()
    #expect(conversation.queue.items.map(\.text) == ["a", "b"])
    #expect(transport.completionBodies.count == 1)

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    // One run, not two: three questions in flight is one follow-up that reads
    // as the user actually typed them.
    #expect(transport.completionBodies.count == 2, "the queue drains as a single completion")
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    // The wire body is JSON, so the join is the escaped pair, not a real newline.
    #expect(body.contains("a\\n\\nb"), "combined in the order they were queued: \(body)")
    #expect(conversation.turns.filter { $0.role == "user" }.count == 2,
            "one new user turn for the whole queue")
}

// MARK: - 3: "send now" interrupts, and the stop lands first

@Test @MainActor func sendNowStopsTheRunAndSendsJustThatOneAfterTheStopLands() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    _ = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "urgent"
    conversation.send()
    conversation.draft = "later"
    conversation.send()
    #expect(conversation.queue.items.map(\.text) == ["urgent", "later"])

    // Hold the stop on the wire: the steered message must not overtake it, or
    // the server answers the completion it was told to stop.
    transport.gateNextStop()
    let urgent = try #require(conversation.queue.items.first)
    conversation.sendNow(id: urgent.id)
    try await waitUntilQueue { transport.isStopGateParked }
    #expect(transport.completionBodies.count == 1,
            "nothing may be posted before the server has stopped the current run")
    #expect(conversation.queue.items.map(\.text) == ["later"], "only the steered item left the queue")

    transport.releaseStopGate()
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let paths = transport.paths
    let stopAt = try #require(paths.firstIndex { $0.hasSuffix("/stop") })
    let completions = paths.enumerated().filter { $0.element.hasSuffix("/chat/completions") }.map(\.offset)
    #expect(completions.count == 2)
    #expect(stopAt < completions[1], "the stop POST resolved before the steered completion: \(paths)")
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("urgent"))
    #expect(!body.contains("later"), "send now sends the one item, not the whole queue")
    // The rest waits for the run it is now behind.
    #expect(conversation.queue.items.map(\.text) == ["later"])
}

// MARK: - 4: edit and delete

@Test @MainActor func editingAQueuedMessagePutsItBackInTheComposer() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "wrong wording"
    conversation.send()
    let item = try #require(conversation.queue.items.first)
    conversation.editQueued(id: item.id)

    #expect(conversation.queue.isEmpty)
    #expect(conversation.draft == "wrong wording", "edit hands the text back to type on")
    #expect(conversation.error == nil)

    // And it stays back: the run ending must not fire a message the user
    // just took out of the queue.
    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { conversation.phase == .ready }
    try await Task.sleep(for: .milliseconds(30))
    #expect(transport.completionBodies.count == 1, "an edited-away message is not sent")
    #expect(conversation.draft == "wrong wording")
}

@Test @MainActor func deletingAQueuedMessageDropsItSilently() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "never mind"
    conversation.send()
    conversation.deleteQueued(id: try #require(conversation.queue.items.first).id)

    #expect(conversation.queue.isEmpty)
    #expect(conversation.draft.isEmpty, "delete throws it away, it does not hand it back")
    #expect(conversation.error == nil, "deleting is not a failure")

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { conversation.phase == .ready }
    try await Task.sleep(for: .milliseconds(30))
    #expect(transport.completionBodies.count == 1)
}

// MARK: - 5: the queue belongs to the chat, not to the screen

@Test @MainActor func theQueueSurvivesLeavingTheChatAndDrainsOnReturn() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let queues = MessageQueueStore()
    let first = makeQueueConversation(chatID: "q5-chat", transport: transport, hub: hub, queues: queues)
    _ = try await startOpenRun(first, transport: transport, hub: hub)
    first.draft = "carried over"
    first.send()
    #expect(first.queue.items.count == 1)

    // Navigating away and back builds a fresh model. A queue that died with the
    // old one is a queue that eats messages.
    let second = makeQueueConversation(chatID: "q5-chat", transport: transport, hub: hub, queues: queues)
    #expect(second.queue.items.map(\.text) == ["carried over"])

    // Opening the chat is a safe moment to drain, and the one that catches a
    // message queued while no model was looking at the chat.
    await second.load()
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("carried over"))
    #expect(second.queue.isEmpty)
}

// MARK: - 6: a queued message waits for its file

@Test @MainActor func aQueuedMessageWaitsForAnUploadStillOnTheWire() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    transport.gateNextUpload()
    conversation.attach(data: Data("notes".utf8), name: "note.txt", mimeType: "text/plain")
    conversation.draft = "read this"
    conversation.send()
    #expect(conversation.queue.items.count == 1)
    #expect(conversation.queue.items[0].awaitingUploads,
            "the message knows its file has not landed")

    // The run ends. The composer is free, and still nothing is sent: sending the
    // text while its picture is on the wire is issue #22, and the queue is not
    // the place to bring it back.
    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { conversation.phase == .ready }
    try await Task.sleep(for: .milliseconds(40))
    #expect(transport.completionBodies.count == 1, "the drain waits for the upload")

    transport.releaseUpload()
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("read this"))
    #expect(body.contains("file-1"), "the file that landed late travels with it: \(body)")
}

@Test @MainActor func aFilePickedForAQueuedMessageLandsOnThatMessage() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "one"
    conversation.send()
    transport.gateNextUpload()
    conversation.attach(data: Data("notes".utf8), name: "note.txt", mimeType: "text/plain")
    // A second message queued while the first one's file is still on the wire
    // must not adopt that upload: the file belongs to the message it was picked
    // for, which is the whole lesson of the misrouted-pictures bug.
    conversation.draft = "two"
    conversation.send()
    #expect(conversation.queue.items.map(\.text) == ["one", "two"])
    #expect(conversation.queue.items[0].awaitingUploads)
    #expect(!conversation.queue.items[1].awaitingUploads)

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    transport.releaseUpload()
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("one\\n\\ntwo"), "combined, escaped as JSON escapes it")
    #expect(body.contains("file-1"))
}

// MARK: - 7: the toggle

@Test @MainActor func sendWhileGeneratingWithTheToggleOffIsStillTheOldNoOp() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    conversation.queueWhileGeneratingOverride = false
    _ = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "interloper"
    conversation.send()
    #expect(conversation.draft == "interloper", "off means off: the send is refused as it was")
    #expect(conversation.queue.isEmpty)
    #expect(transport.completionBodies.count == 1)
    #expect(conversation.error == nil)
}

// MARK: - 8: the drain re-checks what send() checks

@Test @MainActor func aQueuedPictureIsRefusedAtTheDrainWhenTheModelCannotSee() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let eyes = ChatModel.stub("eyes", caps: ["vision": true])
    let blind = ChatModel.stub("blind", caps: ["vision": false])
    let conversation = makeQueueConversation(
        chatID: "chat-1", transport: transport, hub: hub, models: [eyes, blind])
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: "shot.jpg", mimeType: "image/jpeg")
    conversation.draft = "what is this"
    conversation.send()
    #expect(conversation.queue.items.count == 1)

    // The model changed while the message waited. The guard that refused this
    // send would have refused it at the button, and the engine 500s on a
    // picture handed to a blind model — so the drain has to ask again.
    conversation.select(model: "blind", from: [eyes, blind])
    finishRun(chat: "chat-1", message: assistant, hub: hub)
    // The upload has to land before the drain can see what it is refusing, so
    // the wait is for the refusal rather than for a fixed slice of time.
    try await waitUntilQueue { conversation.error != nil }
    #expect(transport.completionBodies.count == 1, "the refused message must not be posted")
    // The point of the guard: refused, not dropped. Silent loss is the bug.
    #expect(conversation.queue.items.map(\.text) == ["what is this"])
    #expect(conversation.queue.items[0].attachments.count == 1, "and it still has its picture")
    #expect(conversation.error?.contains("can't see images") == true,
            "the refusal says why: \(conversation.error ?? "nil")")

    // Pick a model that can see it and it goes out — the item was kept whole.
    conversation.select(model: "eyes", from: [eyes, blind])
    conversation.sendNow(id: try #require(conversation.queue.items.first).id)
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("what is this"))
    #expect(body.contains("image_url"))
}

@Test @MainActor func aQueuedMessageOverTheImageBudgetStaysQueued() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    conversation.maxImagesPerRequestOverride = 2
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    for name in ["a.jpg", "b.jpg", "c.jpg"] {
        conversation.attach(data: Data([0xFF, 0xD8, 0xFF]), name: name, mimeType: "image/jpeg")
    }
    conversation.draft = "three pictures"
    conversation.send()
    #expect(conversation.queue.items.count == 1)

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { conversation.error != nil }

    #expect(transport.completionBodies.count == 1, "an over-budget drain must not post")
    #expect(conversation.queue.items.count == 1, "and it must not throw the message away")
    #expect(conversation.error?.contains("images") == true,
            "the refusal names the budget: \(conversation.error ?? "nil")")
}

// MARK: - 9: a hung upload may stall a message, not eat it

@Test @MainActor func aHungUploadHoldsTheQueueWithAComplaintInsteadOfWedgingIt() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    conversation.uploadWaitLimit = .milliseconds(60)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    transport.gateNextUpload()
    conversation.attach(data: Data("notes".utf8), name: "note.txt", mimeType: "text/plain")
    conversation.draft = "read this"
    conversation.send()
    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { conversation.phase == .ready }

    // The upload never answers. The queue gives up on the transport rather than
    // waiting forever — and says so, instead of sending the text without it.
    try await waitUntilQueue(timeout: .seconds(3)) {
        conversation.queue.items.first?.uploadFailed == true
    }
    #expect(transport.completionBodies.count == 1, "a failed file is not silently dropped")
    #expect(conversation.queue.items.count == 1)
    #expect(conversation.error?.contains("too long") == true,
            "the banner says what happened: \(conversation.error ?? "nil")")

    // A late success still counts: the file lands, the failure is taken back,
    // and the message goes out with its file.
    transport.releaseUpload()
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("file-1"))
}

// MARK: - 10: the busy paths that were refusals

@Test @MainActor func aSendDuringAnInFlightEditIsQueuedAndDrainsAfterTheEdit() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
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
    try await waitUntilQueue { transport.isMessageUpdateGateParked }
    #expect(conversation.phase.isBusy)

    // The edit holds the chat busy, so this is queued rather than refused — and
    // it must not disturb the edit's own run.
    conversation.draft = "interloper"
    conversation.send()
    #expect(conversation.queue.items.map(\.text) == ["interloper"])
    #expect(conversation.draft.isEmpty)
    #expect(transport.completionBodies.isEmpty, "the queued message waits for the edit's run")

    transport.releaseMessageUpdateGate()
    // The edit's own run is the first completion this chat has posted; the
    // queued message will be the second.
    try await transport.awaitCompletion()
    let editAssistant = try #require(transport.assistantMessageID)
    finishRun(chat: "chat-1", message: editAssistant, hub: hub)
    // Two completions total: the edit's own run, then the queued interloper
    // draining as a child of the edit's answer. (Not three — the edit posts one
    // completion, not two.) The drain runs off the terminal frame on the main
    // actor, so allow the same 5s the phase waits use for a loaded runner.
    try await waitUntilQueue(timeout: .seconds(5)) { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("interloper"))
}

@Test @MainActor func aLatePickWhileTheRunIsLiveGoesToTheQueueNotTheComposer() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    // The camera callback that used to be refused: with the queue on, the pick
    // is kept for the message the user sends next.
    conversation.attach(data: Data("notes".utf8), name: "note.txt", mimeType: "text/plain")
    try await waitUntilQueue { transport.uploads.count == 1 }
    conversation.draft = "read this"
    conversation.send()

    #expect(conversation.queue.items.count == 1)
    // The upload's landing continuation (append the file to the queued item)
    // runs on the main actor after `uploadFile` returns, so `uploads.count == 1`
    // can be observed a beat before the item actually carries the file. On a
    // loaded runner that beat widens past the synchronous assert; wait for the
    // landing instead of assuming it already ran.
    try await waitUntilQueue {
        conversation.queue.items.first?.attachments.map(\.id) == ["file-1"]
    }
    #expect(conversation.attachments.isEmpty, "and it is not left in the composer to ride along twice")
    #expect(conversation.error == nil, "nothing was refused")

    finishRun(chat: "chat-1", message: assistant, hub: hub)
    try await waitUntilQueue { transport.completionBodies.count == 2 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("file-1"))
}

// MARK: - 11: a stopped queued run is not lost

@Test @MainActor func aQueuedMessageThatNeverReachedTheServerGoesBackIntoTheQueue() async throws {
    let hub = ChatEventHub(server: testServer)
    let transport = ScriptedTransport()
    let conversation = makeQueueConversation(chatID: "chat-1", transport: transport, hub: hub)
    let assistant = try await startOpenRun(conversation, transport: transport, hub: hub)

    conversation.draft = "queued"
    conversation.send()
    // The drained run's POST dies before a single frame: the issue #9 rollback.
    // For a composer send that puts the text back in the composer; for a queued
    // run it belongs with the queue it came from, or the messages still waiting
    // behind it would be the only copy of it left.
    transport.completionFailure = APIError.unreachable("connection refused")
    finishRun(chat: "chat-1", message: assistant, hub: hub)

    // The rollback lands after the post-run reconcile has had its say. Wait for
    // the FINAL banner ("Could not send …"), not merely `error != nil`:
    // `recordPostError` stamps a provisional banner ("connection refused") a
    // beat before the exchange rollback overwrites it and puts the message back,
    // so on a loaded runner `error != nil` is true mid-rollback and the
    // assertions below race the teardown. The full banner is the rollback's last
    // write, so waiting on it means the queue/turns are already settled.
    try await waitUntilQueue(timeout: .seconds(3)) {
        conversation.error?.contains("Could not send") == true
    }
    #expect(conversation.queue.items.map(\.text) == ["queued"])
    #expect(conversation.draft.isEmpty, "a queued run puts nothing back in the composer")
    #expect(transport.completionBodies.count == 2, "it did try to send")
    #expect(conversation.error?.contains("Could not send") == true,
            "the rollback says so: \(conversation.error ?? "nil")")
    #expect(conversation.turns.filter { $0.role == "user" }.count == 1,
            "the phantom exchange is rolled back")

    // And it is sendable again, whole.
    transport.completionFailure = nil
    conversation.sendNow(id: try #require(conversation.queue.items.first).id)
    try await waitUntilQueue { transport.completionBodies.count == 3 }
    let body = String(decoding: try #require(transport.completionBodies.last), as: UTF8.self)
    #expect(body.contains("queued"))
}
