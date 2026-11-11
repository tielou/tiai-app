import Foundation
import Testing

@testable import TiAiKit

private typealias Frame = ChatEventSocket.Frame

/// The hands-free loop (issue #49) over the REAL `ConversationModel`, driven
/// by the same scripted transport and hand-fed frames the ordinary
/// conversation tests use. Only the microphone and the voice are stubbed —
/// send, the run, the rollback and the parked question are the production
/// state machine, which is the whole point: the loop is tested against what
/// it actually drives.
///
/// The acceptance rule every test checks in some form: the loop never wedges.
/// Every failure either re-arms the mic or lands in `.off` with a visible
/// reason, and `stop()` works from every state.

// MARK: - harness

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw VoiceProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum VoiceProbeFailure: Error { case timeout }

@MainActor
private func makeVoiceFixture() -> (ConversationModel, ScriptedTransport, ChatEventHub) {
    let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
    let hub = ChatEventHub(server: server)
    let transport = ScriptedTransport()
    let conversation = ConversationModel(
        chatID: "chat-1",
        models: [ChatModel.stub("local-personal")],
        client: OWUIClient(server: server, transport: transport),
        hub: hub)
    return (conversation, transport, hub)
}

/// One recording cycle's outcome. `.hang` keeps the mic open forever (the
/// loop is waiting for a sentence that never comes), which is also how a test
/// parks the re-armed loop before calling `stop()`.
private enum StubReply {
    case text(String)
    case textOnFinish(String)
    case empty
    case blank
    case failure(String)
    case permission(String)
    case hang
}

@MainActor
private final class StubRecorder: VoiceModeRecorder {
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private var script: [StubReply]
    /// Models the transcription round trip of the real capture: a
    /// `.textOnFinish` reply returns this long *after* the tap, so a test can
    /// act while the loop is mid-transcription.
    var postFinishDelay: Duration = .zero

    init(_ script: [StubReply]) { self.script = script }

    func recordUntilStopped(client: OWUIClient) async throws -> String? {
        startCount += 1
        let reply = script.isEmpty ? StubReply.hang : script.removeFirst()
        switch reply {
        case .text(let text): return text
        case .empty: return nil
        case .blank: return "   "
        case .failure(let message): throw VoiceModeFailure.message(message)
        case .permission(let message): throw VoiceModeFailure.permission(message)
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return nil
        case .textOnFinish(let text):
            // Hold the mic until the tap, like the real capture does.
            while finishCount < startCount {
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: postFinishDelay)
            return text
        }
    }

    func finish() { finishCount += 1 }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class StubSpeaker: VoiceModeSpeaker {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    /// The first reading hangs until `stop()` — the mid-speech interrupt.
    var hangsFirst = false
    /// When set, the first reading throws this instead of speaking — the TTS
    /// round trip died. The loop must show it and re-arm, not wedge.
    var failFirstWith: String?
    private var released = false
    private var failed = false

    func speak(_ text: String) async throws {
        spoken.append(text)
        if let failure = failFirstWith, !failed {
            failed = true
            throw VoiceModeFailure.message(failure)
        }
        guard hangsFirst && !released else { return }
        while !released { try await Task.sleep(for: .milliseconds(2)) }
    }

    func stop() {
        stopCount += 1
        released = true
    }
}

// MARK: - the loop

@Test @MainActor func theHappyLoopRecordsSendsAnswersReadsAloudAndReArms() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.textOnFinish("hello"), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    // Tap-to-stop the recording, as the bar's circle does while listening.
    try await waitUntil { recorder.startCount == 1 && controller.phase == .listening }
    controller.toggle()

    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistantID, answer: "MAGIC") {
        hub.receive(frame)
    }

    try await waitUntil { speaker.spoken == ["MAGIC"] }
    #expect(conversation.turns.contains { $0.isUser && $0.text == "hello" },
            "the spoken words went out as an ordinary message")
    // Auto re-arm: the loop is back at the mic without a touch.
    try await waitUntil { controller.phase == .listening }
    #expect(controller.error == nil)
    #expect(recorder.finishCount == 1)

    controller.stop()
    #expect(controller.phase == .off)
}

@Test @MainActor func stoppingMidSpeechIsCleanAndTheLoopRestarts() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.text("hello"), .text("again"), .hang])
    let speaker = StubSpeaker()
    speaker.hangsFirst = true
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistantID, answer: "MAGIC") {
        hub.receive(frame)
    }
    try await waitUntil { controller.phase == .speaking }

    controller.stop()
    #expect(controller.phase == .off)
    #expect(speaker.stopCount >= 1, "the voice was cut, not left talking")
    #expect(recorder.cancelCount >= 1, "the mic was released")
    // The run had already finished; stopping the loop must not stop a chat
    // that is not busy.
    #expect(!transport.paths.contains("/api/tasks/chat/chat-1/stop"))
    #expect(conversation.phase == .ready)

    // A second start completes a fresh loop — the state after stop is
    // genuinely re-startable, not a corpse.
    controller.start()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: second, answer: "AGAIN") {
        hub.receive(frame)
    }
    try await waitUntil { speaker.spoken == ["MAGIC", "AGAIN"] }
    controller.stop()
}

