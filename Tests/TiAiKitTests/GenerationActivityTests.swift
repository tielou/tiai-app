import Foundation
import Testing

@testable import TiAiKit

/// Issue #15: the Live Activity ribbon is a process singleton, but a chat's run
/// keeps running after the user switches away (by design — the answer must
/// survive the return trip). Before the owner token existed, the orphaned run's
/// `finish` ended whatever ribbon was live — which could be the one the user
/// now associates with the chat they switched *to*.
///
/// These tests run against the macOS stub, which simulates a working ribbon
/// (one live at a time, same gating) and exposes the observable state.
///
/// The singleton-semantics tests use fresh `GenerationActivity` instances
/// rather than `.shared` on purpose: Swift Testing runs suites in parallel,
/// and every other suite's `send()` raises ribbons on `.shared` — asserting on
/// it from here would be a race, not a test. The two-model test injects one
/// shared instance into both models, which is the exact production shape
/// (one ribbon, many chats) without the cross-suite interference.

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw ProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum ProbeFailure: Error { case timeout }

@Suite(.serialized)
struct RibbonOwnership {
    /// The exact bug scenario. A sends (ribbon owned by A), the user switches
    /// to B and sends (start no-ops — one ribbon at a time, owner stays A),
    /// B's run finishes first. Pre-fix, `finish` was unconditional and B's
    /// finish ended the ribbon A owns. Post-fix it no-ops: B never owned it.
    @Test @MainActor func anotherChatsFinishCannotCloseTheRibbon() async {
        let ribbon = GenerationActivity()
        await ribbon.start(chatTitle: "Chat A", model: "m", chatID: "chat-a")
        #expect(ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == "chat-a")

        // Chat B raises a ribbon while A's is live: the start no-ops and the
        // owner stays A.
        await ribbon.start(chatTitle: "Chat B", model: "m", chatID: "chat-b")
        #expect(ribbon.activeChatID == "chat-a", "one ribbon at a time; B's start must not steal ownership")

        // B's run finishes. Pre-fix this cleared the ribbon A owns — the
        // discriminating assertion.
        await ribbon.finish(.finished, characters: 10, chatID: "chat-b")
        #expect(ribbon.isRibbonActive, "B never owned the ribbon; its finish must not close it")
        #expect(ribbon.activeChatID == "chat-a")

        // A finishes its own run: owner match closes the ribbon.
        await ribbon.finish(.finished, characters: 20, chatID: "chat-a")
        #expect(!ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == nil)
    }

    /// The nil-owner rule. A brand-new chat raises its ribbon before the
    /// server has answered with an id, so the owner token is nil — unclaimed.
    /// The run adopts the id mid-flight and its finish passes the *current*
    /// id; nil matches anything, so the adopting run still closes its own
    /// ribbon. (The accepted trade: while a nil-owner ribbon is live, any
    /// finish may close it — better than stranding it forever.)
    @Test @MainActor func anUnclaimedRibbonIsClosableByTheRunThatAdoptedItsChat() async {
        let ribbon = GenerationActivity()
        await ribbon.start(chatTitle: "New Chat", model: "m", chatID: nil)
        #expect(ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == nil, "unclaimed: the chat had no id when the ribbon went up")

        await ribbon.finish(.finished, characters: 5, chatID: "chat-adopted")
        #expect(!ribbon.isRibbonActive, "the adopting run must still be able to close its own ribbon")
        #expect(ribbon.activeChatID == nil)
    }

