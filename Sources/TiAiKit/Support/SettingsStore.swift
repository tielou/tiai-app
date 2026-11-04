import Foundation

/// Per-server defaults the user sets once instead of per chat.
///
/// Scoped by host on purpose: a system prompt written for a home server with
/// terminal access is wrong for a work one, and pointing the app at a second
/// instance should not silently inherit the first one's instructions.
///
/// These live on the phone, not on the server. Open WebUI stores its own defaults
/// in user settings, but those are the web UI's to write and reading them back
/// means guessing at a schema; the app keeps its own so it can never overwrite
/// something the web UI owns.
public struct AppDefaults: Codable, Equatable, Sendable {
    /// Prepended to every new conversation as the system message.
    public var systemPrompt: String
    /// nil means "whatever the server picked", which is the right default: a
    /// number chosen for one model is wrong for the next one.
    public var temperature: Double?
    /// Ask to be told when an answer lands while the app is not the thing on
    /// screen. On by default: a long answer outlives the app switcher, and
    /// sliding back to a transcript that has not moved is indistinguishable from
    /// a hung one. The permission prompt is deferred to the first send rather
    /// than launch, so it arrives at a moment where the request makes sense.
    public var notifyWhenFinished: Bool
    /// Send a message pressed while the assistant is still generating to the
    /// chat's queue instead of dropping it (issue #37). On by default: the
    /// behaviour it replaces is a silent no-op — the button was a Stop control,
    /// so a follow-up typed in a hurry vanished and the user had no way to know.
    /// A queue the user can see and take back is honest in a way that nothing
    /// happening at all is not.
    public var queueWhileGenerating: Bool
    /// Keep a send made with no connectivity in the durable outbox and replay it
    /// when the network returns (issue #38). On by default: the behaviour it
    /// replaces is the issue #9 rollback, which is honest but asks someone who
    /// just typed a paragraph on a train to retype it once they land. A message
    /// that says "pending, will send when you're back" is the same truth told in
    /// the direction the user can act on.
    public var outboxWhileOffline: Bool
    /// Voice for read-aloud. nil means "whatever the instance configured", which
    /// matters because voice names are not portable across engines — `alloy`
    /// means something to OpenAI and nothing to Edge.
    public var readAloudVoice: String?

    public init(
        systemPrompt: String = "", temperature: Double? = nil, notifyWhenFinished: Bool = true,
        readAloudVoice: String? = nil, queueWhileGenerating: Bool = true,
        outboxWhileOffline: Bool = true
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.notifyWhenFinished = notifyWhenFinished
        self.readAloudVoice = readAloudVoice
        self.queueWhileGenerating = queueWhileGenerating
        self.outboxWhileOffline = outboxWhileOffline
    }

    /// "Nothing here that the user chose." Compared against a fresh default
    /// rather than against all-off: notifications are on by default now, so
    /// turning them *off* is a preference worth remembering, not noise.
    public var isEmpty: Bool {
        systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && temperature == nil && readAloudVoice == nil
            && notifyWhenFinished == AppDefaults().notifyWhenFinished
            && queueWhileGenerating == AppDefaults().queueWhileGenerating
            && outboxWhileOffline == AppDefaults().outboxWhileOffline
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt, temperature, notifyWhenFinished, readAloudVoice,
             queueWhileGenerating, outboxWhileOffline
    }

    /// Hand-written decode, and only because of what is already on phones.
    ///
    /// The stored blob predates `queueWhileGenerating`, and the synthesised
    /// decoder asks for every key: a missing one throws, `load` falls back to a
    /// fresh `AppDefaults`, and an app update silently resets the user's system
    /// prompt and temperature. `decodeIfPresent` with the current default is the
    /// whole fix, and it is the last new key that needs it — from now on the
    /// blob always has every key this struct has.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        notifyWhenFinished =
            try container.decodeIfPresent(Bool.self, forKey: .notifyWhenFinished)
            ?? AppDefaults().notifyWhenFinished
        readAloudVoice = try container.decodeIfPresent(String.self, forKey: .readAloudVoice)
        queueWhileGenerating =
            try container.decodeIfPresent(Bool.self, forKey: .queueWhileGenerating)
            ?? AppDefaults().queueWhileGenerating
        // Same `decodeIfPresent` reason as above: this key is newer than the
        // blobs already on phones, and the synthesised decoder would throw on
        // its absence and reset the user's prompt along with it.
        outboxWhileOffline =
            try container.decodeIfPresent(Bool.self, forKey: .outboxWhileOffline)
            ?? AppDefaults().outboxWhileOffline
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var defaults: AppDefaults {
        didSet { persist() }
    }

    private var host: String

    private init() {
        host = "local"
        defaults = AppDefaults()
    }

    /// Called whenever the app points at a different server; the defaults shown
    /// are that server's, not the last one's.
    public func point(at url: URL?) {
        let next = url?.host ?? "local"
        guard next != host else { return }
        host = next
        defaults = Self.load(host: next)
    }

    private func persist() {
        let key = "tiai.defaults.\(host)"
        if defaults.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(defaults) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(host: String) -> AppDefaults {
        guard let data = UserDefaults.standard.data(forKey: "tiai.defaults.\(host)"),
              let stored = try? JSONDecoder().decode(AppDefaults.self, from: data)
        else { return AppDefaults() }
        return stored
    }
}