@Test @MainActor func stoppingWhileThinkingStopsTheRunAndRestartsCleanly() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.text("hello"), .text("again"), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await waitUntil { controller.phase == .thinking }

    controller.stop()
    #expect(controller.phase == .off)
    // The run in flight was the loop's own, so voice mode owns the stop.
    try await waitUntil { transport.paths.contains("/api/tasks/chat/chat-1/stop") }
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]]))
    try await waitUntil { conversation.phase == .ready }

    controller.start()
    try await transport.awaitCompletion(2)
    let second = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: second, answer: "AGAIN") {
        hub.receive(frame)
    }
    try await waitUntil { speaker.spoken == ["AGAIN"] }
    controller.stop()
}

@Test @MainActor func aTranscriptionFailureShowsUpButNeverWedgesTheLoop() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.failure("The server could not transcribe that."), .text("hello"), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    // The failure is visible while the loop re-arms — and the loop is AT the
    // mic, not stopped: a bad transcription round trip is not a reason to
    // leave hands-free mode.
    try await waitUntil { controller.error != nil }
    #expect(controller.phase == .listening)

    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistantID, answer: "MAGIC") {
        hub.receive(frame)
    }
    try await waitUntil { speaker.spoken == ["MAGIC"] }
    #expect(controller.error == nil, "a full cycle retires the old complaint")
    controller.stop()
}

@Test @MainActor func aDeniedPermissionStopsTheLoopWithTheReason() async throws {
    let (conversation, transport, _) = makeVoiceFixture()
    let recorder = StubRecorder([.permission("Microphone access is off — enable it in Settings.")])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await waitUntil { controller.error != nil }
    #expect(controller.phase == .off)
    #expect(controller.error?.contains("Microphone access") == true)
    // Re-arming would throw the same refusal a beat later, so the loop stayed
    // out — and nothing was sent.
    #expect(recorder.startCount == 1)
    #expect(!transport.paths.contains("/api/v1/chat/completions"))
    #expect(conversation.turns.isEmpty)
    // NOTE: the real AVFAudio permission prompt is iOS-only and cannot be
    // exercised on macOS; this pins the failure contract the iOS adapter
    // maps the prompt onto.
}

@Test @MainActor func anEmptyRecordingReArmsWithoutSending() async throws {
    let (conversation, transport, _) = makeVoiceFixture()
    let recorder = StubRecorder([.empty, .blank, .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await waitUntil { recorder.startCount >= 3 }
    #expect(!transport.paths.contains("/api/v1/chat/completions"),
            "silence is not a message")
    #expect(controller.error == nil, "and silence is not a failure either")
    #expect(conversation.turns.isEmpty)
    controller.stop()
}

@Test @MainActor func sendReportsWhetherTheMessageWasAccepted() {
    let (conversation, _, _) = makeVoiceFixture()
    conversation.draft = ""
    #expect(!conversation.send(), "an empty composer is a refusal")
    conversation.draft = "go"
    #expect(conversation.send(), "a real message is accepted")
}

@Test @MainActor func aSendThatNeverReachesTheServerSurfacesAndReArms() async throws {
    let (conversation, transport, _) = makeVoiceFixture()
    // A refusal the app will not retry: the #9 rollback, which leaves the
    // phase `.ready` with an error and the text back in the composer.
    transport.completionFailure = APIError.http(status: 400, message: "bad request")
    let recorder = StubRecorder([.text("no"), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    // Bounded: the loop must notice the dead send on its own, not sit in
    // `.thinking` until the run timeout.
    try await waitUntil { controller.error != nil }
    #expect(controller.error?.contains("Could not send") == true,
            "\(controller.error ?? "nil") — the model's own reason is surfaced")
    try await waitUntil { recorder.startCount >= 2 }
    #expect(controller.phase == .listening, "re-armed, not wedged")
    #expect(speaker.spoken.isEmpty)
    controller.stop()
}

@Test @MainActor func aParkedQuestionIsReadAloudAndTheLoopReArms() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.text("book me a trip"), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    hub.receive(Frame.fixture(
        kind: "chat:completion", chatID: "chat-1", messageID: assistantID,
        inner: ["done": false, "output": [AskUserFixture.outputItem]]))

    // Voice UX: hear the question, answer it by voice. The parked run is a
    // completed utterance, not a timeout.
    try await waitUntil {
        speaker.spoken.contains { $0.contains("What would you like to eat?") }
    }
    try await waitUntil { controller.phase == .listening }
    #expect(controller.error == nil)
    // Pin the branch: a parked turn must go through the `.question` path —
    // with its settle beat for the refetch — and never through `settled()`,
    // which would read the question before its full text has landed.
    #expect(controller.lastOutcome == .question,
            "the parked run took the question branch, not the answer path")
    controller.stop()
}