    /// Updates are gated by the same rule: an orphaned run must not repaint
    /// someone else's ribbon (its character count would make the ribbon lie
    /// about the wrong chat).
    @Test @MainActor func updatesFromAnotherChatAreIgnored() async {
        let ribbon = GenerationActivity()
        await ribbon.start(chatTitle: "Chat A", model: "m", chatID: "chat-a")

        await ribbon.update(phase: .writing, characters: 100, chatID: "chat-b")
        #expect(ribbon.acceptedUpdates == 0, "B must not repaint A's ribbon")

        await ribbon.update(phase: .writing, characters: 100, chatID: "chat-a")
        #expect(ribbon.acceptedUpdates == 1)

        // nil caller = unclaimed identity, matches — same rule as finish.
        await ribbon.update(phase: .thinking, characters: 0, chatID: nil)
        #expect(ribbon.acceptedUpdates == 2)
    }

    /// `cancelIfRunning` is the unowned teardown (app-level reset), so it
    /// clears the owner token too — a stale owner would gate the next ribbon.
    @Test @MainActor func cancelClearsTheOwnerToken() async {
        let ribbon = GenerationActivity()
        await ribbon.start(chatTitle: "Chat A", model: "m", chatID: "chat-a")
        await ribbon.cancelIfRunning()
        #expect(!ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == nil)
        // And a fresh ribbon can be raised and closed afterwards.
        await ribbon.start(chatTitle: "Chat B", model: "m", chatID: "chat-b")
        #expect(ribbon.activeChatID == "chat-b")
    }
}

@Suite(.serialized)
struct TwoModelsOneRibbon {
    /// The model-level integration: two `ConversationModel`s sharing one
    /// ribbon instance (the production shape — `GenerationActivity.shared`),
    /// driven by real frames through one hub. Chat A is mid-run when the user
    /// "switches" to chat B and sends; B's run finishes first and must leave
    /// A's ribbon standing; A's finish then closes its own.
    @Test @MainActor func aSwitchedAwayChatsRunCannotEndTheOtherChatsRibbon() async throws {
        let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
        let hub = ChatEventHub(server: server)
        let ribbon = GenerationActivity()

        let transportA = ScriptedTransport()
        let chatA = ConversationModel(
            chatID: "chat-a", title: "Chat A",
            models: [ChatModel.stub("local-personal")],
            client: OWUIClient(server: server, transport: transportA),
            hub: hub, activity: ribbon)
        let transportB = ScriptedTransport()
        let chatB = ConversationModel(
            chatID: "chat-b", title: "Chat B",
            models: [ChatModel.stub("local-personal")],
            client: OWUIClient(server: server, transport: transportB),
            hub: hub, activity: ribbon)

        // Chat A sends; the ribbon goes up, owned by chat-a.
        chatA.draft = "go A"
        chatA.send()
        try await transportA.awaitCompletion()
        let answerA = try #require(transportA.assistantMessageID)
        try await waitUntil { ribbon.activeChatID == "chat-a" }

        // The user switches to chat B and sends. `start` no-ops (A's ribbon
        // is live), so the owner stays chat-a.
        chatB.draft = "go B"
        chatB.send()
        try await transportB.awaitCompletion()
        let answerB = try #require(transportB.assistantMessageID)
        // Let B's (no-op) start task run before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(ribbon.activeChatID == "chat-a")

        // B's run finishes first — pre-fix this ended the ribbon A owns.
        for frame in Frames.run(chat: "chat-b", message: answerB, answer: "bee") {
            hub.receive(frame)
        }
        try await waitUntil(timeout: .seconds(5)) { chatB.phase == .ready }
        #expect(chatB.turns.last?.text == "bee")
        #expect(ribbon.isRibbonActive, "B's finish must not close A's ribbon")
        #expect(ribbon.activeChatID == "chat-a")

        // A's run finishes: owner match, its own ribbon closes.
        for frame in Frames.run(chat: "chat-a", message: answerA, answer: "ay") {
            hub.receive(frame)
        }
        try await waitUntil(timeout: .seconds(5)) { chatA.phase == .ready }
        #expect(chatA.turns.last?.text == "ay")
        #expect(!ribbon.isRibbonActive, "A closing its own ribbon must land")
        #expect(ribbon.activeChatID == nil)
    }
}
