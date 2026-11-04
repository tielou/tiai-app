import Foundation

/// A message the user pressed send on while the phone could not reach the
/// server, kept on the phone until it demonstrably has not been sent (issue #38).
///
/// The queue (#37) holds a message that is waiting for *the assistant*; the
/// outbox holds a message that is waiting for *the network*. They are different
/// promises and they fail differently: a queued message is safe in memory
/// because the app is open and the run is one event away, while an offline send
/// can outlive a flight, a dead battery, and iOS deciding the app had better
/// die. So this one is durable, and durability is the whole design brief.
///
/// Text-only, and deliberately so. An attachment cannot survive the wait: its
/// file id only exists once the upload has answered, and the upload cannot
/// answer while offline, so a stored `Data` blob would have to be re-uploaded
/// on replay from bytes kept in the store — base64 in `UserDefaults`, written
/// on the main thread, for a photo that may be megabytes. A send with
/// attachments that fails offline therefore falls back to the issue #9
/// composer restore, which already puts the files back.
public struct OutboxEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let chatID: String
    /// The client-generated id this send put in the completion's
    /// `user_message`. It is the dedup key: the server files the user turn
    /// under the id the client supplied (the transcript read-backs show the
    /// app's own uppercase `UUID().uuidString` as the stored user message id,
    /// where every id the server minted itself is lowercase), so a replay can
    /// ask "is *this* message already in the transcript?" instead of guessing
    /// from text. Text-dedup is not safe: "ok" sent twice is two messages.
    public let userMessageID: String
    public let text: String
    public let createdAt: Date
    /// Consecutive failures, not lifetime ones: see `OutboxStore.revertToPending`.
    public var attempts: Int
    /// True while a run is carrying this entry. Survives a force-quit, which is
    /// the point: the entry is retried, and the dedup is what makes retrying a
    /// message the server may already have safe.
    public var replaying: Bool

    init(chatID: String, userMessageID: String, text: String,
         createdAt: Date = Date(), attempts: Int = 0, replaying: Bool = false) {
        self.id = UUID()
        self.chatID = chatID
        self.userMessageID = userMessageID
        self.text = text
        self.createdAt = createdAt
        self.attempts = attempts
        self.replaying = replaying
    }
}

/// The durable outbox, owned by the session and keyed per instance.
///
/// `UserDefaults`, not the file cache. The DiskCache the transcript uses has a
/// seven-day TTL and lives in `Caches`, which the OS is allowed to empty under
/// space pressure — neither is an acceptable place for a message someone typed
/// and pressed send on. Entries are text and a handful of ids, so the whole
/// store is a few hundred bytes and a synchronous write on mutation costs
/// nothing measurable; the alternative (a JSON file in Application Support) buys
/// nothing for its extra failure modes.
///
/// The test seam is the `UserDefaults` suite: a second store built on the same
/// suite is a force-quit and relaunch, with no fake filesystem in between.
@MainActor
@Observable
public final class OutboxStore {
    public private(set) var entries: [OutboxEntry] = []

    public var isEmpty: Bool { entries.isEmpty }

    private let defaults: UserDefaults
    private let key: String

    /// Entries this process has claimed for replay and not yet resolved.
    ///
    /// The persisted `replaying` flag cannot be the in-process mutex: it is
    /// deliberately ignored by `claimNext` so a fresh process can recover an
    /// entry a force-quit left in flight. But that same leniency lets two
    /// `ConversationModel` instances bound to the same chat (navigation
    /// pushing the same chat twice) each claim and send the same entry
    /// without a user gesture. This set is the other half: it lives only in
    /// memory, so it forbids a second in-process claimer while a claim is
    /// outstanding, and it evaporates on process death — which is exactly the
    /// force-quit-recovery semantics the persisted flag is for. Every path
    /// that resolves a claim (`revertToPending`, `remove`, `removeAll`) drops
    /// the id here too.
    private var inProcessClaims: Set<UUID> = []

    public init(defaults: UserDefaults = .standard, host: String = "local") {
        self.defaults = defaults
        self.key = "outbox@\(host)"
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([OutboxEntry].self, from: data) {
            self.entries = stored
        }
    }

    /// Oldest first: a chat that lost three messages should have them arrive in
    /// the order they were typed.
    public func entries(for chatID: String) -> [OutboxEntry] {
        entries.filter { $0.chatID == chatID }
    }

    public func entry(id: UUID) -> OutboxEntry? { entries.first { $0.id == id } }

    @discardableResult
    func add(chatID: String, userMessageID: String, text: String) -> OutboxEntry {
        let entry = OutboxEntry(chatID: chatID, userMessageID: userMessageID, text: text)
        entries.append(entry)
        persist()
        return entry
    }

    /// Claims the oldest entry of a chat for replay, synchronously.
    ///
    /// The claim is the mutex. Two triggers landing in the same main-actor turn
    /// (a reconnect that is also a foreground, which is the common case) would
    /// otherwise both start a run for the same entry, and the second would
    /// supersede the first. Taking the entry out of the pool in the same
    /// synchronous region as the decision is what makes "exactly one replay"
    /// true without a flag that could be left set by a crash between check and
    /// claim.
    func claimNext(for chatID: String) -> OutboxEntry? {
        guard let index = entries.firstIndex(where: {
            $0.chatID == chatID && !inProcessClaims.contains($0.id)
        }) else { return nil }
        entries[index].replaying = true
        inProcessClaims.insert(entries[index].id)
        persist()
        return entries[index]
    }

    /// Claims one named entry, for "send now" on the strip — the user pointed
    /// at a message, and replaying the oldest instead would be ignoring them.
    func claim(id: UUID) -> OutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              !inProcessClaims.contains(id)
        else { return nil }
        entries[index].replaying = true
        inProcessClaims.insert(id)
        persist()
        return entries[index]
    }

    /// Puts a failed replay back to pending and counts it — or does not.
    ///
    /// The cap is on *consecutive* failures, not on how many times a trigger
    /// fired. An entry that fails while the phone is still offline is not a
    /// message the server refused; it is the same attempt seen again, and
    /// counting it means a long flight with three app foregrounds dumps every
    /// pending message into the composer with a red banner. The caller says
    /// which one it was by passing `burnsAttempt`.
    func revertToPending(id: UUID, burnsAttempt: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].replaying = false
        inProcessClaims.remove(id)
        if burnsAttempt { entries[index].attempts += 1 }
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        inProcessClaims.remove(id)
        persist()
    }

    public func removeAll() {
        entries = []
        inProcessClaims.removeAll()
        persist()
    }

    /// Throws away everything waiting for one chat, for the chat's own deletion.
    ///
    /// A pending message in a chat that no longer exists can never be shown (the
    /// strip lives in that chat's screen) and can never be sent (the server 404s
    /// the id), so keeping it is keeping someone's text with no way to get at it.
    public func removeAll(for chatID: String) {
        guard entries.contains(where: { $0.chatID == chatID }) else { return }
        let removed = entries.filter { $0.chatID == chatID }.map(\.id)
        entries.removeAll { $0.chatID == chatID }
        inProcessClaims.subtract(removed)
        persist()
    }

    /// Synchronous on purpose. A write that is deferred is a write that can be
    /// lost to the exact thing this store exists for — the app being killed
    /// while offline, which is to say with no second chance to retry.
    private func persist() {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
