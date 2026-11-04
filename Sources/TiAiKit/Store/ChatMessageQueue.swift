import Foundation

/// The messages the user pressed send on *while the assistant was still
/// generating*, held per chat until the run ends (issue #37).
///
/// Before this, send-while-generating was a silent no-op: the button was a Stop
/// control and `send()` refused on `phase.isBusy`, so a follow-up typed in a
/// hurry was simply lost — either on the floor or, worse, thought-by-the-user to
/// have been sent. Queuing is the honest shape: the message is kept, it is
/// visible, and it goes out the moment the chat can take it.
///
/// The queue is deliberately dumb. It stores, removes and hands back; every
/// decision about *when* to drain, whether the combined message is allowed at
/// all, and what a failed upload means lives in `ConversationModel`, next to the
/// run machinery those decisions need. Keeping the policy out of the store is
/// what keeps this reviewable.
///
/// It lives on `SessionStore` rather than on `ConversationModel` for the same
/// reason the run preferences do (issue #35): navigating away and back builds a
/// fresh model, and a queue that dies with it is a queue that eats messages.
@MainActor
@Observable
public final class ChatMessageQueue {
    /// One queued message.
    ///
    /// A class, not a struct, because an upload that is still on the wire holds
    /// a reference to the item it belongs to: the file lands whenever the
    /// server answers, which can be after the item has been edited, re-ordered
    /// or drained. A struct copy would land the bytes in a value nobody is
    /// holding any more.
    @MainActor
    @Observable
    public final class Item: Identifiable {
        public let id: UUID
        public var text: String
        /// Already-uploaded files that will travel with this message.
        public var attachments: [ConversationModel.PendingAttachment]
        /// True while a file picked for this item is still on the wire. The
        /// drain waits on this: sending the text while its picture is still
        /// uploading is the "I sent a photo and it never arrived" bug (#22),
        /// and the queue is not a place to reintroduce it.
        public var awaitingUploads: Bool
        /// Set when an upload for this item failed or gave up. The item is
        /// still sent — with the failure said out loud in the banner rather
        /// than the file vanishing from the message on the app's own
        /// authority.
        public var uploadFailed: Bool

        init(text: String, attachments: [ConversationModel.PendingAttachment],
             awaitingUploads: Bool = false) {
            self.id = UUID()
            self.text = text
            self.attachments = attachments
            self.awaitingUploads = awaitingUploads
            self.uploadFailed = false
        }
    }

    public private(set) var items: [Item] = []

    public var isEmpty: Bool { items.isEmpty }
    /// The drain gate: an item with a file still on the wire holds the whole
    /// queue, because the items go out as one message.
    public var hasItemAwaitingUpload: Bool { items.contains(where: \.awaitingUploads) }
    /// The stronger gate: an item whose upload *failed* holds the queue too.
    ///
    /// Letting it through would send the message with its file quietly removed
    /// — the app deciding on the user's authority that the picture did not
    /// matter. So a failed file stops the queue and says so, and the strip's
    /// Edit and Delete are the two ways on: fix the attachment, or throw the
    /// message away. Both are the user's call, which is the whole difference.
    public var hasBlockedItem: Bool { items.contains { $0.awaitingUploads || $0.uploadFailed } }

    @discardableResult
    func enqueue(text: String, attachments: [ConversationModel.PendingAttachment],
                 awaitingUploads: Bool = false) -> Item {
        let item = Item(text: text, attachments: attachments, awaitingUploads: awaitingUploads)
        items.append(item)
        return item
    }

    func item(for id: UUID) -> Item? { items.first { $0.id == id } }

    /// Takes one item out without sending it — "send now" and "edit" both
    /// remove first and decide afterwards, and both put it back if they
    /// change their minds.
    @discardableResult
    func remove(id: UUID) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Empties the queue and hands everything back, in order.
    ///
    /// Synchronous and destructive on purpose: the drain takes the whole queue
    /// in the same main-actor turn it decides to send, so there is no window in
    /// which a second trigger can observe — and take — the same items. A
    /// `drainInFlight` flag would be the alternative, and it would be wrong the
    /// moment two triggers land in one turn.
    func takeAll() -> [Item] {
        defer { items = [] }
        return items
    }

    /// Puts items back at the front, in order, for a drain that decided not to
    /// send after all (a guard refused the combined message, a stop raced the
    /// steered send). The queue's one promise is that it does not lose things.
    func putBackFront(_ items: [Item]) {
        self.items.insert(contentsOf: items, at: 0)
    }

    /// Puts another queue's items in front of this one's. Used when a new chat's
    /// stand-in queue is re-keyed onto the id the server chose and the chat
    /// already had a queue of its own.
    func absorb(_ other: ChatMessageQueue) { items.insert(contentsOf: other.items, at: 0) }

    func removeAll() { items = [] }
}

/// The per-chat queues, owned by the session.
///
/// Keyed by chat id, so a chat's queue is found by whichever model instance
/// happens to be showing it. A chat that does not exist yet is keyed by a
/// per-model stand-in and re-keyed when the server names it — otherwise the
/// first message of a new chat would be queued under a key nothing else can
/// find, and a new chat that adopts its id would silently drop what was queued
/// for it.
@MainActor
@Observable
public final class MessageQueueStore {
    public init() {}

    private var queues: [String: ChatMessageQueue] = [:]

    public func queue(for key: String) -> ChatMessageQueue {
        if let found = queues[key] { return found }
        let created = ChatMessageQueue()
        queues[key] = created
        return created
    }

    /// Moves a new chat's stand-in entry onto its real id.
    ///
    /// Merges rather than overwrites: if the real chat already had a queue (the
    /// id was opened in another model while this one was naming itself), the
    /// items from both are the user's messages, and dropping either is the bug.
    func migrate(from key: String, to chatID: String) {
        guard key != chatID, let moving = queues.removeValue(forKey: key) else { return }
        guard let existing = queues[chatID] else {
            queues[chatID] = moving
            return
        }
        existing.absorb(moving)
    }

    public func removeAll() { queues = [:] }
}
