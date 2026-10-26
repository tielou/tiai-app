import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What a running generation looks like from outside the app.
///
/// The pain this answers is specific: a long answer outlives the app switcher,
/// iOS kills the socket in the background, and coming back to a transcript that
/// has not moved is indistinguishable from a hung one. A Live Activity says
/// "still working, this is the model, this long" and tapping it lands you back in
/// the chat that is doing the work.
///
/// Nothing secret goes in here. Live Activity content is readable by the system
/// and appears on a locked screen, so it carries a chat's title and a model name
/// and never a word of the prompt or the answer.
public struct GenerationActivityAttributes: Codable, Hashable {
    /// The chat's title, fixed for the life of the activity.
    public var chatTitle: String
    /// Which model is working, so five local ones are tellable apart at a glance.
    public var model: String
    /// So tapping the ribbon lands in the chat that is doing the work rather than
    /// wherever the app happens to reopen. Optional because a brand new chat has
    /// no id until the server answers.
    public var chatID: String?

    public init(chatTitle: String, model: String, chatID: String? = nil) {
        self.chatTitle = chatTitle
        self.model = model
        self.chatID = chatID
    }

    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable, Sendable {
            case waiting = "Waiting"
            case thinking = "Thinking"
            case writing = "Writing"
            case finished = "Done"
            case stopped = "Stopped"
        }
        public var phase: Phase
        /// How much has arrived so far. A number that moves is the difference
        /// between "working" and "stuck" when you are not looking at the app.
        public var characters: Int
        public var startedAt: Date

        public init(phase: Phase, characters: Int, startedAt: Date) {
            self.phase = phase
            self.characters = characters
            self.startedAt = startedAt
        }
    }
}

/// The ribbon ownership rule, shared by both variants of `GenerationActivity`.
///
/// The ribbon is a process singleton — one at a time — but a chat's run keeps
/// running after the user switches away (the answer must survive the trip), so
/// an orphaned model can otherwise finish *another* chat's ribbon (issue #15).
/// `start` records who raised the ribbon; `update` and `finish` only touch it
/// when the caller matches.
///
/// A match is: either side nil, or the two ids equal. nil means *unclaimed*:
/// a brand-new chat raises its ribbon before the server has answered with an
/// id, and nothing ever upgrades the token when the run adopts the id later —
/// a new chat's ribbon stays nil-owned for its whole run. The identity
/// `start` had was nil, and `finish` passes the *current* (adopted) id, so a
/// nil owner must match anything or the adopting run could never close its
/// own ribbon. The accepted trade: while a nil-owner ribbon is live, any
/// finish may close it — strictly better than stranding the new chat's
/// ribbon forever, and identical to the pre-fix behavior. Closing the window
/// for real means claiming the token at adoption (filed as a follow-up).
private func ribbonMatches(owner activeChatID: String?, caller chatID: String?) -> Bool {
    activeChatID == nil || chatID == nil || activeChatID == chatID
}

#if canImport(ActivityKit) && os(iOS)
extension GenerationActivityAttributes: ActivityAttributes {}

/// Every field is a value type, so this is a real conformance rather than an
/// unchecked one. Without it the state cannot cross into `Activity`'s async
/// methods at all.
extension GenerationActivityAttributes.ContentState: Sendable {}

/// Starts, updates and ends the Live Activity for a run.
///
/// Every method is safe to call when the feature is unavailable, unsupported or
/// simply refused in Settings — a chat app that fails to send a message because
/// it could not show a ribbon has put the cart before the horse. Calls are fire
/// and forget by design: they are wrapped in a Task so a slow or refused
/// ActivityKit call can never delay the message that triggered it.
@MainActor
public final class GenerationActivity {
    public static let shared = GenerationActivity()

    private var activity: Activity<GenerationActivityAttributes>?
    /// Which chat owns the live ribbon; nil while none is live, and nil-but-live
    /// for a brand-new chat whose id the server has not named yet (see
    /// `ribbonMatches`). Set on a successful `start`, cleared on `finish`/
    /// `cancelIfRunning`.
    public private(set) var activeChatID: String?
    private var startedAt = Date.now
    private var lastPhase: GenerationActivityAttributes.ContentState.Phase = .waiting

