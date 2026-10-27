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

/// Issue #20: a brand-new chat raises its ribbon before the server has named
/// the chat, so the owner token starts nil — and nil matches *anything*.
/// Nothing used to upgrade the token when the run adopted its id, so the
/// ribbon stayed unclaimed for its whole run and any other chat's `finish`
/// could close it. `claim` closes that window at adoption.
@Suite(.serialized)
struct RibbonClaim {
    /// The acceptance scenario, stub-level: raise unclaimed, adopt (claim),
    /// a foreign finish no-ops, the adopting run still closes its own.
    @Test @MainActor func adoptedIdClaimsTheRibbonAndForeignFinishesCannotCloseIt() async {
        let ribbon = GenerationActivity()
        // A brand-new chat raises the ribbon: live, but unclaimed.
        await ribbon.start(chatTitle: "New chat", model: "m", chatID: nil)
        #expect(ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == nil)

        // The run adopts the id the server chose: the token upgrades.
        ribbon.claim(chatID: "chat-adopted")
        #expect(ribbon.activeChatID == "chat-adopted")

        // Pre-#20 the ribbon was still nil-owned here — nil matches anything —
        // and this closed it. Now the ribbon has a real owner and a mismatch
        // makes the finish a no-op.
        await ribbon.finish(.finished, characters: 5, chatID: "chat-other")
        #expect(ribbon.isRibbonActive, "an adopted-id ribbon is owned; another chat's finish must no-op")
        #expect(ribbon.activeChatID == "chat-adopted")
        // Updates from the wrong chat are gated the same way.
        await ribbon.update(phase: .writing, characters: 40, chatID: "chat-other")
        #expect(ribbon.acceptedUpdates == 0)

        // The adopting run still closes its own ribbon at its end.
        await ribbon.finish(.finished, characters: 9, chatID: "chat-adopted")
        #expect(!ribbon.isRibbonActive)
        #expect(ribbon.activeChatID == nil)
    }

    /// Pins the *only-while-nil* rule: a claim upgrades an unclaimed ribbon
    /// and nothing else. Without this pin, an unconditional overwrite would
    /// let a second chat's claim steal a live ribbon — the same class of bug
    /// #15 was.
    @Test @MainActor func claimUpgradesOnlyAnUnclaimedRibbon() async {
        let ribbon = GenerationActivity()
        // No ribbon live: there is nothing to upgrade, and no owner may be
        // invented out of thin air.
        ribbon.claim(chatID: "chat-z")
        #expect(ribbon.activeChatID == nil)
        #expect(!ribbon.isRibbonActive)

        await ribbon.start(chatTitle: "Chat A", model: "m", chatID: "chat-a")
        // A live ribbon with a real owner must survive a stranger's claim.
        ribbon.claim(chatID: "chat-b")
        #expect(ribbon.activeChatID == "chat-a", "a claim must never overwrite a real owner")
        // The owner claiming its own id is a no-op (idempotent).
        ribbon.claim(chatID: "chat-a")
        #expect(ribbon.activeChatID == "chat-a")

        // Only the nil-but-live (brand-new chat) state is claimable.
        await ribbon.finish(.finished, characters: 1, chatID: "chat-a")
        await ribbon.start(chatTitle: "New", model: "m", chatID: nil)
        ribbon.claim(chatID: "chat-new")
        #expect(ribbon.activeChatID == "chat-new")
    }

    /// The wiring: the model's adoption point (`adopt(chatID:)`) is what
    /// claims the ribbon. A brand-new chat sends, raises the ribbon
    /// unclaimed, adopts its id from the first frame — and from that moment
    /// another chat's finish cannot close it. The adopting run then closes
    /// its own ribbon as usual.
    @Test @MainActor func aNewChatClaimsItsRibbonWhenTheStreamNamesItsId() async throws {
        let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
        let hub = ChatEventHub(server: server)
        let ribbon = GenerationActivity()
        let transport = ScriptedTransport()
        // A generated title lands on the first refetch, so the run's terminal
        // block does not sit in `awaitGeneratedTitle`'s backoff (the default
        // stub detail says "New Chat", which that loop deliberately ignores).
        transport.chatDetailOverride = Data(
            """
            {"id":"chat-adopted","title":"Salzburg trains","updated_at":1,"created_at":1,
             "chat":{"models":["local-personal"],"history":{"currentId":null,"messages":{}}}}
            """.utf8)
        let fresh = ConversationModel(
            chatID: nil,
            models: [ChatModel.stub("local-personal")],
            client: OWUIClient(server: server, transport: transport),
            hub: hub, activity: ribbon)

        fresh.draft = "which train goes to Salzburg"
        fresh.send()
        try await transport.awaitCompletion()
        let answerID = try #require(transport.assistantMessageID)
        // The ribbon is up but unclaimed: a new chat has no id to raise it with.
        try await waitUntil { ribbon.isRibbonActive }
        #expect(ribbon.activeChatID == nil)

        // The first frames for a real chat id are the adoption point: the
        // model takes the id and claims the ribbon with it.
        let frames = Frames.run(chat: "chat-adopted", message: answerID, answer: "the 08:15")
        hub.receive(frames[0])
        hub.receive(frames[1])
        try await waitUntil { ribbon.activeChatID == "chat-adopted" }

        // Another chat's finish — the exact #15 shape, now against a ribbon
        // whose real owner was adopted mid-run. Pre-#20 the token was still
        // nil here and this closed the ribbon.
        await ribbon.finish(.finished, characters: 5, chatID: "chat-other")
        #expect(ribbon.isRibbonActive, "the adopted id owns the ribbon; a foreign finish must no-op")
        #expect(ribbon.activeChatID == "chat-adopted")

        // The run ends: its own finish carries the adopted id and closes it.
        hub.receive(frames[2])
        try await waitUntil(timeout: .seconds(5)) { fresh.phase == .ready }
        #expect(fresh.turns.last?.text == "the 08:15")
        #expect(!ribbon.isRibbonActive, "the adopting run must still close its own ribbon")
        #expect(ribbon.activeChatID == nil)
    }
}