@Test @MainActor func aSpeakerFailureShowsUpAndReArmsTheMic() async throws {
    let (conversation, transport, hub) = makeVoiceFixture()
    let recorder = StubRecorder([.text("hello"), .hang])
    let speaker = StubSpeaker()
    speaker.failFirstWith = "Could not produce audio."
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    try await transport.awaitCompletion()
    let assistantID = try #require(transport.assistantMessageID)
    for frame in Frames.run(chat: "chat-1", message: assistantID, answer: "MAGIC") {
        hub.receive(frame)
    }
    // A dead voice is a failure the user should see — but the mic is the
    // point of hands-free mode, so the loop re-arms rather than quitting.
    try await waitUntil { controller.error != nil }
    #expect(controller.error?.contains("Could not produce audio") == true)
    try await waitUntil { controller.phase == .listening }
    #expect(recorder.startCount >= 2, "the mic re-armed despite the dead voice")
    controller.stop()
    #expect(controller.phase == .off)
}

@Test @MainActor func stopFromListeningAndMidTranscriptionLeavesOffCleanly() async throws {
    // From `.listening`: the mic is open, nothing else has started.
    let (conversation, transport, _) = makeVoiceFixture()
    let recorder = StubRecorder([.hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))
    controller.start()
    try await waitUntil { controller.phase == .listening }
    controller.stop()
    #expect(controller.phase == .off)
    #expect(recorder.cancelCount >= 1, "the mic was released")
    #expect(controller.error == nil, "a stop is never an error")
    #expect(conversation.turns.isEmpty)

    // Mid-transcription: the tap has stopped the mic and the words are still
    // on their way back (the round trip lives inside the recorder, which is
    // what `.transcribing` exists to describe). Stopping there must leave a
    // clean `.off` and must not send the half-made message.
    let recorder2 = StubRecorder([.textOnFinish("hello")])
    recorder2.postFinishDelay = .milliseconds(200)
    let (conversation2, transport2, _) = makeVoiceFixture()
    let speaker2 = StubSpeaker()
    let controller2 = VoiceModeController(
        conversation: conversation2, recorder: recorder2, speaker: speaker2,
        poll: .milliseconds(2), runTimeout: .seconds(10))
    controller2.start()
    try await waitUntil { recorder2.startCount == 1 && controller2.phase == .listening }
    controller2.toggle()  // the tap that ends the recording
    try await waitUntil { recorder2.finishCount == 1 }
    controller2.stop()
    #expect(controller2.phase == .off)
    #expect(controller2.error == nil)
    // Give the stub's fake round trip longer than it needs; the cancelled
    // loop must not come back and send anything.
    try await Task.sleep(for: .milliseconds(50))
    #expect(!transport2.paths.contains("/api/v1/chat/completions"),
            "the transcription in flight was dropped, not sent")
    #expect(conversation2.turns.isEmpty)
}

@Test @MainActor func repeatedRecorderFailuresTakeTheLoopOutOfTheGame() async throws {
    let (conversation, transport, _) = makeVoiceFixture()
    // A persistent non-permission failure — the mic held by another app.
    // One failure is worth a retry; three identical ones are a wall, and a
    // loop that re-arms against it every backoff beat forever is worse than
    // one that quits with the reason on screen.
    let message = "The microphone is in use by another app."
    let recorder = StubRecorder([.failure(message), .failure(message), .failure(message), .hang])
    let speaker = StubSpeaker()
    let controller = VoiceModeController(
        conversation: conversation, recorder: recorder, speaker: speaker,
        poll: .milliseconds(2), runTimeout: .seconds(10))

    controller.start()
    // `startCount >= 3` first: `.off` is also the phase before the loop ever
    // ran, and `waitUntil` checks immediately.
    try await waitUntil { recorder.startCount >= 3 && controller.phase == .off }
    #expect(controller.error?.contains("microphone") == true)
    #expect(!transport.paths.contains("/api/v1/chat/completions"))
    // And the state is genuinely re-startable, not a corpse.
    #expect(conversation.turns.isEmpty)
}
