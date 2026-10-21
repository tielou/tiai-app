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
        public enum Phase: String, Codable, Hashable {
            case waiting = "Waiting"
            case thinking = "Thinking"
            case writing = "Writing"
            case finished = "Finished"
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

#if canImport(ActivityKit) && os(iOS)
extension GenerationActivityAttributes: ActivityAttributes {}

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
    private var startedAt = Date.now
    private var lastPhase: GenerationActivityAttributes.ContentState.Phase = .waiting

    public static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    public func start(chatTitle: String, model: String, chatID: String? = nil) {
        guard GenerationActivity.isSupported, activity == nil else { return }
        startedAt = .now
        let attributes = GenerationActivityAttributes(chatTitle: chatTitle, model: model,
                                                     chatID: chatID)
        let state = GenerationActivityAttributes.ContentState(
            phase: .waiting, characters: 0, startedAt: startedAt)
        Task { [weak self] in
            guard let self else { return }
            self.activity = try? await Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: .now + 300),
                pushType: nil)
        }
    }

    public func update(phase: GenerationActivityAttributes.ContentState.Phase, characters: Int) {
        // Re-posting the same phase on every token would hammer the system and
        // buy nothing; the character count is what moves.
        guard let activity else { return }
        let changed = phase != lastPhase || characters / 200 != lastCharacters / 200
        guard changed else { return }
        lastPhase = phase
        lastCharacters = characters
        let state = GenerationActivityAttributes.ContentState(
            phase: phase, characters: characters, startedAt: startedAt)
        Task { try? await activity.update(.init(state: state, staleDate: .now + 300)) }
    }
    private var lastCharacters = 0

    /// Ends it, and leaves it on screen briefly so a finished run is visible
    /// rather than vanished the instant it lands.
    public func finish(_ phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int) {
        guard let activity else { return }
        let state = GenerationActivityAttributes.ContentState(
            phase: phase, characters: characters, startedAt: startedAt)
        Task {
            await activity.end(using: state, dismissalPolicy: .after(.now + 15))
        }
        self.activity = nil
    }

    public func cancelIfRunning() {
        guard let activity else { return }
        Task { await activity.end(using: nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}

#else
/// macOS build: the kit compiles for tests, where there is no ActivityKit.
@MainActor
public final class GenerationActivity {
    public static let shared = GenerationActivity()
    public static var isSupported: Bool { false }
    public func start(chatTitle: String, model: String, chatID: String? = nil) {}
    public func update(phase: GenerationActivityAttributes.ContentState.Phase, characters: Int) {}
    public func finish(_ phase: GenerationActivityAttributes.ContentState.Phase,
                       characters: Int) {}
    public func cancelIfRunning() {}
}
#endif