    public static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // Async rather than fire-and-forget. `Activity` is not `Sendable`, so the
    // obvious `Task { activity.update(...) }` is a data race by the compiler's
    // reckoning — and it is right, the object would be crossing isolation. Awaiting
    // in place keeps it on the main actor, which is where it already lives.
    public func start(chatTitle: String, model: String, chatID: String? = nil) async {
        guard GenerationActivity.isSupported, activity == nil else { return }
        startedAt = .now
        lastPhase = .waiting
        lastCharacters = 0
        let attributes = GenerationActivityAttributes(chatTitle: chatTitle, model: model,
                                                     chatID: chatID)
        let state = GenerationActivityAttributes.ContentState(
            phase: .waiting, characters: 0, startedAt: startedAt)
        activity = try? await Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: .now + 300),
            pushType: nil)
        // The owner token is recorded only for a ribbon that actually exists —
        // a refused request leaves nothing to guard.
        activeChatID = activity == nil ? nil : chatID
    }

    public func update(phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int, chatID: String?) async {
        // Re-posting the same phase on every token would hammer the system and
        // buy nothing; the character count is what moves.
        guard let activity else { return }
        // An orphaned run must not repaint someone else's ribbon.
        guard ribbonMatches(owner: activeChatID, caller: chatID) else { return }
        let changed = phase != lastPhase || characters / 200 != lastCharacters / 200
        guard changed else { return }
        lastPhase = phase
        lastCharacters = characters
        let state = GenerationActivityAttributes.ContentState(
            phase: phase, characters: characters, startedAt: startedAt)
        // `Activity` is not `Sendable` in the SDK — an Apple gap, not a real
        // hazard here: the handle is only ever touched from the main actor, and
        // the await is a call into ActivityKit, not a hand-off to another thread.
        nonisolated(unsafe) let target = activity
        try? await target.update(.init(state: state, staleDate: .now + 300))
    }
    private var lastCharacters = 0

    /// Ends it, and leaves it on screen briefly so a finished run is visible
    /// rather than vanished the instant it lands.
    public func finish(_ phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int, chatID: String?) async {
        guard let activity else { return }
        // The bug this gate kills: chat A's run finishes after the user moved
        // to chat B and ends the ribbon B is watching (issue #15).
        guard ribbonMatches(owner: activeChatID, caller: chatID) else { return }
        let state = GenerationActivityAttributes.ContentState(
            phase: phase, characters: characters, startedAt: startedAt)
        self.activity = nil
        self.activeChatID = nil
        nonisolated(unsafe) let target = activity
        // No sound here, deliberately. `ActivityContent` carries no alert
        // parameter in this SDK — a Live Activity can only be made to chime by a
        // push, which this app has no server for. The audible signal is a local
        // notification instead; see CompletionNotifier.
        // Held for 30s rather than 15: "Done" has to survive being noticed.
        await target.end(using: state, dismissalPolicy: .after(.now + 30))
    }

    public func cancelIfRunning() async {
        guard let activity else { return }
        self.activity = nil
        self.activeChatID = nil
        nonisolated(unsafe) let target = activity
        await target.end(using: nil, dismissalPolicy: .immediate)
    }
}

#else
/// macOS build: the kit compiles for tests, where there is no ActivityKit.
///
/// The stub is what the tests run against, so it does not merely no-op: it
/// simulates a working ribbon — one live at a time, with the same ownership
/// gating as the iOS variant — and exposes the state (`isRibbonActive`,
/// `activeChatID`, `acceptedUpdates`) that the issue #15 tests assert on.
@MainActor
public final class GenerationActivity {
    public static let shared = GenerationActivity()
    public static var isSupported: Bool { false }

    /// Mirrors the iOS variant's `activity != nil`: a ribbon is live.
    public private(set) var isRibbonActive = false
    /// The chat that raised the live ribbon; nil while none is live, and
    /// nil-but-live for an unclaimed (brand-new chat) ribbon. See
    /// `ribbonMatches` for why nil matches anything.
    public private(set) var activeChatID: String?
    /// `update` calls that passed the ownership gate — the observable stand-in
    /// for "the ribbon text actually moved".
    public private(set) var acceptedUpdates = 0

    public func start(chatTitle: String, model: String, chatID: String? = nil) async {
        // One ribbon at a time, exactly like the iOS guard on `activity == nil`:
        // a second chat's start no-ops and the owner stays whoever raised it.
        guard !isRibbonActive else { return }
        isRibbonActive = true
        activeChatID = chatID
    }

    public func update(phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int, chatID: String?) async {
        guard isRibbonActive, ribbonMatches(owner: activeChatID, caller: chatID) else { return }
        acceptedUpdates += 1
    }

    public func finish(_ phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int, chatID: String?) async {
        guard isRibbonActive, ribbonMatches(owner: activeChatID, caller: chatID) else { return }
        isRibbonActive = false
        activeChatID = nil
    }

    public func cancelIfRunning() async {
        isRibbonActive = false
        activeChatID = nil
    }
}
#endif
