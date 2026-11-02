import Foundation

/// What the user has switched on or off *this session*, across every chat.
///
/// Issue #35: a feature or tool enabled in one chat used to be a property of
/// that one chat — switch chats and the fresh `ConversationModel` reseeded
/// from the model's defaults, so the choice evaporated. This is the memory
/// that was missing: a session-scoped overlay that every new chat seeds on
/// top of.
///
/// Both maps are tri-state:
///
/// * **absent** — the user has no opinion; the per-chat seed stands.
/// * **true / false** — an explicit session intent that overlays the seeds.
///   A `false` only ever turns off a key the seed already contains (never
///   introduces one), and a `true` only lands where the model supports the
///   feature — the send path ships the `features` dict wholesale, and a key
///   the model never advertised is a bug class, not a hint.
///
/// Deliberately *not* persisted: this is what you switched on while the app
/// was open, not a setting. The next launch starts from the model's defaults
/// again.
@MainActor
@Observable
public final class RunPreferences {
    /// Feature keys (see `ChatFeature`) the user has expressed an intent about.
    public var features: [String: Bool] = [:]
    /// Tool ids the user has expressed an intent about.
    public var tools: [String: Bool] = [:]

    public init() {}
}
