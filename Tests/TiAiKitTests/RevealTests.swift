import Foundation
import Testing

@testable import TiAiKit

// Issue #24: the flusher used to publish the entire pending buffer every tick,
// so a bursty local model (speculative decoding emits several tokens at once)
// made the text jump in multi-word lumps. With `revealStep` set, each tick
// advances the published prefix by at most max(step, backlog/10) graphemes —
// smooth steps, bounded lag — and the final flush of the run always publishes
// the complete text. These tests pin the pacing, the completion guarantee,
// and that the default (knob unset) is byte-identical to the old behaviour.

@MainActor
private func makeRevealFixture(chatID: String) -> (
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
    // Short ticks so a test does not spend seconds waiting for flushes.
    conversation.flushInterval = .milliseconds(20)
    return (conversation, transport, hub)
}

@MainActor
private func waitReveal(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw RevealFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum RevealFailure: Error { case timeout }

private func deltaFrame(_ chatID: String, _ messageID: String, _ delta: String)
    -> ChatEventSocket.Frame
{
    ChatEventSocket.Frame.fixture(
        kind: "response:completion", chatID: chatID, messageID: messageID,
        inner: ["type": "response.output_text.delta", "delta": delta])
}

private func doneFrame(_ chatID: String, _ messageID: String) -> ChatEventSocket.Frame {
    ChatEventSocket.Frame.fixture(
        kind: "chat:completion", chatID: chatID, messageID: messageID,
        inner: ["choices": [["index": 0, "delta": NSNull(), "finish_reason": "stop"]]])
}

/// The burst case: one frame carrying a long delta must NOT appear in full on
/// the next tick — the reveal publishes it in steps — and must complete in
/// full when the run ends.
@Test @MainActor func burstyDeltaRevealsInStepsAndCompletes() async throws {
    let (conversation, transport, hub) = makeRevealFixture(chatID: "chat-reveal")
    conversation.revealStep = 4
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    let burst = String(repeating: "word ", count: 40)  // 200 graphemes in one frame
    hub.receive(deltaFrame("chat-reveal", id, burst))

    // First visible publish: non-empty but clearly a step, not the burst.
    try await waitReveal { conversation.turns.last?.text.isEmpty == false }
    let first = conversation.turns.last?.text ?? ""
    #expect(first.count < burst.count / 2,
            "the first reveal was \(first.count) graphemes — the burst leaked")

    // Steps grow monotonically and stay partial while the stream is open.
    try await Task.sleep(for: .milliseconds(60))
    let later = conversation.turns.last?.text ?? ""
    #expect(later.count >= first.count, "the reveal went backwards")
    #expect(later.count < burst.count, "the reveal finished before the run ended")

    hub.receive(doneFrame("chat-reveal", id))
    // Completion guarantee: whatever is left unpublished goes out with the
    // final flush — no word hidden, buffer published before ready.
    try await waitReveal {
        conversation.turns.last?.text == burst && conversation.phase == .ready
    }
    #expect(conversation.turns.last?.streaming == false)
}

/// Stop mid-reveal: the stop path publishes the full buffer (the reveal may
/// delay visibility, never hide text).
@Test @MainActor func stopDuringRevealPublishesEverything() async throws {
    let (conversation, transport, hub) = makeRevealFixture(chatID: "chat-reveal-stop")
    conversation.revealStep = 2
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    let burst = String(repeating: "chunk ", count: 60)  // 360 graphemes
    hub.receive(deltaFrame("chat-reveal-stop", id, burst))
    try await waitReveal { conversation.turns.last?.text.isEmpty == false }
    #expect((conversation.turns.last?.text.count ?? 999) < burst.count,
            "reveal knob off during a stop-pinned run")

    conversation.stop()
    try await waitReveal { conversation.phase == .ready }
    // The final publish can land one flush tick behind `.ready` on a loaded
    // runner (#59); the property under test is that the whole buffer DOES
    // get published, so wait for it rather than snapshotting the race.
    try await waitReveal { conversation.turns.last?.text == burst }
    #expect(conversation.turns.last?.text == burst,
            "the stop must publish the whole buffer, not the reveal prefix")
}

/// Knob explicitly nil: the tick publishes the whole buffer, exactly the
/// pre-#24 behaviour — the escape hatch for anyone who hates typewriters.
@Test @MainActor func revealKnobUnsetPublishesFullBuffer() async throws {
    let (conversation, transport, hub) = makeRevealFixture(chatID: "chat-reveal-off")
    conversation.revealStep = nil
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    let burst = String(repeating: "word ", count: 40)
    hub.receive(deltaFrame("chat-reveal-off", id, burst))
    try await waitReveal { conversation.turns.last?.text == burst }
    hub.receive(doneFrame("chat-reveal-off", id))
    try await waitReveal { conversation.phase == .ready }
}

/// A superseded run must not write through the reveal path either: the tick
/// resolves the buffer by id and returns the cursor untouched when the buffer
/// belongs to a newer run (#11/#14/#16 invariants unchanged).
@Test @MainActor func supersededRunRevealsNothing() async throws {
    let (conversation, transport, hub) = makeRevealFixture(chatID: "chat-reveal-gone")
    conversation.revealStep = 2
    conversation.draft = "go"
    conversation.send()
    try await transport.awaitCompletion()
    let id = try #require(transport.assistantMessageID)

    hub.receive(deltaFrame("chat-reveal-gone", id, "old run text "))
    try await waitReveal { conversation.turns.last?.text.isEmpty == false }

    conversation.abandon()
    let shownAtAbandon = conversation.turns.last?.text ?? ""

    // Frames for the dead run keep arriving; nothing may reach the transcript.
    for _ in 0..<5 {
        hub.receive(deltaFrame("chat-reveal-gone", id, "more old text "))
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(conversation.turns.last?.text == shownAtAbandon,
            "a superseded drain wrote through the reveal path")
}
