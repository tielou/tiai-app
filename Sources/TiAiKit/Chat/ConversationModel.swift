import Foundation

/// The state behind one conversation.
///
/// Everything here follows from four things the probe measured rather than
/// assumed, and they are worth writing down because all four are
/// counter-intuitive:
///
/// 1. The chat must exist before the completion is sent. A server-minted new
///    chat id is announced only over the socket, so a client that lets the
///    server create the chat cannot subscribe in time to hear its own answer.
/// 2. The completion must carry the assistant message id as `id`. Without it the
///    server creates no event emitter and the exchange is silently never written
///    to the transcript — the answer arrives, and then never happened.
/// 3. The POST does not return until the model has finished, and its body is
///    empty. Content arrives over the socket, so the POST runs in one task while
///    this reads frames in another.
/// 4. The end of a run is a `finish_reason`, not a `done` frame.
@MainActor
@Observable
public final class ConversationModel {
    public enum Phase: Equatable {
        case loading
        case ready
        /// Sent, waiting for the first token.
        case waiting
        /// Tokens arriving.
        case streaming
        /// Stop requested, waiting for the run to actually end.
        case stopping

        public var isBusy: Bool { self != .ready && self != .loading }
    }

    public private(set) var turns: [Turn] = []
    public private(set) var phase: Phase = .ready
    public private(set) var error: String?
    /// Set when a send was refused for crossing the image budget and there is
    /// something the client can do about it: the oldest persisted images that
    /// must be replaced with placeholders to let the send through (issue #2).
    /// The UI offers `trimOldestImagesToFit()` while this is non-nil; the send
    /// itself stays blocked either way, because the engine would 500.
    public private(set) var imageTrim: ImageTrimOffer?
    /// Re-entrancy gate for `trimOldestImagesToFit`: the phase never goes busy
    /// during a trim, so without this a second confirm could run a concurrent
    /// trim whose recompute passes the confirm-gate (turns not yet mutated)
    /// and re-trims an already-trimmed message into a double placeholder.
    private var isTrimming = false
    /// Takes the error banner away. Errors used to clear themselves on the next
    /// send or on the next successful run, which is fine for a failure that
    /// fixes itself but not for one the user has already read — a banner that
    /// outlives its meaning is noise, and the dismiss affordance has to be
    /// honest about what it dismisses (issue #9).
    public func dismissError() { error = nil; imageTrim = nil }
    public private(set) var title: String
    /// Nil until the chat exists. It is set by `createChat`, not by the caller —
    /// a new conversation learns its own id mid-send.
    public private(set) var chatID: String?

    /// What the composer holds. On the model rather than in `@State` so a draft
    /// survives navigating away and back.
    public var draft = ""
    public var model: String
    public var features: [String: Bool]
    /// Tool ids to offer this run. Empty means the server's own default set for
    /// the model, which is what almost every chat wants.
    public var tools: [String] = []
    /// The terminal to run code in, named on every request as `terminal_id`.
    /// Without it the server does not offer the terminal's tools at all, so a
    /// model asked for a PDF will describe one instead of making one.
    public var terminalID: String?
    /// The chat's template variables, carried back untouched on every send.
    public var chatVariables: JSONValue?
    public var modelIDs: [String] = []
    /// The models themselves, kept because capabilities live on them
    /// and a few decisions — can this model be shown a picture at all —
    /// cannot be made from an id.
    public var models: [ChatModel] = []

    /// The instance client. Public because dictation runs from the composer and
    /// posts audio straight to the server; the model has no reason to intermediate
    /// a transcription.
    public let client: OWUIClient
    /// The instance root, for links that are not API calls — an OAuth sign-in
    /// page is a web page, and it lives at the site root rather than under
    /// `/api/v1`.
    public var serverURL: URL { client.server.baseURL }
    /// The bearer token and host, for the one flow that is not an API call: an
    /// MCP OAuth sign-in needs Open WebUI's session as a cookie, and this is the
    /// session the app already has.
    public var authToken: String { client.server.token }
    public var serverHost: String { client.server.baseURL.host ?? "" }
    private let hub: ChatEventHub
    private var run: Task<Void, Never>?
    private var post: Task<Void, Never>?
    /// #36: the hub token of the pre-id ("waiting") listener THIS model
    /// installed for the current run, nil when it subscribed by chat id.
    /// It is the precise address of this model's own listener, so teardown
    /// ends exactly it — replacing the global `expireWaitingListeners()`
    /// sweep and every blast-radius gate that guarded it (#9, #28, #30).
    /// Held for the whole run: expiring an already-adopted or already-removed
    /// token is a no-op, so there is no race with the adopt hop — and the
    /// adopted-id residual #30 documented is covered, because the subscriber
    /// keeps its token as its key through adoption.
    @ObservationIgnored private var waitingToken: UUID?
    /// Which run currently owns this model's state. Bumped when a run starts
    /// (send/edit/regenerate) or the current one is given up (abandon). A run
    /// that captured an older generation was superseded mid-await and must not
    /// write state it no longer owns — the next run's POST slot, phase, error
    /// or transcript. stop() captures but never bumps: a stop belongs to the
    /// run it stops. Invariant this relies on: phase == .ready implies post was
    /// cancelled — every path to .ready cancels the slot first.
    private var runGeneration = 0
    private func isCurrent(_ gen: Int) -> Bool { gen == runGeneration }
    /// The message of a completion POST that failed while the run was still
    /// `.waiting` with not a single frame seen. Set by `recordPostError`,
    /// consumed by `exchange` after the drain to roll the phantom send back
    /// (issue #9), and cleared before every new POST so a stale failure can
    /// never poison the next run.
    private var postFailureMessage: String?
    /// The message the next reply will be filed under. Tracked explicitly rather
    /// than derived from `turns`, because "the last thing in the tree" is exactly
    /// the thing regenerate and edit change.
    private var leafID: String?

    /// How long to wait on a silent stream before calling it dead: no frame
    /// for this run's message for this long means the stream is dead. It is a
    /// silence budget, not a run cap — every frame this drain attributes to
    /// this message re-arms it (issue #33), so a long run that keeps talking
    /// is never cut off. Longer than the slowest legitimate gap (cold
    /// prefill, a thinking pause) you have seen, shorter than someone's
    /// patience.
    static let silenceLimit: Duration = .seconds(60)
    /// #42: the absolute ceiling on one live run, independent of frame
    /// activity. The silence watchdog measures quiet and can be outrun by a
    /// stream that never goes quiet and never terminates — a terminal frame
    /// that is filtered, mis-keyed, or never emitted at all. The live case
    /// was a chat whose frames never carried a chat id: the watchdog fired
    /// every 60 s and expired nothing (no adopted id to expire by), and the
    /// run stayed "running" for an hour over a server record that had been
    /// `done` for fifty minutes. When the ceiling fires the stream ends
    /// whatever the frame traffic looks like, and the caller's reconcile
    /// reads the truth off the server record — the "leave and re-enter
    /// fixes it" recovery the user already trusts, on a bound. Generous on
    /// purpose: a healthy long run (twenty tool calls, a weasyprint build,
    /// a slow local prefill) must never meet it.
    static let runCeiling: Duration = .seconds(900)
    /// How long a turn may sit between a `finish_reason` and the tool result that
    /// follows it. Long enough for a slow MCP server, short enough that a tool
    /// which died silently does not leave the composer spinning for three minutes.
    static let handoffLimit: Duration = .seconds(60)

    /// How long to wait after an errored run claims to have finished, to see
    /// whether it really is finished.
    ///
    /// Not the tool-handoff budget: a tool may legitimately take a minute, but
    /// an errored run that stays silent for a few seconds is done, and making
    /// the user watch a spinner for a minute over a hiccup is its own bug.
    static let errorRecoveryLimit: Duration = .seconds(3)    /// Deltas are coalesced before they reach observable state: a model emitting
    /// token by token would otherwise invalidate the transcript view per token,
    /// which is the difference between a smooth stream and a stuttering one.
    static let flushInterval: Duration = .milliseconds(60)

    /// The most images one completion may carry.
    ///
    /// The inference engine hard-rejects anything above 64 images ("IMG count
    /// outside 0..64", surfaced as a litellm 500), and the client cannot trim
    /// the history the server rebuilds from the persisted chat tree — the
    /// outgoing `messages` carry no historical images at all. So a send that
    /// would cross the cap is refused with a clear error before anything is
    /// touched. 50 rather than 64 leaves headroom for the count drift that
    /// cannot be measured exactly: server-side additions and the
    /// files-vs-content double-count below.
    nonisolated static let maxImagesPerRequest = 50

    /// Test seam: shrink the cap so a test can drive the over-cap path with
    /// five messages instead of fifty-one. Nil (production) uses
    /// `maxImagesPerRequest`.
    var maxImagesPerRequestOverride: Int?

    /// The effective image cap for this conversation.
    private var imageCap: Int { maxImagesPerRequestOverride ?? Self.maxImagesPerRequest }

    /// The images the next completion would put in front of the engine: every
    /// image already on the loaded branch, plus what the message being sent
    /// adds.
    ///
    /// Per message, the content `image_url` blocks are counted one by one — two
    /// identical photos in one message are two images to the engine, so they are
    /// two images here too. The only dedup is a block that *is* one of the
    /// message's own files: `file_id://X` is normalised to the file id `X`, and a
    /// `data:` block a file chip was built from already carries that id, so each
    /// file absorbs at most one matching block. A picture the app sent itself is
    /// stored as a file *and* a `data:` block with unrelated identifiers, so it
    /// counts twice: over-counting refuses a send early, under-counting
    /// reproduces the engine's opaque 500, and only one of those is recoverable.
    /// Counted regardless of whether the current model has vision — the cap is
    /// about the stored conversation the server rebuilds, not this model's eyes.
    nonisolated static func imageCount(in turns: [Turn], outgoing: [PendingAttachment]) -> Int {
        turns.reduce(0) { $0 + imageCount(in: $1) } + outgoing.filter(\.isImage).count
    }

    /// The images one message puts in front of the engine — the per-message
    /// half of `imageCount(in:outgoing:)`, split out so the trim offer can
    /// walk the branch oldest-first one message at a time.
    nonisolated static func imageCount(in turn: Turn) -> Int {
        func key(for url: String) -> String {
            let prefix = "file_id://"
            return url.hasPrefix(prefix) ? String(url.dropFirst(prefix.count)) : url
        }
        let imageFiles = turn.attachments.filter(\.isImage).map(\.id)
        var files = Set(imageFiles)
        var count = imageFiles.count
        for url in turn.contentImageURLs {
            // A block that is one of this message's files is that file and
            // not an extra image — but it absorbs only one block, so a
            // second identical block still counts.
            if files.remove(key(for: url)) != nil { continue }
            count += 1
        }
        return count
    }

    /// The refusal shown when the next request would cross
    /// `maxImagesPerRequest`, nil when it fits.
    ///
    /// The wording carries the actual numbers and the only way out. There is no
    /// "continue without the pictures" to offer: the server rebuilds the
    /// engine's messages from the persisted tree, so a text-only send in an
    /// over-cap branch is still over the cap on history alone.
    ///
    /// `uploadsInFlightImages` is part of the projection because a photo still
    /// on the wire is an image the next request will carry: `attachments` only
    /// gains its entry when the upload answers.
    private func imageLimitMessage(outgoing: [PendingAttachment]) -> String? {
        let inFlight = uploadsInFlightImages
        let count = Self.imageCount(in: turns, outgoing: outgoing) + inFlight
        guard count > imageCap else { imageTrim = nil; return nil }
        // Issue #2: the refusal is also the decision point for the way out.
        // If the over-cap images live in persisted messages the client can
        // rewrite, offer the trim; the send stays blocked until it happens.
        imageTrim = Self.imageTrimOffer(
            in: turns, projected: count, cap: imageCap)
        let subject = outgoing.contains(where: \.isImage) || inFlight > 0
            ? "This message would send \(count) images"
            : "This chat already contains \(count) images"
        return "\(subject) — the model can see at most \(imageCap) per request. Start a new chat to keep using images."
    }

    // MARK: - image trim (issue #2)

    /// The text that replaces a removed image, in the stored message and in
    /// the local transcript.
    public static let imageTrimPlaceholder = "[image removed — over model image budget]"

    /// The projection the cap is compared against: persisted images plus what
    /// the pending send adds, including uploads still on the wire.
    private func projectedImageCount(outgoing: [PendingAttachment]) -> Int {
        Self.imageCount(in: turns, outgoing: outgoing) + uploadsInFlightImages
    }

    /// The trim offer for an over-cap projection: walk the branch oldest-first
    /// and take whole messages until the excess is covered. Whole messages,
    /// not individual images, because the trim rewrites a message wholesale
    /// (the server overwrites the row) — a message is either trimmed or it is
    /// not. Nil when nothing can be trimmed (e.g. a fresh chat whose excess
    /// is entirely the attachments of the message being sent).
    static func imageTrimOffer(in turns: [Turn], projected: Int, cap: Int) -> ImageTrimOffer? {
        var excess = projected - cap
        guard excess > 0 else { return nil }
        var targets: [ImageTrimOffer.Target] = []
        for turn in turns {
            let images = imageCount(in: turn)
            guard images > 0 else { continue }
            targets.append(ImageTrimOffer.Target(
                messageID: turn.id, dropCount: images, preview: trimPreview(for: turn)))
            excess -= images
            if excess <= 0 { break }
        }
        guard !targets.isEmpty else { return nil }
        return ImageTrimOffer(
            imagesInChat: projected,
            cap: cap,
            dropTotal: targets.reduce(0) { $0 + $1.dropCount },
            targets: targets)
    }

    /// One line describing a message for the confirmation dialog: its first
    /// line of text (or a label when it is image-only) and its date.
    static func trimPreview(for turn: Turn) -> String {
        let firstLine = (turn.text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "").trimmingCharacters(in: .whitespaces)
        let label = firstLine.isEmpty
            ? "image-only message"
            : (firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine)
        return "\(label) · \(turn.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Replace the oldest persisted images with placeholders until the
    /// projection fits, so an image-heavy chat keeps working instead of
    /// dead-ending (issue #2). Nothing is re-sent afterwards: the user presses
    /// send again once the banner clears.
    ///
    /// Each update is independently consistent server-side, so a failure
    /// mid-trim leaves the completed trims applied, surfaces the error, and
    /// recomputes the offer against what is left. There is no undo — these are
    /// server mutations — which is why the UI gates this behind a confirm
    /// dialog that lists exactly what will be replaced.
    public func trimOldestImagesToFit() async {
        guard let chatID, !phase.isBusy, !isTrimming else { return }
        isTrimming = true
        defer { isTrimming = false }
        error = nil
        // Recomputed against the current state rather than trusting the
        // stored offer, which may predate the user opening the dialog.
        let confirmed = imageTrim
        var offer = Self.imageTrimOffer(
            in: turns, projected: projectedImageCount(outgoing: attachments), cap: imageCap)
        // Confirm-gate fidelity: the user confirmed `confirmed`. If the state
        // got worse while the dialog was open — the recomputed trim would
        // drop MORE images than were confirmed — touch nothing: refresh the
        // offer so the user sees the bigger number and confirms again.
        // Trimming fewer than confirmed is honest (the trim stops as soon as
        // it fits); trimming more is an unconfirmed, irreversible mutation.
        if let confirmed, let offer, offer.dropTotal > confirmed.dropTotal {
            imageTrim = offer
            return
        }
        imageTrim = offer
        guard let targets = offer?.targets else { return }
        for target in targets {
            // Re-check before every message: the point is to stop as soon as
            // the projection fits, not to trim the whole target list blindly.
            guard projectedImageCount(outgoing: attachments) > imageCap else { break }
            do {
                try await trimImages(messageID: target.messageID, chatID: chatID)
            } catch {
                self.error = "Could not remove the oldest images: \(error.localizedDescription)"
                offer = Self.imageTrimOffer(
                    in: turns, projected: projectedImageCount(outgoing: attachments), cap: imageCap)
                imageTrim = offer
                return
            }
        }
        imageTrim = Self.imageTrimOffer(
            in: turns, projected: projectedImageCount(outgoing: attachments), cap: imageCap)
    }

    /// Test seam: drop the cached chat detail, so trim paths see the
    /// "session-local message the refetch never covered" shape — kept files
    /// must then be rebuilt from the turn's attachment chips.
    func debugClearDetailForTrimTest() { detail = nil }

    /// Rewrite one persisted message without its images: the text parts kept,
    /// the images dropped, a placeholder added, and `files` narrowed to the
    /// message's non-image entries — the server
    /// overwrites the row with exactly what the body says, so omitting
    /// `files` is the silent-delete trap, and sending `[]` would destroy a
    /// PDF riding along with the images. A message whose files are all
    /// images still sends the explicit empty array: that is the honest "no
    /// files". The local transcript and the cached detail are updated to match.
    ///
    /// Content is always sent as a plain string: the message-upsert endpoint
    /// rejects block arrays (`Input should be a valid string`, verified live —
    /// a 422 on every write). Block content therefore collapses to its text
    /// parts joined the way a refetch renders them; non-text, non-image blocks
    /// cannot survive that and are dropped with the images.
    private func trimImages(messageID: String, chatID: String) async throws {
        let placeholder = Self.imageTrimPlaceholder
        let stored = detail?.messages[messageID]
        let turnIndex = turns.firstIndex(where: { $0.id == messageID })
        let newContent: MessageContent
        // The separator the local text needs to match a future refetch: block
        // content renders as its text parts joined with "\n"
        // (`MessageContent.text`), while text content is stored verbatim, so
        // the "\n\n" written below is exactly what a refetch will show.
        let textSeparator: String
        switch stored?.content {
        case let .blocks(blocks)?:
            let text = blocks.compactMap { $0.objectValue?["text"]?.stringValue }
                .joined(separator: "\n")
            newContent = .text(text.isEmpty ? placeholder : text + "\n" + placeholder)
            textSeparator = "\n"
        case let .text(value)?:
            newContent = .text(value.isEmpty ? placeholder : value + "\n\n" + placeholder)
            textSeparator = "\n\n"
        case nil:
            // No cached detail for this message (a turn from this session that
            // the last refetch never saw): fall back to its rendered text.
            let text = turnIndex.map { turns[$0].text } ?? ""
            newContent = .text(text.isEmpty ? placeholder : text + "\n\n" + placeholder)
            textSeparator = "\n\n"
        }
        // Stored detail is the truth for file entries; when this session's
        // message was never in the last refetch, rebuild the non-image ones
        // from the local turn (byte-for-byte the regenerate/edit resend
        // shape) instead of silently clearing the row's files.
        let keptFiles = stored.map { Self.nonImageFileEntries($0.files) }
            ?? Self.resentFilePayload(turnIndex.map { turns[$0].attachments } ?? [])
        try await client.updateMessage(
            chatID: chatID, messageID: messageID, content: newContent, files: keptFiles)
        if var stored {
            stored.content = newContent
            stored.files = keptFiles
            detail?.messages[messageID] = stored
        }
        if let turnIndex {
            var turn = turns[turnIndex]
            let text = turn.text
            turn.text = text.isEmpty ? placeholder : text + textSeparator + placeholder
            turn.attachments.removeAll { $0.isImage }
            turn.contentImageURLs = []
            turns[turnIndex] = turn
        }
    }

    /// The stored file entries that survive a trim: everything except the
    /// entries `ChatMessage.fileEntryIsImage` calls an image. An entry with
    /// no id cannot be classified (the transcript drops it too) and is kept:
    /// keeping can only over-count the image budget, which the guard handles,
    /// while deleting is irreversible.
    static func nonImageFileEntries(_ files: [JSONValue]?) -> [JSONValue] {
        (files ?? []).filter { value in
            let inner = value["file"] ?? value
            let id = (inner["id"] ?? value["id"])?.stringValue
            guard let id, !id.isEmpty else { return true }
            return !ChatMessage.fileEntryIsImage(value)
        }
    }

    /// A chat that is never saved.
    ///
    /// Open WebUI's contract, read out of its own frontend bundle: a chat id of
    /// `temporary:<socket sid>` is temporary, `local:` is the legacy spelling of
    /// the same thing, and anything else is a saved chat. The server checks
    /// `is_saved_chat_id` before writing a message, so nothing is persisted —
    /// and it resolves the embedded sid back to the socket to decide who owns
    /// the chat, which is why the id has to carry *this* socket's id and not a
    /// made-up one.
    public var incognito = false

    /// Whether incognito can still be switched. Once anything is on the wire the
    /// answer is already decided: a saved chat has messages the server kept, and
    /// a temporary one has nothing to switch back to.
    public var canChangeIncognito: Bool { Self.canChangeIncognito(given: turns) }

    static func canChangeIncognito(given turns: [Turn]) -> Bool {
        turns.allSatisfy { turn in
            turn.text.isEmpty && turn.role != "user" && turn.calls.isEmpty
        }
    }

    /// Test seam for the incognito chat id. `ensureChat` builds it from the
    /// live socket's session id, which a scripted test has none of; setting
    /// this lets an incognito send reach the fork the way a real one does —
    /// with a `temporary:` id in `chatID`.
    var incognitoSessionIDOverride: String?

    /// The chat id a temporary run uses, or nil until the socket has one.
    private var temporaryChatID: String? {
        (incognitoSessionIDOverride ?? hub.sessionID).map { "temporary:\($0)" }
    }

    /// The Live Activity ribbon. Defaults to the process singleton — one
    /// ribbon app-wide — but is injectable so tests can drive two models that
    /// share one ribbon without racing every other test's use of `.shared`.
    private let activity: GenerationActivity
    /// The in-flight (or finished) ribbon raise of the current run, so a
    /// mid-run `claim` can order itself after `start` (issue #20).
    private var ribbonRaise: Task<Void, Never>?

    // MARK: - the send-while-generating queue (issue #37)

    /// The queue for *this* chat, shared by every model instance that shows it.
    ///
    /// Read-only here in the sense that nothing but this model writes to it; the
    /// view reads it to draw the strip. It is a `var` only because a brand-new
    /// chat's queue is re-keyed onto the id the server chooses (`rekeyQueue`).
    public private(set) var queue: ChatMessageQueue
    private let queues: MessageQueueStore
    /// The key a chat that does not exist yet queues under, and the key it is
    /// moved off when the server names it.
    private let freshQueueKey: String
    private var queueKey: String

    /// Test seam, mirroring `maxImagesPerRequestOverride`: the toggle is read
    /// live (not snapshotted at init) so flipping it in Settings takes effect
    /// in the chat you are looking at, and so a test can pin either behaviour
    /// without touching the shared defaults store.
    var queueWhileGeneratingOverride: Bool?

    /// Read at the fork, not captured: the setting is meant to be live.
    ///
    /// Public because the composer's send/stop button needs the same answer:
    /// while a run is in flight it offers a queue-send only if queueing is
    /// actually on, and falls back to Stop when it is not (issue #37).
    public var queueEnabled: Bool {
        queueWhileGeneratingOverride ?? SettingsStore.shared.defaults.queueWhileGenerating
    }

    /// A queued message the user pressed "send now" on: it goes out alone, as
    /// soon as the run it interrupted has actually stopped.
    private var steerPending: (text: String, files: [PendingAttachment])?

    /// The queued item an in-flight upload belongs to, when the user picked a
    /// file for a message that is already queued. Resolved again when the
    /// upload answers, because by then the item may have been edited away.
    private var uploadLandingTarget: ChatMessageQueue.Item?

    /// Whether the run that is currently ours came out of the queue.
    ///
    /// `stop()` needs it because the two paths put an interrupted message back
    /// in different places: a composer send goes back to the draft, a queued
    /// one goes back to the queue. Restoring a queued message into the draft
    /// would drop everything still waiting behind it.
    private var lastRunWasQueued = false
    /// What the queued run was carrying, for that put-back.
    private var lastQueuedRun: (text: String, files: [PendingAttachment])?

    /// Files picked while a run is in flight, on the wire.
    ///
    /// Deliberately not the composer's `uploadsInFlight`/`uploading`: a queued
    /// message's upload and a composer send must not hold each other up, and
    /// `uploading` means "the composer is waiting" to both `canSend` and `send`.
    /// Counting a queue upload there would either lock the composer behind a
    /// file that is already somebody's message, or let a composer send wait on
    /// it in `waitForUploads` and abort on its failure.
    private var queueUploadsInFlight = 0

    /// The give-up timer for a queue upload that never answers.
    ///
    /// An item waiting on its file holds the queue — that is the point — but a
    /// transport that ignores its own timeout must not hold it forever. The
    /// composer send has `uploadWaitLimit` for exactly this; the queue gets the
    /// same bound, armed when a drain actually finds itself waiting.
    private var queueUploadDeadline: Task<Void, Never>?

    // MARK: - the offline outbox (issue #38)

    /// Where a send that could not reach the server is kept until it can.
    ///
    /// Nil means "this model has no outbox", which is the whole behaviour of
    /// every model built before issue #38 and every model built without one:
    /// a failed send takes the issue #9 rollback. The view injects the
    /// session's store; tests inject one to exercise the other half.
    private let outbox: OutboxStore?

    /// Test seam, mirroring `queueWhileGeneratingOverride`: read live, so the
    /// setting applies to the chat you are looking at, and a test can pin
    /// either behaviour without touching the shared defaults store.
    var outboxOverride: Bool?

    /// Read at the fork, not captured: the setting is meant to be live.
    private var outboxEnabled: Bool {
        guard outbox != nil else { return false }
        return outboxOverride ?? SettingsStore.shared.defaults.outboxWhileOffline
    }

    /// How many times a replay may fail for a reason the server actually gave
    /// before the message is handed back to the composer.
    ///
    /// Three is "the server was asked and said no, or blinked, three times":
    /// enough that a transient 500 on a restarting box is retried past, short
    /// enough that a message the server will never accept does not sit in a
    /// strip forever. Failures while still offline are not counted at all —
    /// see `OutboxStore.revertToPending`.
    static let outboxAttemptCap = 3

    /// Whether the POST failure that armed the #9 rollback was one worth
    /// trying again — unreachable, a 5xx, a 429 — as opposed to a 401 or a
    /// 400, which the app would only fail again.
    ///
    /// Set in `recordPostError` in lockstep with `postFailureMessage` and
    /// cleared wherever that is cleared, because a flag that outlives its
    /// failure would capture the *next* run's non-transient error into the
    /// outbox and hold a message the server has already refused.
    private var postFailureIsTransient = false

    /// The outbox entry the current run is carrying, and the generation that
    /// run owns.
    ///
    /// The generation is the reason this is not just a UUID: a replay that gets
    /// superseded mid-flight must not have its marker read by the successor's
    /// fork, or a send the user typed by hand would be filed under the
    /// replay's entry and vanish into the outbox.
    ///
    /// `gen == nil` means claimed but not started — the window while the dedup
    /// refetch is in flight. It matches no run, which is exactly right: a
    /// claimed-but-unstarted entry belongs to no fork yet.
    private var outboxReplayContext: (entryID: UUID, gen: Int?, burnsAttempt: Bool)?

    /// The outbox entries waiting on this chat, oldest first — what the strip
    /// in `ConversationView` draws.
    public var pendingOutbox: [OutboxEntry] {
        guard let chatID, let outbox else { return [] }
        return outbox.entries(for: chatID)
    }

    public init(
        chatID: String?,
        title: String = "New Chat",
        models: [ChatModel] = [],
        incognito: Bool = false,
        client: OWUIClient,
        hub: ChatEventHub,
        activity: GenerationActivity = .shared,
        prefs: RunPreferences = RunPreferences(),
        queues: MessageQueueStore = MessageQueueStore(),
        outbox: OutboxStore? = nil
    ) {
        self.incognito = incognito
        // A chat the server has not named yet cannot own a queue by id, so it
        // gets a stand-in key of its own — not a shared "new chat" key, which
        // would let two half-written chats read each other's queued messages.
        let freshKey = "new:\(UUID().uuidString)"
        self.queues = queues
        self.outbox = outbox
        self.freshQueueKey = freshKey
        self.queueKey = chatID ?? freshKey
        self.queue = queues.queue(for: chatID ?? freshKey)
        self.chatID = chatID
        self.title = title
        self.client = client
        self.hub = hub
        self.activity = activity
        self.prefs = prefs
        self.models = models
        modelIDs = models.map(\.id)
        model = models.first?.id ?? ""
        features = Self.applyFeaturePrefs(
            seed: Self.seedFeatures(for: models.first, incognito: incognito),
            model: models.first, incognito: incognito, prefs: prefs)
    }

    /// The session's feature/tool intent (issue #35). Read-only here: the only
    /// ways in are `setFeature`/`setTool`, so a chat can never write an intent
    /// it did not express.
    private let prefs: RunPreferences

    /// Moves this chat's queue onto its real id once the server has chosen one.
    ///
    /// Without this, messages queued for a chat that was still unnamed would
    /// stay under a key nothing else looks at, and the chat would open empty.
    private func rekeyQueue() {
        guard let chatID, queueKey != chatID else { return }
        queues.migrate(from: queueKey, to: chatID)
        queueKey = chatID
        queue = queues.queue(for: chatID)
    }

    // MARK: - draining the queue

    /// Where the files a run is about to carry came from.
    ///
    /// The distinction is the whole reason `send`'s body is factored into
    /// `beginRun`: a composer send owns `attachments` and the upload bookkeeping
    /// around them, and a queued run owns neither. Handing a queued run the
    /// composer's files — or letting it clear them — is how a message queued
    /// five minutes ago would send the picture attached for the next one.
    enum RunFiles {
        /// The composer's own, taken after its uploads have landed.
        case composer
        /// Already-uploaded files handed over by the queue (issue #37).
        case taken([PendingAttachment])
    }

    /// Hands the queue to a chat that has just become able to take it.
    ///
    /// Called from the places a run ends cleanly, and from nowhere else: a path
    /// that gave up on a run, parked a question, rolled a send back, aborted an
    /// upload or discarded a half-made chat leaves the chat in a state where
    /// firing a new completion would be the wrong thing, and each of those is an
    /// early return that simply does not call this.
    ///
    /// Synchronous, and it has to be: the queue is emptied in the same main-actor
    /// turn it is inspected, so two triggers landing in one turn cannot both take
    /// the same messages. A `drainInFlight` flag is the alternative, and it is
    /// wrong the moment two triggers do land together.
    ///
    /// `afterStoppingQueuedRun` is the one case the guards cannot see for
    /// themselves: a stop means "not now", and the run that was just stopped may
    /// itself have been the queue's.
    private func settleQueue(afterStoppingQueuedRun: Bool = false) {
        guard queueEnabled, phase == .ready else { return }

        // "Send now" wins over the queue: the item was already taken out, and it
        // is waiting for the run it interrupted to have actually stopped —
        // `stop()` resolves the server POST before it gets here, which is the
        // only reason the server cannot be handed a new completion for a chat it
        // is still on its way to stop.
        if let steer = steerPending {
            steerPending = nil
            let item = ChatMessageQueue.Item(text: steer.text, attachments: steer.files)
            if startQueuedRun(items: [item]) { return }
            queue.putBackFront([item])
            return
        }

        guard !afterStoppingQueuedRun else { return }
        guard !queue.isEmpty else { return }
        // An item whose file has not landed — or has visibly failed — holds the
        // whole queue. The items go out as one message, and sending the text
        // without the picture is #22 wearing a new hat.
        guard !queue.hasBlockedItem else {
            // Only a file still on the wire can time out; a failed one waits for
            // the user, which is not a timeout and must not re-arm forever.
            if queue.hasItemAwaitingUpload { armQueueUploadDeadline() }
            return
        }
        queueUploadDeadline?.cancel()
        queueUploadDeadline = nil

        let items = queue.takeAll()
        if !startQueuedRun(items: items) {
            // Refused — the combined message crosses the image budget, or the
            // model selected since no longer has eyes for it. The messages go
            // straight back: the banner says why, the strip still shows them,
            // and Edit and Delete are the ways on. Dropping them because the app
            // decided they would not be accepted is the bug this guards.
            queue.putBackFront(items)
        }
    }

    /// Starts one run carrying everything `items` holds, or refuses without
    /// starting anything. Returns whether the run went out.
    private func startQueuedRun(items: [ChatMessageQueue.Item]) -> Bool {
        let text = items.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let files = items.flatMap(\.attachments)
        guard !text.isEmpty || !files.isEmpty else { return false }
        // The same two guards `send` runs at the button, against the *combined*
        // message and the model selected *now*. What was allowed when the first
        // of these was typed is not a promise about now: the model may have been
        // changed, another message may have used up the image budget, and the
        // engine's 500 is a worse way to learn that than a banner.
        if let refusal = imageLimitMessage(outgoing: files) {
            error = refusal
            return false
        }
        if !modelSupportsVision, files.contains(where: \.isImage) {
            error = "\(model) can't see images — remove the picture or pick a vision model."
            return false
        }
        beginRun(text: text, fileSource: .taken(files))
        return true
    }

    /// Puts a run that never reached the server back into the queue it came from.
    ///
    /// The queue's one promise is that it does not lose things, and a run that
    /// was stopped or failed before its POST landed has not sent anything.
    private func putBackInQueue(text: String, files: [PendingAttachment]) {
        queue.enqueue(text: text, attachments: files)
        lastQueuedRun = nil
    }

    /// The user pressed "send now" on one queued message: it interrupts the run
    /// in flight and goes out alone, while everything else keeps waiting.
    ///
    /// The steered message is not sent here. It is parked in `steerPending` and
    /// `stop()` is called, because the new completion must not reach the server
    /// before the stop for the run it interrupts does — a completion that
    /// arrives first is answered by a server that is on its way to stopping it,
    /// which is the race this ordering exists to avoid. `stop()` resolves its
    /// POST and `settleQueue` picks the message up on the other side of it.
    public func sendNow(id: UUID) {
        guard let item = queue.remove(id: id) else { return }
        guard phase != .loading else {
            queue.putBackFront([item])
            return
        }
        if phase.isBusy {
            steerPending = (item.text, item.attachments)
            stop()
            return
        }
        if !startQueuedRun(items: [item]) { queue.putBackFront([item]) }
    }

    /// Takes a queued message back out into the composer to be edited.
    ///
    /// The text is handed over rather than appended blindly: if something has
    /// been typed since, both are the user's words and neither may be eaten, so
    /// they are joined. The file goes with it, and an upload still on the wire
    /// for this item lands in the composer now that the item is gone.
    public func editQueued(id: UUID) {
        guard let item = queue.remove(id: id) else { return }
        draft = draft.isEmpty ? item.text : draft + "\n" + item.text
        attachments.append(contentsOf: item.attachments)
        // The message is out of the queue, so a drain must not be waiting on it
        // any more — and if it was the last thing waiting, this is the trigger.
        if uploadLandingTarget?.id == id { uploadLandingTarget = nil }
        settleQueue()
    }

    /// Throws a queued message away. Silent on purpose: the user chose to drop
    /// it, which is not an error and must not leave a banner behind.
    public func deleteQueued(id: UUID) {
        guard let item = queue.remove(id: id) else { return }
        if uploadLandingTarget?.id == id { uploadLandingTarget = nil }
        // A delete can be the thing that unblocks the queue: the message whose
        // file failed is often the one that was holding the rest up.
        settleQueue()
    }

    /// Gives up on a queue upload that has not answered in `uploadWaitLimit`.
    ///
    /// The upload itself is left running, exactly as `waitForUploads` leaves a
    /// hung composer upload: a late success still lands and takes the failure
    /// back. What the deadline ends is the *wait*, because the alternative is a
    /// queue held shut by a transport that never answers.
    private func armQueueUploadDeadline() {
        guard queueUploadDeadline == nil else { return }
        let limit = uploadWaitLimit
        queueUploadDeadline = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self else { return }
            self.queueUploadDeadline = nil
            guard self.queue.hasItemAwaitingUpload else { return }
            for item in self.queue.items where item.awaitingUploads {
                item.awaitingUploads = false
                item.uploadFailed = true
            }
            self.error = "Upload is taking too long — the queued message is waiting "
                + "on a file that has not arrived. Edit it to retry, or delete it."
            // Nothing to time out on the other side, so nothing to re-check:
            // re-settling here would re-arm the deadline over a failure that is
            // waiting for the user, not for the server.
        }
    }

    // MARK: - replaying the outbox (issue #38)

    /// What the outbox does with a POST that died before its first frame.
    private enum OutboxFate {
        /// A send made with no connection, parked for the first time.
        case park
        /// A replay that failed again, back to pending. `burnsAttempt` is false
        /// when the failure was "still offline" rather than an answer: the
        /// attempt cap counts times the server was asked, not times a trigger
        /// fired into a dead network.
        case repark(entryID: UUID, burnsAttempt: Bool)
        /// A replay that has run out of attempts: the entry is deleted and the
        /// message takes the issue #9 route home.
        case gaveUp(entryID: UUID)
        /// The entry this run was carrying is gone — the user cancelled it (or
        /// the chat was deleted, or the account signed out) while the replay's
        /// POST was in flight. The run belongs to no queue any more: the
        /// message is thrown away quietly, the way `cancelOutbox` throws away
        /// a pending one.
        case discarded
    }

    /// The user-message id a replay must reuse, if this run is one.
    ///
    /// This is what makes the dedup able to recognise its own retry. A replay
    /// that minted a fresh UUID would be a *different* message as far as the
    /// server is concerned, so an attempt that landed and was not seen would be
    /// sent again under a new id and the chat would carry the question twice —
    /// which is precisely the failure the dedup exists to prevent, reintroduced
    /// by the thing that was supposed to fix it.
    ///
    /// Generation-matched for the same reason the rest of the fork is: a
    /// superseded run must not stamp a successor's message with its
    /// predecessor's id.
    private func replayedUserMessageID(for gen: Int) -> String? {
        guard let context = outboxReplayContext, context.gen == gen,
              let entry = outbox?.entry(id: context.entryID)
        else { return nil }
        return entry.userMessageID
    }

    /// The outbox's claim on a failed send, or nil when the #9 rollback owns it.
    ///
    /// Decided in one place before the fork because the answer needs three
    /// things the fork does not carry together: the replay marker, the entry's
    /// attempt count, and whether this failure was the server's answer or the
    /// same dead network seen again.
    private func outboxFate(
        files: [PendingAttachment], queuedRun: Bool, gen: Int
    ) -> OutboxFate? {
        guard let outbox else { return nil }
        if let context = outboxReplayContext, context.gen == gen {
            // A replay that failed again belongs to the outbox and nowhere
            // else. This is what the marker exists for: a replay goes out
            // through `beginRun(.taken)`, which means `queuedRun` is true, and
            // without the marker its failure would land in `putBackInQueue` —
            // the in-memory queue, which loses the message on the next force
            // quit and draws a strip for a chat that is not generating.
            //
            // A gone entry means the claim was cancelled mid-flight. Routing
            // that to `nil` would drop the failure into the #9 arm, whose
            // `queuedRun` branch hands the just-cancelled message to the
            // queue — resurrecting exactly what the user threw away.
            guard let entry = outbox.entry(id: context.entryID) else { return .discarded }
            if context.burnsAttempt, entry.attempts + 1 >= Self.outboxAttemptCap {
                return .gaveUp(entryID: entry.id)
            }
            return .repark(entryID: entry.id, burnsAttempt: context.burnsAttempt)
        }
        // A fresh send. `chatID != nil` is the existing-chat gate: a brand-new
        // chat has no id to key an entry under, and its offline failure happens
        // earlier still, in `ensureChat` — a different hook and a follow-up.
        // `!incognito` is the promise gate: incognito sends get a derived
        // `temporary:<sid>` id, so the nil-check alone would let an offline
        // incognito send park its text in UserDefaults — durable storage is
        // precisely what incognito promises not to write. (The replay branch
        // above is unaffected: a replay only exists for an entry that was
        // legitimately captured.)
        // `files.isEmpty` is the text-only gate: an attachment has no file id
        // until its upload answers, and offline that never happens.
        guard outboxEnabled, !queuedRun, postFailureIsTransient,
              chatID != nil, !incognito, files.isEmpty
        else { return nil }
        return .park
    }

    /// Sends anything this chat is holding, if the chat is free to send.
    ///
    /// Idempotent and cheap, which is what lets three different moments call it
    /// — a connectivity transition, a foreground, and the chat opening — without
    /// any of them having to know about the others.
    ///
    /// The phase gate and the claim are one synchronous main-actor region on
    /// purpose. `beginRun` has no phase guard of its own — it assumes the caller
    /// checked — so a replay that claimed an entry, awaited something, and then
    /// called `beginRun` would bump the generation out from under a run the user
    /// started in the meantime and supersede it. Claiming in the same turn as
    /// the check is the mutex; `beginRun` is called after the dedup refetch
    /// only behind a re-check of the same condition.
    public func replayOutboxIfNeeded() {
        guard outboxEnabled, phase == .ready, let chat = chatID else { return }
        // A marker left by a run that has since ended or been superseded is
        // nobody's; clearing it here is what keeps an entry retryable instead
        // of wedged behind one bad interleaving. A claim that has not started a
        // run yet (nil generation) is by definition current — clearing it here
        // would undo the mutex that makes two triggers in one turn safe.
        clearStaleReplayMarker()
        guard outboxReplayContext == nil else { return }
        guard let entry = outbox?.claimNext(for: chat) else { return }
        beginClaim(entry)
    }

    /// Drops a replay marker whose run has since ended or been superseded,
    /// and lets the store's in-process claim go with it.
    ///
    /// Shared by `replayOutboxIfNeeded` and `sendOutboxNow`: both refuse to
    /// start over a marker, so both owe the caller the same cleanup — a
    /// trigger (or a "Send now") that refused against a stale marker and
    /// left it in place is a dead button until some later cue happens to
    /// fire. A claim that has not started a run yet (nil generation) is by
    /// definition current and is left alone.
    private func clearStaleReplayMarker() {
        if let context = outboxReplayContext, let gen = context.gen,
           gen != runGeneration {
            outboxReplayContext = nil
            // The run that owned the claim is gone, so the claim is nobody's —
            // and the store's in-process claim set must let go too, or the
            // entry is wedged out of `claimNext` for the rest of the process.
            outbox?.revertToPending(id: context.entryID, burnsAttempt: false)
        }
    }

    /// "Send now" on the pending strip: the user is asserting the network is
    /// back, which is exactly the information the monitor may not have yet.
    ///
    /// Deliberately *not* gated on `outboxEnabled`: the press is the override
    /// case the flag is an opinion about. With the toggle off and entries
    /// already on disk, the strip still shows them (they are real), and a
    /// "Send now" that silently did nothing would make the strip a liar and
    /// the button a dead end. Capture, by contrast, stays gated — the flag
    /// still refuses to take on *new* entries.
    public func sendOutboxNow(id: UUID) {
        // Same refusal-and-cleanup contract as the automatic trigger: a stale
        // marker must not dead-button the user's explicit "send it now".
        clearStaleReplayMarker()
        // Self-defending against a cross-chat id: the strip only ever passes an
        // id from this chat's `pendingOutbox`, but `sendOutboxNow` is public, and
        // replaying another chat's text into the open chat would be a wrong send
        // the type system can't catch. Peek before claiming so a foreign id never
        // becomes a claim.
        guard phase == .ready, outboxReplayContext == nil,
              outbox?.entry(id: id)?.chatID == chatID,
              let entry = outbox?.claim(id: id)
        else { return }
        beginClaim(entry)
    }

    /// Throws a pending message away. The user has decided it does not matter,
    /// which is not an error and must not leave a banner behind — the same
    /// contract `deleteQueued` keeps.
    public func cancelOutbox(id: UUID) {
        // A claim that has not started a run yet (nil generation) belongs to no
        // fork, so clearing the marker here is what keeps a cancelled claim
        // from wedging the next trigger. A claim that *owns a live run* must
        // keep its marker: the run's fork needs it to recognise itself when its
        // POST fails, and a marker dropped here would send a cancelled
        // replay's failure into the #9 arm, which hands the just-cancelled
        // message back to the queue — resurrecting what the user deleted.
        if outboxReplayContext?.entryID == id, outboxReplayContext?.gen == nil {
            outboxReplayContext = nil
        }
        outbox?.remove(id: id)
    }

    private func beginClaim(_ entry: OutboxEntry) {
        // Claimed but not started: a generation of nil matches no run, so no
        // fork can read it, and a second trigger landing in this same turn sees
        // a claim and stands down instead of taking the entry too.
        outboxReplayContext = (entry.id, nil, true)
        Task { await replay(entry) }
    }

    /// Replays one claimed entry: check it has not already landed, then send it.
    ///
    /// The check is the reason a replay may be a retry at all. A message can be
    /// in the server's transcript and unknown to the app — the answer arrived
    /// and the app was killed, or the POST landed and the socket died before any
    /// frame came back. Sending it again would put the same question to the
    /// model twice, and the model would answer twice, and both answers would be
    /// in the chat forever.
    private func replay(_ entry: OutboxEntry) async {
        // Whether a failure of this attempt should count against the cap, set
        // below by whether the refetch reached the server at all.
        var burnsAttempt = true
        // The generation at claim time. The dedup guard below needs more than
        // `phase == .ready`: a run can start *and finish* inside the refetch
        // window (slow GET, fast answer), leaving the phase back at `.ready`
        // while the transcript the refetch returns is a snapshot from before
        // that run — applying it would rewind the leaf and drop the exchange
        // that just completed, the #19/#26 class wearing a `.ready` mask.
        // Generation can only move forward, so equality is the whole check.
        let startGen = runGeneration
        do {
            let detail = try await client.chat(id: entry.chatID)
            if detail.messages[entry.userMessageID] != nil {
                // The server already has this exact message — the id is the
                // app's own UUID, so "a message with this id" is "this send",
                // not a message that happens to read the same. It landed; only
                // the answer was lost. Show the transcript and send nothing.
                //
                // But the refetch was a real await: a run may have started
                // under it, and `apply` replaces the transcript, rewinds the
                // leaf and can swap the model — superseding a live run is the
                // #19/#26 class of bug, and the same rule as the guard below
                // applies before the apply, not just before a `beginRun`. An
                // entry that was cancelled while the refetch was in flight is
                // gone too: there is nothing left to dedup or replay.
                guard phase == .ready, runGeneration == startGen,
                      outbox?.entry(id: entry.id) != nil else {
                    outbox?.revertToPending(id: entry.id, burnsAttempt: false)
                    clearReplayMarker(ifFor: entry.id)
                    return
                }
                outbox?.remove(id: entry.id)
                clearReplayMarker(ifFor: entry.id)
                apply(detail)
                // And take the next one now: an entry that deduped was never
                // really the attempt, and making the message behind it wait
                // for another reconnect cue is a message that sits there for
                // no reason. Bounded, because every pass removes an entry.
                replayOutboxIfNeeded()
                return
            }
        } catch {
            // Still offline, most likely. Proceed: the send fails the way it
            // failed before and re-parks — but a failure to reach the server
            // for the *check* is not the server refusing the *message*, so it
            // does not spend an attempt. Without this, three foregrounds on a
            // long flight would empty the outbox into the composer.
            burnsAttempt = false
        }
        // The refetch was a real await: a run may have started while it was in
        // flight, and superseding it is not this code's to do. And the entry
        // may have been cancelled while it was: a cancelled message must not
        // come back to life as a run behind the refetch that was checking it.
        // `phase == .ready` alone is enough here, unlike the dedup guard: a
        // free chat means `beginRun` supersedes nothing, whatever the
        // generation has meanwhile done.
        guard phase == .ready, outbox?.entry(id: entry.id) != nil else {
            outbox?.revertToPending(id: entry.id, burnsAttempt: false)
            clearReplayMarker(ifFor: entry.id)
            return
        }
        beginRun(text: entry.text, fileSource: .taken([]))
        // Stamped after `beginRun` because that is where the generation is
        // bumped, and `beginRun`'s own task cannot start before this
        // synchronous region ends — so no fork can observe the gap.
        outboxReplayContext = (entry.id, runGeneration, burnsAttempt)
    }

    /// Clears the replay marker only if it still names this entry.
    ///
    /// The marker is a single slot and a bail-out here is a verdict about
    /// *this* entry, not about whoever holds the slot by the time the await
    /// resolves: claim A, cancel A, a trigger claims B, and A's replay
    /// resuming would otherwise nil *B's* claim — B's fork then cannot
    /// recognise itself and its failure lands in the #9 queue put-back with
    /// a duplicate of a message the durable store is still holding.
    private func clearReplayMarker(ifFor entryID: UUID) {
        if outboxReplayContext?.entryID == entryID { outboxReplayContext = nil }
    }

    /// The toggles a model starts a chat with.
    ///
    /// The server's own defaults first, so a model configured for web search
    /// starts with it on. Then two we force on deliberately:
    ///
    /// * **memory**, which the server leaves off unless enabled globally — and a
    ///   chat that quietly forgets what you told it is a worse surprise than one
    ///   that remembers too much.
    /// * **code interpreter**, because it is what the terminal sandbox is. Off,
    ///   the model cannot write a file, run a command, or hand you a PDF, and the
    ///   web UI has it on by default — so the app would be missing a whole class
    ///   of answer for no reason the user chose.
    ///
    /// Both are only offered where the model reports the capability, because a
    /// toggle that does nothing is worse than no toggle.
    static func seedFeatures(for model: ChatModel?, incognito: Bool = false) -> [String: Bool] {
        guard let model else { return [:] }
        var seeded = Dictionary(
            uniqueKeysWithValues: model.defaultFeatureIDs.map { ($0, true) })
        // Incognito has to mean something. Remembering what the user just said
        // in a chat that is supposed to vanish is the opposite of the request.
        if model.supports(.memory) && !incognito { seeded[ChatFeature.memory.rawValue] = true }
        if model.supports(.codeInterpreter) { seeded[ChatFeature.codeInterpreter.rawValue] = true }
        // Web search joins memory rather than staying off until asked. There is
        // nothing on the server to inherit: `default_feature_ids` is null for
        // every model here, and `/users/user/settings` carries only `ui` — the
        // browser's "on for new chats" is localStorage, which no client can
        // read. So the capability is the only honest signal, and a model that
        // advertises search should offer it switched on rather than three taps
        // deep in a sheet. Incognito gets the same treatment as memory: a chat
        // that is meant to leave no trace should not be phoning a search engine.
        if model.supports(.webSearch) && !incognito {
            seeded[ChatFeature.webSearch.rawValue] = true
        }
        return seeded
    }

    /// Overlay the session's feature intent on a per-chat seed (issue #35).
    ///
    /// Applied wherever a seed is produced — init and the `setModels` fill —
    /// so a chat opened after the user toggled something in another chat
    /// starts with that choice. Two asymmetries, both about the send path
    /// shipping `features` wholesale to the server:
    ///
    /// * A pref-**false** only turns off a key the seed already contains.
    ///   Turning off a seeded default is the user's own intent; introducing
    ///   a `false` for a key the model never had leaks an unknown key onto
    ///   the wire.
    /// * A pref-**true** only lands where the model reports the capability
    ///   (`supports(_:)`'s empty-capabilities-means-supports rule included),
    ///   and never for the incognito exclusions `seedFeatures` makes —
    ///   memory and web search stay out of a chat that is meant to vanish.
    ///   An unsupported key stays absent, not false.
    static func applyFeaturePrefs(
        seed: [String: Bool],
        model: ChatModel?,
        incognito: Bool,
        prefs: RunPreferences
    ) -> [String: Bool] {
        guard !prefs.features.isEmpty else { return seed }
        var seeded = seed
        for (key, value) in prefs.features {
            if !value {
                if seeded[key] != nil { seeded[key] = false }
                continue
            }
            guard let feature = ChatFeature(rawValue: key),
                  let model, model.supports(feature) else { continue }
            if incognito, feature == .memory || feature == .webSearch { continue }
            seeded[key] = true
        }
        return seeded
    }

    public var canSend: Bool {
        // A photo with no caption is a message. Requiring text made the send
        // button sit there disabled after a picture was attached, which read as
        // the upload having failed.
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Uploading counts as content for the same reason send() waits for it:
        // the picture is coming, and greying the button out until it lands is
        // honest in a way that sending without it is not.
        // `.loading` too: until the branch is on screen the image budget can
        // only see this message, so a send now could cross the cap unseen.
        return (hasText || !attachments.isEmpty || uploading) && !phase.isBusy && phase != .loading
    }

    public func setModels(_ models: [ChatModel]) {
        self.models = models
        modelIDs = models.map(\.id)
        if model.isEmpty { model = models.first?.id ?? "" }
        // A chat can open before the model list arrives, which leaves the
        // toggles unseeded. Fill them in, but never over a choice the user has
        // already made in this chat.
        if features.isEmpty {
            features = Self.applyFeaturePrefs(
                seed: Self.seedFeatures(for: models.first, incognito: incognito),
                model: models.first, incognito: incognito, prefs: prefs)
        }
    }

    /// Record a feature toggle as both this chat's state and the session's
    /// intent, so the next chat opened starts with the same choice (issue #35).
    public func setFeature(_ key: String, on: Bool) {
        features[key] = on
        // #35: the read side refuses to let session intent re-enable
        // memory/web_search in an incognito chat; the write side must not
        // smuggle that intent into the session either, or toggling it inside
        // an incognito chat would leak it to every later normal chat.
        let incognitoExcluded = incognito
            && (key == ChatFeature.memory.rawValue || key == ChatFeature.webSearch.rawValue)
        if !incognitoExcluded {
            prefs.features[key] = on
        }
    }

    /// Record a tool toggle as both this chat's state and the session's
    /// intent, so the next chat opened seeds the same set (issue #35).
    public func setTool(_ id: String, on: Bool) {
        if on {
            if !tools.contains(id) { tools.append(id) }
        } else {
            tools.removeAll { $0 == id }
        }
        prefs.tools[id] = on
    }

    /// Seed this chat's tool ids from the workspace defaults, overlaid with
    /// the session's tool intent (issue #35).
    ///
    /// Same once-only semantics as the old view-side seed: only while nothing
    /// is selected, so switching everything off stays switched off. Pref-false
    /// ids are subtracted from the defaults; a pref-true id is added only if
    /// it is in `available`, actually available, and needs no sign-in — an
    /// unauthenticated MCP server cannot serve anything, and selecting it by
    /// default would put a broken tool in every request.
    public func seedTools(
        defaultIDs: [String],
        available: [(id: String, available: Bool, needsAuth: Bool)] = []
    ) {
        guard tools.isEmpty else { return }
        var seeded = defaultIDs
        seeded.removeAll { prefs.tools[$0] == false }
        // Iterate `available`, not `prefs.tools`: dictionary order is unstable,
        // and the appended ids land in `tool_ids` on the wire — the order must
        // be a function of the tool list, not of a hash.
        for tool in available where prefs.tools[tool.id] == true {
            guard tool.available, !tool.needsAuth, !seeded.contains(tool.id) else { continue }
            seeded.append(tool.id)
        }
        tools = seeded
    }

    /// Called when the model changes: the defaults belong to the model, so the
    /// toggles have to follow it rather than keep the previous model's settings.
    ///
    /// Deliberately does NOT apply the session prefs (issue #35, pinned): a
    /// model change means "give me this model's defaults", and the seed
    /// already respects the model's capabilities. The session intent is
    /// re-applied when the next chat opens, not on a mid-chat model switch.
    public func select(model id: String, from models: [ChatModel]) {
        model = id
        features = Self.seedFeatures(for: models.first { $0.id == id }, incognito: incognito)
    }

    /// Connects the shared socket. Failures are not fatal: the REST calls still
    /// work, and a chat that cannot stream is better than a screen that refuses
    /// to open — so this records the problem and lets the run fail on its own.
    public func connect() async {
        do { try await hub.connect() }
        catch let problem { error = "Live streaming is unavailable: \(problem.localizedDescription)" }
    }

    /// Coming back to the foreground with a run still marked as streaming.
    ///
    /// iOS kills the socket in the background and the server keeps writing, so
    /// the answer is already finished by the time you look again — but the run is
    /// sitting on a frame stream that will never see them. If the reconnect does
    /// not come back, end the stream so the run reconciles against the server
    /// record now instead of after the silence watchdog.
    public func resumeAfterBackground() {
        hub.reconnectIfNeeded()
        guard phase == .streaming, let chat = chatID else { return }
        Task { [weak self] in
            try? await Task.sleep(for: ChatEventHub.reconnectGrace)
            guard let self, self.phase == .streaming, !self.hub.isConnected else { return }
            self.hub.expire(chatID: chat)
        }
    }

    // MARK: - loading

    /// Reads the chat, then gives the queue its turn.
    ///
    /// Opening a chat is a safe moment to drain, and the one that catches a
    /// message queued while no model was looking at the chat — the queue lives on
    /// the session, so a message queued before navigating away is still sitting
    /// there when the chat is opened again.
    ///
    /// The outbox gets the same moment for the same reason (issue #38): a
    /// message that failed to leave while this chat was closed has nowhere else
    /// to be noticed, and a chat that has just been opened is a chat somebody
    /// is looking at while it sends.
    public func load() async {
        await loadInner()
        settleQueue()
        replayOutboxIfNeeded()
    }

    private func loadInner() async {
        guard let chatID else { return }
        // A temporary chat has no history to fetch — that is the whole point —
        // and asking for one is a guaranteed 404 on an id the server never
        // stored, which would put a red error banner on a perfectly good chat.
        if incognito || chatID.hasPrefix("temporary:") || chatID.hasPrefix("local:") {
            // #26: same ownership rule #19 established for the plain paths —
            // a mid-run load of a temporary/local/incognito chat must not
            // hand the composer back while a run is live. The early return
            // used to stamp `.ready` unconditionally, unlocking the composer
            // and disarming reconcile's phase guard for exactly the bug
            // class #19 closed one branch over. The lost accidental self-heal
            // (an unconditional `.ready` settling a stuck-busy temporary
            // chat) has no reachable case: `.stopping` always resolves via
            // finishLocally, `.streaming` via the silence watchdog.
            if !phase.isBusy { phase = .ready }
            return
        }
        let cacheKey = DiskCache.key("chat-\(chatID)",
                                     host: client.server.baseURL.host ?? "local")
        // A run in flight owns the phase (issue #19). A pull-to-refresh during
        // a live run used to drop the phase to .loading/.ready whatever the run
        // was doing: the composer unlocked mid-answer, and — because
        // `reconcileUntilClosed` refuses to watch a run nobody considers live —
        // the reload also disarmed the very loop that is supposed to converge
        // the transcript on the server. The run settles the phase when it ends;
        // a refresh is not an end. Ownership covers the heal below too: the
        // live run is already watching its own message, so a mid-run load must
        // neither restamp the phase nor start a second watcher on it.
        let runInFlight = phase.isBusy
        // Cached first. Opening a chat used to be a blank screen for the length
        // of a round trip, which is the single thing that most makes the app feel
        // slow — the transcript is already on the phone from the last time you
        // read it. The network then replaces it, and a failure leaves the cached
        // transcript on screen instead of trading it for an error banner.
        if let cached = DiskCache.load(ChatDetail.self, key: cacheKey) {
            apply(cached)
            if !runInFlight { phase = .ready }
        } else if !runInFlight {
            phase = .loading
        }
        do {
            let detail = try await client.chat(id: chatID)
            apply(detail)
            DiskCache.save(detail, key: cacheKey)
            // Opening a chat is reading it. The server tracks unread as
            // `updated_at > last_read_at` and only moves `last_read_at` over the
            // socket, so without this every conversation had on the phone walked
            // into the browser still flagged as having an unread reply.
            hub.markChatRead(chatID)
            // Heal a run the app gave up on. If the newest message is an answer
            // the server still has open, the run is either still writing or parked
            // on a question — either way the transcript on screen is incomplete,
            // and opening the chat is exactly the moment to find that out.
            //
            // This is the part that makes the fix durable: however a run got
            // mis-ended — dead socket, misread frame, app killed mid-answer —
            // re-entering the chat now converges on what the server has.
            //
            // Only when no run is live (issue #19 review): a mid-run load whose
            // reloaded tree happens to end on the run's own open assistant
            // used to stamp `.streaming` over `.waiting`/`.stopping` and spawn
            // a SECOND `reconcileUntilClosed` on the message the live run is
            // already watching — two loops, double GETs, one record. The live
            // run is watching that message; there is nothing to heal.
            if !runInFlight, let last = turns.last, !last.isUser,
               let stored = detail.messages[last.id], stored.done != true {
                phase = .streaming
                Task {
                    await self.reconcileUntilClosed(messageID: last.id)
                    // Only hand the composer back if nothing else took it while
                    // we were watching — a send started mid-heal owns the phase.
                    if case .streaming = phase, post == nil {
                        phase = .ready
                        // Issue #37: the heal is a run ending — the answer the
                        // app had given up on is finished, and the chat is free.
                        settleQueue()
                    }
                }
            } else if !runInFlight {
                phase = .ready
            }
        } catch {
            // Only worth complaining about when there is nothing to show. With a
            // cached transcript on screen, a dead network should keep the screen
            // as it is, not replace readable messages with a red banner.
            if detail == nil { self.error = error.localizedDescription }
            if !runInFlight { phase = .ready }
        }
    }

    /// Put a fetched — or cached — record onto the screen.
    private func apply(_ detail: ChatDetail) {
        self.detail = detail
        title = detail.title
        turns = detail.thread.map(Turn.init)
        leafID = turns.last?.id
        chatVariables = detail.variables
        if let used = detail.models.first, !used.isEmpty { model = used }
    }

    // MARK: - sending

    /// A file chosen in the composer and uploaded, waiting to be sent with the
    /// next message.
    public struct PendingAttachment: Identifiable, Equatable, Sendable {
        /// The server's file id — what the completion's `files` list carries.
        public let id: String
        public let name: String
        public let mimeType: String
        /// The bytes, kept until the message is sent.
        ///
        /// The file id alone is not enough: `files` is what the retrieval
        /// pipeline and the transcript see, and a vision model gets its picture
        /// from the message content. Sending the id and nothing else is why a
        /// photo looked attached, sent cleanly, and then never arrived.
        public let data: Data
        public var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    public private(set) var attachments: [PendingAttachment] = []
    public private(set) var uploading = false

    /// Uploads a file so it can be attached to the next message.
    ///
    /// Upload happens when the file is picked, not when the message is sent: the
    /// server processes documents in the background after upload, so starting
    /// early is the difference between an instant send and a spinner after the
    /// user has already pressed go.
    public func attach(data: Data, name: String, mimeType: String) {
        guard !name.isEmpty else { return }
        // A camera or photoPicker callback can land while a run is in flight —
        // the picker was opened before the send, the answer arrived in the
        // meantime. Attaching into a busy chat used to sweep the late pick into
        // whatever message sent next, which is a picture filed under the wrong
        // question. Refuse it where it lands, and say so.
        //
        // Issue #37 changed what "where it lands" is: with the queue on, the
        // pick belongs to the message the user is queueing, and there is
        // nothing wrong to report. Without the queue the refusal stands.
        if phase.isBusy {
            guard queueEnabled else {
                error = "Wait for the current answer to finish before adding attachments."
                return
            }
            attachForQueue(data: data, name: name, mimeType: mimeType)
            return
        }
        uploading = true
        error = nil
        uploadsInFlight += 1
        // Counted as an image straight away, from the mime type the picker
        // already handed over: `attachments` only gains its entry when the
        // upload answers, so a batch of photos picked a second ago would be
        // invisible to the image budget for the length of the upload.
        let countsAsImage = mimeType.hasPrefix("image/")
        if countsAsImage { uploadsInFlightImages += 1 }
        pendingUploads.append(Task {
            defer {
                if countsAsImage { uploadsInFlightImages -= 1 }
                uploadsInFlight -= 1
                uploading = uploadsInFlight > 0
            }
            do {
                let file = try await client.uploadFile(data: data, filename: name, mimeType: mimeType)
                attachments.append(
                    PendingAttachment(id: file.id, name: file.filename, mimeType: mimeType, data: data))
            } catch {
                uploadFailureCount += 1
                self.error = "Could not attach \(name): \(error.localizedDescription)"
            }
        })
    }

    /// Uploads a file picked while a run is in flight, for the message the user
    /// is queueing rather than for the composer (issue #37).
    ///
    /// Three things this keeps apart:
    ///
    /// * *whose* file it is — the most recently queued message, or the composer
    ///   if nothing is queued yet, in which case the next `send` picks it up;
    /// * the composer's upload counters, which it deliberately does not join —
    ///   `uploading` and `pendingUploads` drive the composer and a composer
    ///   send's `waitForUploads`, and a queued message's file is neither;
    /// * the fact that the item it was picked for may be gone by the time the
    ///   upload answers — edited back to the composer, or already sent. The
    ///   target is resolved again on landing, and a file whose message has left
    ///   lands in the composer, where the user can still see it.
    private func attachForQueue(data: Data, name: String, mimeType: String) {
        let target = uploadLandingTarget ?? queue.items.last
        target?.awaitingUploads = true
        uploadLandingTarget = target
        queueUploadsInFlight += 1
        error = nil
        Task { [weak self] in
            guard let self else { return }
            let uploaded: FileRecord?
            do { uploaded = try await self.client.uploadFile(data: data, filename: name, mimeType: mimeType) }
            catch { uploaded = nil; self.noteQueueUploadFailure(name, pickedFor: target) }
            // Resolved *now*, and by id: the item may have been edited away or
            // drained in the meantime, and bytes landing in a message that has
            // gone is the misrouted-pictures bug all over again. `?? target`
            // because the claim may have been made after this upload started —
            // the file was picked for the message queued a moment later, and it
            // belongs to it.
            let landing = self.queue.item(for: (self.uploadLandingTarget ?? target)?.id ?? UUID())
            self.queueUploadsInFlight -= 1
            if self.queueUploadsInFlight == 0 { self.uploadLandingTarget = nil }
            if let uploaded {
                let attachment = PendingAttachment(
                    id: uploaded.id, name: uploaded.filename, mimeType: mimeType, data: data)
                if let landing {
                    landing.attachments.append(attachment)
                    // A late success takes back the deadline's "failed": the
                    // file did arrive, and the message goes out with it.
                    landing.awaitingUploads = false
                    landing.uploadFailed = false
                } else {
                    self.attachments.append(attachment)
                }
            }
            // The drain re-triggers on the way out, failure included: an upload
            // that lands is the second half of an upload-gated drain, and an
            // upload that fails is the moment the queue has to say so.
            self.settleQueue()
        }
    }

    /// A queue upload that failed. The item is held, not quietly trimmed: the
    /// message goes out with its file or not at all, and the two ways on — edit
    /// it, or delete it — are the user's to take, not the app's to choose.
    private func noteQueueUploadFailure(_ name: String, pickedFor: ChatMessageQueue.Item?) {
        if let item = queue.item(for: (uploadLandingTarget ?? pickedFor)?.id ?? UUID()) {
            item.awaitingUploads = false
            item.uploadFailed = true
            error = "Could not attach \(name) to the queued message. "
                + "Edit it to retry, or delete it."
        } else {
            error = "Could not attach \(name)."
        }
    }

    /// Uploads that have been started and not finished.
    ///
    /// The upload begins when the file is picked, which is right, but it means
    /// there is a window in which the picture is chosen, visible in the composer,
    /// and *not yet in* `attachments` — because the id does not exist until the
    /// server answers. Pressing send inside that window used to send the message
    /// without the file and without any complaint. That is the whole of
    /// "I sent a photo and the backend never got it".
    private var pendingUploads: [Task<Void, Never>] = []
    private var uploadsInFlight = 0
    /// Of those, the ones that are images — all the image budget counts.
    private var uploadsInFlightImages = 0
    /// Uploads that have failed, ever. A failed upload never lands in
    /// `attachments` — the chip simply never appears — so without a counter a
    /// later send would quietly ship the reduced set: the multi-photo partial
    /// of the misrouted-pictures bug. `send` aborts when this has moved.
    private var uploadFailureCount = 0
    /// The failure count as of the last send that got cleanly past its upload
    /// wait. Sticky across sends on purpose: a failure that happened *before*
    /// the send press must still abort that send, so the baseline is taken
    /// after `waitForUploads()` inside the run, never at the button press.
    private var uploadFailuresAtLastSend = 0

    /// Backstop for a transport that ignores the upload client's own 120s
    /// URLSession timeout (`OWUIClient.uploadFile`): a hung /files POST must
    /// not pin send in `.waiting` with the draft already consumed.
    /// Deliberately ABOVE the transport's bound: in production the URLSession
    /// timeout should win the race and take the ordinary failure path (a
    /// real failure message, sticky-failure bookkeeping); this backstop only
    /// fires for a transport that ignores its own timeout. Tests shrink it;
    /// production keeps the default.
    var uploadWaitLimit: Duration = .seconds(125)

    /// Waits for every in-flight upload, bounded by `uploadWaitLimit`.
    /// Returns true when the deadline fired first. One overall deadline, not
    /// one per task: uploads run concurrently, so per-task windows would
    /// multiply. Timed-out upload tasks are deliberately NOT cancelled: if
    /// the socket is merely slow, a late success re-adds the chip (the user
    /// can resend), and a late failure takes the existing sticky-failure
    /// path — cancelling would fake a failure the next send would hold
    /// against the user.
    ///
    /// Two unstructured racers on a once-latched continuation rather than a
    /// task group: a group joins every child before returning, and a child
    /// parked on `await task.value` of a hung `Task<Void, Never>` cannot be
    /// cancelled free (`value` on a never-throwing task does not observe
    /// cancellation), so the group would never return — the very hang this
    /// bounds. Residue: the losing racer stays parked — the upload racer on
    /// an already-hung upload (bounded by URLSession in production), the
    /// sleeper for the rest of its sleep. Suspended tasks, no CPU; not
    /// worth the handle-passing machinery to cancel them.
    private func waitForUploads() async -> Bool {
        guard !pendingUploads.isEmpty else { return false }
        let waiting = pendingUploads
        pendingUploads = []
        let limit = uploadWaitLimit
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce()
            Task {
                for task in waiting { _ = await task.value }
                if once.claim() { continuation.resume(returning: false) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: true) }
            }
        }
    }

    /// One-shot latch: whichever racer finishes first claims it and resumes
    /// the continuation; the other loses and does nothing.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// A file the picker handed over and the app could not read.
    public func attachmentFailed(_ name: String) {
        error = "Could not read \(name)."
    }

    public func detach(_ attachment: PendingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Diagnostics: a single-value env var.
    static func debugString(_ name: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name]
        #else
        nil
        #endif
    }

    /// Diagnostics only: `TIAI_FEATURES=terminal,foo=false` merges extra keys into
    /// the `features` map so a candidate capability name can be tested against a
    /// live server without guessing from the client's own defaults.
    static func debugFeatureOverrides(base: [String: Bool]) -> [String: Bool] {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["TIAI_FEATURES"], !raw.isEmpty
        else { return base }
        var merged = base
        for item in raw.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1)
            let key = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !key.isEmpty else { continue }
            let value = parts.count > 1 ? (parts[1] == "true") : true
            merged[key] = value
        }
        return merged
        #else
        return base
        #endif
    }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // `uploading` counts as content. A picture that is still on the wire is
        // not an absent picture, and refusing to send until it lands is better
        // than sending a message that quietly lost it.
        // `.loading` is not `.isBusy`, and on an uncached chat the branch is not
        // on screen yet: counting over an empty `turns` would see only this
        // message and let a certain 500 through. The composer is disabled for
        // the same reason (`canSend`); this is the same gate for every other
        // caller. Silent, because there is nothing wrong to report — the chat is
        // simply not ready yet.
        guard !(text.isEmpty && attachments.isEmpty && !uploading) else { return }
        // Issue #37: a chat that is busy is no longer a chat that cannot take a
        // message. The content guard above comes first on purpose — an empty
        // press is still nothing at all, busy or not — and everything the send
        // would have refused for other reasons is now the queue's problem
        // later, with the guards re-run against the model of the moment.
        if phase.isBusy, queueEnabled {
            enqueueWhileGenerating(text: text)
            return
        }
        // ...and with the feature off, a busy chat refuses exactly as it always
        // did: silently, with the draft left where it was.
        guard !phase.isBusy, phase != .loading else { return }
        // Refused before anything is touched: the draft and the attachments are
        // still in the composer because nothing has been consumed, and the
        // phase never left `.ready`. Deliberately here rather than in
        // `exchange`, which runs after the draft is cleared.
        if let refusal = imageLimitMessage(outgoing: attachments) {
            error = refusal
            return
        }
        // A model that has *said* — capabilities present and `vision: false` —
        // that it cannot see images must not be handed a picture to drop.
        // `modelSupportsVision` fails open on unknown, so this is the only
        // blind case left, and it gets refused out loud rather than silently
        // stripped. Same outgoing set the cap guard counts: landed attachments
        // plus images still on the wire. Placed after the cap check so a
        // both-broken send reports the cap, which is the harder fact.
        if !modelSupportsVision,
           attachments.contains(where: \.isImage) || uploadsInFlightImages > 0 {
            error = "\(model) can't see images — remove the picture or pick a vision model."
            return
        }
        beginRun(text: text, fileSource: .composer)
    }

    /// Puts a message pressed while a run is in flight into the chat's queue
    /// (issue #37).
    ///
    /// What it deliberately does *not* touch is the point: no phase, no
    /// generation, no ribbon, no `lastSendText`, no title capture. Queueing is
    /// not a send, and the run that is still going owns every one of those.
    private func enqueueWhileGenerating(text: String) {
        // An upload still on the wire belongs to the message being queued now —
        // unless an earlier queued message already claimed it, which keeps the
        // file with the message it was picked for.
        let claimsUpload = queueUploadsInFlight > 0 && uploadLandingTarget == nil
        queue.enqueue(
            text: text, attachments: attachments, awaitingUploads: claimsUpload)
        // The composer is emptied the way a send empties it: the message is on
        // its way, just later. The draft only goes if it still says what was
        // queued — anything typed since wins, the same no-clobber rule every
        // other put-back in this file follows.
        attachments = []
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        if claimsUpload { uploadLandingTarget = queue.items.last }
    }

    /// Everything `send()` did once its guards passed: claim the composer, raise
    /// the ribbon, and start the run.
    ///
    /// Factored out so the queue can start a run without pretending to be the
    /// composer. The `.composer` path is byte-for-byte what `send` used to do —
    /// every concurrency fix in here (#5, #8, #9, #11, #20, #22, #34) hangs on
    /// that ordering — and the only branching is on `fileSource`, in the four
    /// places a queued run owns state the composer does not.
    private func beginRun(text: String, fileSource: RunFiles) {
        let queuedFiles: [PendingAttachment]
        switch fileSource {
        case .composer:
            queuedFiles = []
            draft = ""
            lastSendText = text
            // #34: the discard-on-stop puts the chat back where the send found
            // it. The name `ensureChat` gives a new chat is captured here (the
            // last point it still holds its pre-send value). Attachments are NOT
            // restored — see the accepted-cost note in `stop()`'s nil branch.
            titleBeforeLastSend = title
            placeholderBeforeLastSend = titleIsPlaceholder
        case .taken(let files):
            // A queued run owns none of that. The composer may already be
            // filling with the *next* message while this one is on the wire, and
            // `lastSendText`/the title capture describe a send the user made at
            // the keyboard, not one the queue let go of by itself.
            queuedFiles = files
        }
        let isQueuedRun: Bool
        if case .taken = fileSource { isQueuedRun = true } else { isQueuedRun = false }
        error = nil
        // Set here rather than inside the task: the button's feedback should not
        // wait for a scheduling hop, and a caller that then awaits something
        // conditioned on the phase would otherwise race the run it just started.
        phase = .waiting
        runGeneration += 1
        let gen = runGeneration
        lastRunWasQueued = isQueuedRun
        lastQueuedRun = isQueuedRun ? (text, queuedFiles) : nil
        // Out-of-process progress. A long answer outlives the app switcher, and
        // coming back to a transcript that has not moved is indistinguishable
        // from a hung one; a ribbon that says "Writing · local-deep" settles it.
        // `send` is synchronous — a button press should not wait on anything —
        // so the ribbon is raised on the main actor rather than awaited here.
        let ribbonTitle = title.isEmpty ? "New Chat" : title
        let ribbonModel = modelIDs.first ?? ""
        let ribbonChat = chatID
        // Captured, not discarded: the abort path below has to await the raise
        // before it can close the ribbon, or the finish runs while `start` is
        // still queued behind this task and no-ops on a nil activity —
        // leaving an orphaned "Waiting" ribbon when the start finally runs.
        let ribbon = Task { @MainActor in
            await activity.start(chatTitle: ribbonTitle,
                                 model: ribbonModel, chatID: ribbonChat)
        }
        // Kept for the adoption point (issue #20): a new chat's `claim` has to
        // land *after* this raise, because `start` suspends inside
        // ActivityKit and the first frame can beat it back.
        ribbonRaise = ribbon
        run = Task {
            // Taken *after* the wait, because until the upload answers there is
            // no file id to take.
            let uploadsTimedOut: Bool
            if case .composer = fileSource {
                uploadsTimedOut = await self.waitForUploads()
            } else {
                // A queued run has no composer uploads to wait for. Its own
                // files are gated by the queue's `awaitingUploads` flag long
                // before a drain lets the message out, and waiting here would
                // stall it behind a file picked for the *next* message.
                uploadsTimedOut = false
            }
            // A superseded run (abandoned, or replaced by a newer send while the
            // upload wait was in flight) must not touch state it no longer owns:
            // neither the abort branch below nor the `attachments` steal would
            // be its to take any more. One guard covers the whole post-await
            // region because there is no await between it and `exchange`.
            guard gen == runGeneration else { return }
            // A failed upload is invisible in `attachments` — the chip never
            // appeared — so a send that simply carried on would ship a silently
            // reduced set. The checkpoint is compared here, after the wait, and
            // not at the button press: a failure that happened *before* the
            // press must still abort this send, and a failure whose upload is
            // still on the wire is counted by the wait above. On abort the
            // checkpoint is re-synced rather than left behind, or one old
            // failure would block every later send forever; the landed
            // attachments stay put so a retry is one more press away — with
            // the failed file now the user's decision, not the app's.
            let sawNewFailure: Bool
            if case .composer = fileSource {
                sawNewFailure = uploadFailureCount > uploadFailuresAtLastSend
                uploadFailuresAtLastSend = uploadFailureCount
            } else {
                // The queue keeps its own upload state; the composer's sticky
                // failure checkpoint is not its business — reading it would
                // abort a queued message over a file that failed for the
                // composer, and writing it would make this run block the next.
                sawNewFailure = false
            }
            // Issue #22: a stop pressed while this run was parked in
            // `waitForUploads`. The wait is not cancellation-cooperative and
            // `stop` never bumps the generation, so the gen guard above
            // cannot see the stop — this is the first point after the wake
            // where it is visible: `finishLocally` cancelled this Task in the
            // same main-actor turn it settled the phase to `.ready`.
            // Cancellation *is* the marker (the contract #18 set for edit's
            // updateMessage window); without this guard the run would enter
            // `exchange`, flip the UI back to `.waiting`, POST and stream a
            // message the user already stopped. The failure checkpoint above
            // was already re-synced, so one old upload failure cannot wedge
            // later sends. Draft: mirror #8's abort — the message was never
            // posted, so the text goes back to the composer, but only if the
            // user has not typed in the meantime.
            //
            // This check runs BEFORE the #6/#8 abort branch on purpose: when
            // a stop and an upload failure/timeout race, the stop wins and
            // stays banner-free — `Task.isCancelled` takes precedence,
            // because the stop is the newer intent (the same priority #18
            // decided for edit's catch).
            if Task.isCancelled {
                switch fileSource {
                case .composer:
                    if draft.isEmpty { draft = text }
                case .taken:
                    // Back to the queue, not to the composer: a queued message
                    // restored into the draft would strand everything still
                    // waiting behind it, and the composer may hold the next
                    // message already.
                    putBackInQueue(text: text, files: queuedFiles)
                }
                // Same shape as the abort branch: await the raise first, or
                // the finish no-ops on a nil activity and the raise finally
                // lands as an orphaned ribbon. The generation re-check after
                // that await: `ribbon.value` is a real suspension, and a new
                // send (the phase has been `.ready` since the stop) could
                // have raised this chat's next ribbon — a stopped run must
                // not close the ribbon its successor raised (#5's lesson).
                await ribbon.value
                if gen == runGeneration {
                    await activity.finish(.stopped, characters: 0, chatID: chatID)
                }
                return
            }
            if sawNewFailure || uploadsTimedOut {
                phase = .ready
                // Restore only if the draft is still empty: a message typed
                // during a long `waitForUploads` must not be clobbered by the
                // text of the send that just aborted.
                if draft.isEmpty { draft = text }
                // A timeout outranks a stale failure count: the hung upload
                // *is* the news, whether or not an older failure is also
                // sitting in the checkpoint. With no attachment on hand the
                // "remove the failed one" fix makes no sense — the failure
                // is stale, from before the press. Name the actual choice.
                if uploadsTimedOut {
                    error = "Upload is taking too long — message not sent. Try again in a moment; the file may still arrive."
                } else {
                    error = attachments.isEmpty
                        ? "A previous upload failed — press send again to send without it, or re-attach the file."
                        : "Upload failed — message not sent. Remove the failed attachment and send again."
                }
                // The sticky-failure path never suspends in `waitForUploads`,
                // so the ribbon raise may still be sitting in the main-actor
                // queue. Await it first, then close the ribbon directly —
                // this task already runs on the main actor. The generation
                // re-check after the await (#29, mirroring #22): `phase`
                // became `.ready` at the top of this branch, so a fresh send
                // can raise this chat's next ribbon during `ribbon.value`'s
                // suspension — an aborted run must not close its successor's
                // ribbon.
                await ribbon.value
                if gen == runGeneration {
                    await activity.finish(.stopped, characters: 0, chatID: chatID)
                }
                return
            }
            let files: [PendingAttachment]
            if case .taken = fileSource {
                files = queuedFiles
            } else {
                files = self.attachments
                self.attachments = []
            }
            await self.exchange(text: text, regenerating: nil, files: files, gen: gen,
                                queuedRun: isQueuedRun)
        }
    }

    /// The stored chat, kept so the message tree can be walked without another
    /// round trip. Sibling navigation and edit-and-resend both need the tree, and
    /// refetching on every chevron tap would make a one-tap action feel slow.
    private var detail: ChatDetail?

    /// Ratings given in this session, keyed by message id. The server has no
    /// read-back that is worth a request per message, so the app remembers what
    /// it sent rather than pretending the state is unknown.
    public private(set) var ratings: [String: Int] = [:]

    /// Edits a user message and re-runs from it.
    ///
    /// The text is stored first and the run started second, because the server
    /// files the new answer as a sibling of the edited message: the old branch
    /// survives, which is the whole point of editing rather than deleting.
    public func edit(messageID: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !phase.isBusy, phase != .loading,
            let index = turns.firstIndex(where: { $0.id == messageID })
        else { return }
        // The same gate as send and regenerate, before the server update and
        // before any local mutation: a refused edit must leave everything as it
        // was. The tail about to be removed is counted too — over-counting is
        // the safe direction.
        if let refusal = imageLimitMessage(outgoing: []) {
            error = refusal
            return
        }
        error = nil
        // Capture the pre-edit turn before the mutation below: its images are
        // what the updateMessage write and the completion have to resend, or
        // the server's overwrite drops them from the stored record.
        let carried = turns[index]
        turns[index].text = clean
        // Everything after the edited message belongs to the branch being
        // replaced; leaving it on screen would show an answer to a question that
        // no longer says that.
        turns.removeSubrange(turns.index(after: index)..<turns.endIndex)
        leafID = messageID
        // Only the text is replaced locally: the turn keeps its attachments and
        // image URLs so the UI still shows the picture.
        let content = Self.resentUserContent(text: clean, imageURLs: carried.contentImageURLs)
        let resentFiles = Self.resentFilePayload(carried.attachments)
        let files = resentFiles.isEmpty ? nil : resentFiles
        // Mark busy *before* the run starts, next to the generation bump — the
        // same shape as send's prologue. Without it the model stays `.ready`
        // through the `updateMessage` await, so a send pressed in that window
        // is not refused: it bumps the generation, this edit's exchange then
        // arrives generation-stale and silently no-ops — branch already
        // truncated locally, message already rewritten server-side, and no
        // answer ever generated for either (issue #13).
        phase = .waiting
        runGeneration += 1
        let gen = runGeneration
        run = Task {
            do {
                try await client.updateMessage(
                    chatID: chatID ?? "", messageID: messageID,
                    content: content, files: files)
            }
            catch {
                // Issue #18: a stop pressed during this update's window
                // cancels this Task (stop's `finishLocally` owns the
                // cancellation), and with a cancellation-cooperative
                // transport the halted update surfaces as *this* throw. The
                // stop is the user's intent, not a failure — stamping the
                // cancel error here flashed a cancelled-error banner over a
                // stop that had already been acknowledged. `finishLocally`
                // settled the phase in the same main-actor turn it cancelled
                // this Task, so there is normally nothing left to do; the
                // belt-and-braces restore only fires if the phase is somehow
                // still ours and still busy, so a cancelled run can never
                // wedge it. A genuine failure that races the stop is swallowed
                // here too — `Task.isCancelled` takes precedence, because the
                // stop is the newer intent.
                if Task.isCancelled {
                    if gen == runGeneration, phase.isBusy { phase = .ready }
                    return
                }
                // The run owns the phase now, so a failure has to hand it
                // back — but only if the run is still current: an abandon
                // during the POST already reset the phase itself, and a newer
                // run's `.waiting` is not this stale failure's to stamp over
                // (the same generation guard issue #5 established for stop).
                if gen == runGeneration {
                    self.error = error.localizedDescription
                    phase = .ready
                }
                return
            }
            // Issue #18: a stop pressed during the update window cancelled
            // this Task. The edit itself is saved — the update landed
            // server-side before the stop was acknowledged, and that save
            // surviving its own stop is the documented choice — but the
            // re-run is what the user stopped. `exchange`'s generation guard
            // cannot catch this: stop never bumps the generation, so the
            // completion would POST and stream after the UI had already gone
            // `.stopping` → `.ready`. Cancellation *is* the marker; the phase
            // and UI were settled by `finishLocally`.
            if Task.isCancelled { return }
            await self.exchange(text: clean, regenerating: messageID, files: [], gen: gen)
        }
    }

    /// Thumbs a reply up or down. Tapping the same thumb again takes it back to
    /// no rating locally; the server keeps the record either way.
    public func rate(messageID: String, rating: Int) {
        ratings[messageID] = ratings[messageID] == rating ? nil : rating
        guard let chatID else { return }
        Task {
            do { try await client.rate(chatID: chatID, messageID: messageID, rating: rating) }
            catch { self.error = "Could not record that: \(error.localizedDescription)" }
        }
    }

    /// Which assistant sibling the current branch is on, 1-based, or nil when
    /// there is nothing to page through.
    public func siblingPage(of messageID: String) -> (index: Int, total: Int)? {
        let kids = detail?.messages[messageID]?.childrenIDs ?? []
        guard kids.count > 1, let current = branchChild(of: messageID),
            let at = kids.firstIndex(of: current)
        else { return nil }
        return (at + 1, kids.count)
    }

    /// Moves to the previous or next sibling answer and rebuilds the transcript
    /// along that branch.
    public func selectSibling(of messageID: String, direction: Int) {
        guard let detail,
            let kids = detail.messages[messageID]?.childrenIDs,
            let current = branchChild(of: messageID),
            let at = kids.firstIndex(of: current)
        else { return }
        let next = kids.index(at, offsetBy: direction)
        guard kids.indices.contains(next) else { return }
        // Walk to the end of the branch, not just to the sibling itself.
        //
        // Stopping at the sibling dropped everything below it: paging back to an
        // older answer made the rest of the conversation — including any picture
        // attached after it — vanish, which looked like data loss rather than
        // paging.
        let target = leaf(below: kids[next])
        leafID = target
        turns = ChatMessage.tree(from: detail.messages, currentID: target).map(Turn.init)
    }

    /// The last message below `id`, following the newest child at each step.
    private func leaf(below id: String) -> String {
        ChatTree.leaf(below: id, in: detail?.messages ?? [:])
    }

    /// The child of `messageID` that leads to the message the branch ends on.
    private func branchChild(of messageID: String) -> String? {
        guard let detail, let leaf = leafID else { return nil }
        return ChatTree.branchChild(of: messageID, leaf: leaf, in: detail.messages)
    }

    /// Re-runs the last user message. That message's id is reused, so the server
    /// files the new answer as a sibling in the message tree instead of a new
    /// turn — which is what makes the web UI's "2/3" possible, and costs nothing
    /// here because the app already knows the id.
    public func regenerate() {
        guard !phase.isBusy, phase != .loading, let index = turns.lastIndex(where: \.isUser) else { return }
        // Counted over the whole branch, tail included — the tail is about to
        // be truncated and would not really be re-sent, so this over-counts,
        // which is the safe direction. Checking after the truncation would let
        // a refused regenerate destroy the very answer it was only meant to
        // re-run.
        if let refusal = imageLimitMessage(outgoing: []) {
            error = refusal
            return
        }
        let last = turns[index]
        error = nil
        turns.removeSubrange(turns.index(after: index)..<turns.endIndex)
        leafID = last.id
        phase = .waiting
        runGeneration += 1
        let gen = runGeneration
        run = Task { await self.exchange(text: last.text, regenerating: last.id, files: [], gen: gen) }
    }

    /// Asks the server to halt the run in flight.
    ///
    /// It has to be a separate request: the completion POST is still open for the
    /// whole generation, so there is no other channel to shout down. A 200 here
    /// is not proof anything stopped — hence `stopping` rather than `ready`, and
    /// the terminal frame is what actually ends it.
    ///
    /// Issue #28: a run on a chat the server does not know yet has no server to
    /// ask — there is no chat id, so there is no route to POST. Pressing Stop
    /// there used to be a no-op, which left the button dead for the whole
    /// pre-chat window (the upload wait, and the completion POST whose chat id
    /// the stream has not named yet) on a brand-new chat: the chat sat in
    /// `.waiting` and then shipped the message the user had just tried to
    /// abort. The abort is therefore purely local:
    /// `finishLocally(chatID: nil, …)` cancels the run Task, and cancellation
    /// *is* the stop marker the run's own guards read — #22 built exactly that
    /// guard for `send`'s upload wait, and it is the only suspension between
    /// the send and the POST (`ensureChat` names a brand-new chat from the
    /// stream, it does not make a request of its own). The generation is
    /// deliberately not bumped: those guards finish the ribbon and restore the
    /// draft behind `gen == runGeneration`, and every other generation gate in
    /// the run would go inert instead of doing its local-finish work.
    ///
    /// The button keeps the same shape either way — busy means Stop works — and
    /// the local abort settles straight to `.ready`: `.stopping` means "the
    /// server has been asked", and here nobody was.
    public func stop() {
        guard phase.isBusy else { return }
        // A stop belongs to the run it stops: capture the generation, never bump
        // it. If a newer run starts while the stop POST is in flight, the slow
        // stop must not come back and finish *that* run (issue #5).
        let gen = runGeneration
        userStopped = true
        guard let chatID else {
            // Issue #28: nothing to ask. Cancel the run where it is parked and
            // let its own cancellation guards do the local finish (draft back
            // to the composer, ribbon closed, no banner, no completion POST).
            //
            // Issue #34 (product call): and then DISCARD the chat. A stop here
            // means "this message did not happen", so the transcript goes back
            // to empty and the text goes back to the composer — the same
            // never-happened shape #22's upload-wait abort has. The accepted
            // cost, deliberately accepted: if the completion POST was already
            // open, the server finishes a chat nobody is watching, and that
            // chat shows up in the chat list with its full answer. There is
            // no id to address a real stop until the first frame names one;
            // racing that window with a deferred stop (option (b) on the
            // issue) was passed over for this simpler, honest shape.
            //
            // Safe to clear mid-flight: every stream write is resolved by
            // message id at write time (#14), so a drain still in flight
            // skips these removed turns instead of resurrecting them, and
            // `leafID` is meaningless for the next send — a brand-new chat
            // posts no parent until an id exists.
            finishLocally(chatID: nil, gen: gen)
            turns = []
            leafID = nil
            // Same rule as #22's abort: text returns only if the composer is
            // still empty — anything typed since the press wins.
            if lastRunWasQueued, let run = lastQueuedRun {
                // A queued run goes back to the queue, never to the composer:
                // the composer may hold the next message already, and the
                // messages still waiting behind this one belong with it
                // (issue #37).
                lastQueuedRun = nil
                queue.enqueue(text: run.text, attachments: run.files)
            } else if !lastRunWasQueued {
                if draft.isEmpty { draft = lastSendText }
                // Undo `ensureChat`'s rename: a chat that never happened keeps the
                // name it had before the send named it after the message. A queued
                // run never captured that name, so it has nothing to undo — and
                // undoing it would rename the chat after a message from before it.
                title = titleBeforeLastSend
                titleIsPlaceholder = placeholderBeforeLastSend
            }
            // Accepted cost (review of #34): attachments are NOT put back. By
            // the time a stop can discard the chat, the run Task has stolen
            // the *landed* files into `exchange` and cleared `attachments`;
            // the only snapshot available at `send()` is the still-uploading
            // state, and restoring a half-uploaded chip is a worse bug than
            // the rare loss (a brand-new chat, stopped mid-first-send, that
            // had a file attached). The text — the thing the issue is about —
            // always comes back.
            //
            // Issue #37: and now the queue gets its turn. Last, after every
            // mutation above, because a drain that ran before the discard was
            // undone would send into a chat that has just been thrown away.
            // `afterStoppingQueuedRun` is why the stopped run's own message is
            // not fired straight back out: a stop means "not now".
            settleQueue(afterStoppingQueuedRun: lastRunWasQueued)
            return
        }
        phase = .stopping
        Task {
            do {
                try await client.stop(chatID: chatID)
            } catch {
                // Same race as finishLocally below: a stop POST that fails
                // after a newer run started must not stamp its error onto
                // THAT run's banner (issue #5).
                if gen == runGeneration {
                    self.error = error.localizedDescription
                }
            }
            // The server has confirmed the task is stopped. Waiting for a frame
            // to prove it was the old design, and on a real stop that frame
            // never came: the run was over but nothing terminal was emitted, so
            // the button stayed red and the chat looked frozen even though
            // nothing was happening. A Stop button that stops is what was asked
            // for. Whatever arrived stays on screen.
            finishLocally(chatID: chatID, gen: gen)
            // Issue #37, and the reason steering waits for this point: the stop
            // POST has resolved, so the chat is free and a steered message can
            // go out without racing the server's own stop.
            settleQueue(afterStoppingQueuedRun: lastRunWasQueued)
        }
    }

    /// Ends the run in the app, whatever the server does next.
    ///
    /// A nil `chatID` is the issue #28 case: a run on a chat the server never
    /// learned about, so Stop has nothing to ask and aborts locally.
    private func finishLocally(chatID: String?, gen: Int) {
        guard gen == runGeneration else { return }
        run?.cancel()
        post?.cancel()
        post = nil
        if let chatID {
            hub.expire(chatID: chatID)
        }
        // #36: end exactly this model's pre-id listener, if this run
        // installed one (nil token: it subscribed by id, or never got to
        // install one — e.g. the upload-wait window). This replaces the
        // global `expireWaitingListeners()` sweep and its two blast-radius
        // gates (#9's `chatID == nil`, #28's `hadOpenPost`): a token can
        // only ever address the listener THIS model installed, so the
        // cross-model hazard those gates could only bound is structurally
        // gone, and the adopted-id residual is covered too (the token
        // survives adoption).
        if let token = waitingToken {
            hub.expire(waitingToken: token)
            waitingToken = nil
        }
        // One index for both jobs below: the buffer's own turn while a buffer
        // is in flight (the id match is the truth — a regenerate can have
        // replaced the tail), the last assistant turn otherwise (drain already
        // flushed, or the run never got a buffer).
        let bufferIndex = pending.flatMap { p in turns.firstIndex(where: { $0.id == p.id }) }
        if let index = bufferIndex ?? turns.lastIndex(where: \.isAssistant) {
            turns[index].streaming = false
        }
        // Publish the buffer *before* declaring ready: any first-`.ready`
        // observer — the UI, a test — reads `turns`, so `.ready` has to imply
        // "the buffer is published". Without this, an observer landing here
        // while drain was still in flight read the empty placeholder turn: the
        // streamed deltas were still only in `pending`, visible in `turns`
        // only once the 60 ms flusher happened to have ticked.
        //
        // The non-final `publishPending`, not `flush(final: true)`: when drain
        // is still in flight, its final flush runs after this and stays
        // authoritative for error, streaming and usage; in the common ordering
        // drain already ran and `pending` is nil — which is what the
        // `if let pending` guard below is for.
        //
        // And `pending` must NOT be nilled here: drain's final flush reads it
        // (`var finished = pending ?? Turn(...)`), so clearing it would flush an
        // empty Turn over the text published just above.
        if let pending, bufferIndex != nil {
            // The non-final flush flips `.stopping` back to `.streaming` when
            // the buffer is non-empty (`flush`'s phase rule); unobservable —
            // `phase = .ready` follows in the same synchronous main-actor turn.
            publishPending(keeping: pending.id)
        }
        phase = .ready
    }

    /// Gives up on the local view of a run — used when the app goes to the
    /// background, where the socket will be cut anyway.
    public func abandon() {
        // Give up on the current run *before* anything else: the run's own
        // unwinding (its drain returning, its post catch firing) now sees a
        // stale generation and stays inert instead of poisoning the next run
        // (issue #11).
        runGeneration += 1
        run?.cancel()
        post?.cancel()
        post = nil
        // Hub teardown (issue #4). The generation bump alone does not end the
        // frame stream: `run?.cancel()` cannot stop a `for await` over an
        // `AsyncStream` — cancellation does not terminate iteration — and the
        // frame loop's #16 guard is id-based (abandon deliberately does not
        // clear `pending`), so a superseded drain only breaks out when a NEW
        // run installs its buffer. If no new run starts, the abandoned drain
        // keeps its hub subscriber and 60 ms flusher alive indefinitely: the
        // silence watchdog that used to be the backstop is generation-gated
        // since #21 and correctly never fires for a superseded run. The
        // So end the streams here, as `finishLocally` does for stop: the
        // abandoned drain wakes on the closed stream, exits the loop, and its
        // final flush — id-gated, and `pending` is still this run's —
        // republishes the buffer as final and nils it; everything after the
        // drain is generation-guarded inert. Gated on `phase.isBusy`: an
        // idle model has nothing of its own streaming, and an orphaned
        // duplicate of the same chatID abandoning while idle must not expire
        // the live model's listener (the same accepted trade as `stop`,
        // which can only fire while busy).
        if phase.isBusy {
            if let chat = chatID {
                hub.expire(chatID: chat)
            } else if let token = waitingToken {
                hub.expire(waitingToken: token)
            }
            // #36: exactly this model's pre-id listener, token-addressed —
            // replacing the #9-gated global sweep this site used to make
            // (and with it the adopted-id residual this comment used to
            // document: `expire(chatID: "")` never matched a nil-chatID
            // listener, and the sweep missed an adopted one; the token
            // reaches both states).
            if let token = waitingToken {
                hub.expire(waitingToken: token)
                waitingToken = nil
            }
        }
        // One index for both jobs below, exactly as in `finishLocally`: the
        // buffer's own turn while a buffer is in flight (the id match is the
        // truth — a regenerate can have replaced the tail), the last
        // assistant turn otherwise (drain already flushed, or the run never
        // got a buffer).
        let bufferIndex = pending.flatMap { p in turns.firstIndex(where: { $0.id == p.id }) }
        if let index = bufferIndex ?? turns.lastIndex(where: \.isAssistant) {
            turns[index].streaming = false
        }
        // Publish the buffer *before* declaring ready — the ordering reasons
        // are `finishLocally`'s (issues #3/#9, and #4 is the same bug on the
        // abandon path): any first-`.ready` observer — the UI, a test — reads
        // `turns`, so `.ready` has to imply "the buffer is published". The
        // streamed deltas live in `pending` between flush ticks, and on the
        // path this method exists for — backgrounding, where the socket dies
        // and the app may not — the next tick may never come, so without this
        // the run's text vanished from the transcript until a reload.
        //
        // `publishPending` is keyed by message id, not generation, so the
        // generation bump above does not suppress it — that is the point: the
        // abandoned run's streamed text stays visible. It is the non-final
        // flush, not `flush(final: true)`: the abandoned drain's own final
        // flush (woken by the `hub.expire` above) stays authoritative for
        // error and usage, and it settles `streaming` too. The flag is
        // cleared above BEFORE publishing because the non-final flush
        // preserves whatever streaming state the turn has — the abandoned
        // turn must end up settled AND with its text, not spinnered. And
        // `pending` must NOT be nilled here: the drain's final flush reads it.
        if let pending, bufferIndex != nil {
            // The non-final flush flips a busy phase back to `.streaming` when
            // the buffer is non-empty (`flush`'s phase rule); unobservable —
            // `phase = .ready` follows in the same synchronous main-actor turn.
            publishPending(keeping: pending.id)
        }
        phase = .ready
        // The abandoned run's exchange returns at its first generation guard and
        // never reaches its own ribbon `finish`, so close it here. `finish`
        // no-ops on a nil activity, so this is safe even when nothing was raised.
        // The owner token still gates it: an orphaned model abandoning must not
        // end a ribbon another chat raised (issue #15).
        let ribbonOwner = chatID
        Task { await activity.finish(.stopped, characters: 0, chatID: ribbonOwner) }
    }

    // MARK: - the exchange

    /// Whether the current model can be shown a picture at all.
    ///
    /// Fails open on unknown, deliberately: the model list may not be loaded
    /// yet, and the selected id can come from the server's own report of the
    /// chat (`apply` sets `model` from `detail.models.first`), so "not in the
    /// list" is common and means *no metadata*, not blindness — the same
    /// idiom as `ChatModel.supports(_ feature:)`, where an empty capability
    /// map is "the server didn't say", not "it can't". The old `?? false`
    /// conflated the two and silently dropped every image block from the
    /// *persisted* message: the photo rendered locally, the server stored a
    /// text-only turn, and the rebuilt history fell back to an older picture.
    /// A wrong yes costs a visible server-side complaint; a wrong no loses a
    /// photo with no error anywhere. So only an explicit `vision: false` is an
    /// honest no — a map that merely lacks the key, empty or not, is unknown
    /// and gets the benefit of the doubt. `send` refuses the explicit-false
    /// case out loud instead of stripping the picture quietly.
    private var modelSupportsVision: Bool {
        models.first(where: { $0.id == model })?.capabilities["vision"] != false
    }

    /// The user message as the server needs it.
    ///
    /// A picture has to be *inside* the message. `files` is what the retrieval
    /// pipeline ingests and what the transcript stores; a vision model receives
    /// its image from the message content, and sending the file id alone meant
    /// the photo was uploaded, shown as attached, sent — and never reached the
    /// model. `data:image/…` is passed straight through by the server, so no
    /// file URL has to be resolved or re-authenticated on the way.
    static func userContent(
        text: String, files: [PendingAttachment], vision: Bool
    ) -> MessageContent {
        let images = vision ? files.filter(\.isImage) : []
        guard !images.isEmpty else { return .text(text) }
        var blocks: [JSONValue] = []
        if !text.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for image in images {
            blocks.append(
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string(
                            "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
                    ]),
                ]))
        }
        return .blocks(blocks)
    }

    /// The `files` list, in the shape the server walks.
    ///
    /// Each entry is an object with a `type` and a nested `file`; the code that
    /// reads them does `item['type']`, so a list of id strings is not a
    /// shorter way of saying the same thing.
    static func filePayload(_ files: [PendingAttachment]) -> [JSONValue] {
        files.map { file in
            fileRow(id: file.id, name: file.name, mimeType: file.mimeType)
        }
    }

    /// One `files` entry. Shared by the send path (`PendingAttachment`) and the
    /// regenerate/edit resend (`MessageAttachment`) so the two can never drift.
    private static func fileRow(id: String, name: String, mimeType: String) -> JSONValue {
        .object([
            "type": .string("file"),
            "id": .string(id),
            "name": .string(name),
            "file": .object([
                "id": .string(id),
                "filename": .string(name),
                "meta": .object([
                    "name": .string(name),
                    "content_type": .string(mimeType),
                ]),
            ]),
        ])
    }

    /// The user message as it goes back on a regenerate or an edit.
    ///
    /// The completion handler *overwrites* the stored user message with
    /// whatever this request carries, so a resend that says `content: "text"`
    /// does not merely fail to add a picture — it deletes the one that was
    /// stored, and every later request rebuilds a history without it. The
    /// URLs travel verbatim from the local turn (`data:`, `file_id://`,
    /// http(s) alike): no refetch, no decoding, and deliberately no vision
    /// gate — this is storage preservation, not a picture for the current
    /// model's eyes, so even an explicitly blind model gets the image back.
    /// Text-only stays a bare string, never an empty-blocks array.
    static func resentUserContent(text: String, imageURLs: [String]) -> MessageContent {
        guard !imageURLs.isEmpty else { return .text(text) }
        var blocks: [JSONValue] = []
        if !text.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for url in imageURLs {
            blocks.append(
                .object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(url)]),
                ]))
        }
        return .blocks(blocks)
    }

    /// The `files` list for a regenerate/edit resend, rebuilt from the turn's
    /// stored attachments.
    ///
    /// Every attachment that is *not* content-derived, images included: the
    /// server's overwrite drops whatever this list omits, so a PDF left out
    /// here is a PDF destroyed. The content-derived pseudo-attachments
    /// `Chat.swift` synthesizes from `data:` blocks are the only ones skipped:
    /// they are not file ids, and sending one under `files` is garbage the
    /// server cannot resolve.
    static func resentFilePayload(_ attachments: [MessageAttachment]) -> [JSONValue] {
        attachments
            .filter { $0.dataURL == nil && !$0.id.hasPrefix("data:") }
            .map { fileRow(id: $0.id, name: $0.name, mimeType: $0.mimeType) }
    }

    private func exchange(
        text: String, regenerating: String?, files: [PendingAttachment], gen: Int,
        queuedRun: Bool = false
    ) async {
        // G1: superseded during the caller's pre-exchange await (send's upload
        // wait, edit's updateMessage). Nothing below is ours to write — not
        // even the model guard's error: that banner belongs to the run that
        // owns the model now.
        guard isCurrent(gen) else { return }
        guard !model.isEmpty else {
            error = "No model selected."
            // G1 above proved this run still owns the model, so the phase
            // stamp is ours to make — without it, a caller that entered
            // busy (send, edit) wedges in .waiting forever.
            phase = .ready
            return
        }
        phase = .waiting
        // A rollback (issue #9) puts a brand-new chat back exactly where the
        // send found it, and `ensureChat` is the thing that renames a new chat
        // after the first message — so the pre-send name is captured here.
        let titleBeforeSend = title
        let placeholderBeforeSend = titleIsPlaceholder
        let chat: String
        do {
            chat = try await ensureChat(named: text)
        } catch {
            // G2: superseded during `ensureChat`. A stale failure banner and a
            // `.ready` that flips the *new* run back to idle are both writes we
            // no longer own.
            guard isCurrent(gen) else { return }
            self.error = error.localizedDescription
            phase = .ready
            return
        }

        // G3: superseded during `ensureChat`'s success hop. Everything from here
        // to the `await drain` runs without a suspension, so this one guard also
        // covers the `postFailureMessage` clear and the `post = Task` slot write.
        guard isCurrent(gen) else { return }

        let userMessageID = regenerating ?? replayedUserMessageID(for: gen) ?? UUID().uuidString
        let assistantID = UUID().uuidString
        let parentID = regenerating ?? leafID

        let content: MessageContent
        let wireFiles: [JSONValue]?
        if regenerating == nil {
            content = Self.userContent(text: text, files: files, vision: modelSupportsVision)
            var turn = Turn(
                id: userMessageID, role: "user", text: text,
                attachments: files.map {
                    MessageAttachment(
                        id: $0.id, name: $0.name, isImage: $0.isImage, mimeType: $0.mimeType)
                })
            // The Turn invariant, applied at send time and not only at adopt:
            // `contentImageURLs` mirrors what the message body carries. A
            // regenerate right after a stopped or errored stream has no stored
            // message to adopt from (`adoptStoredMessage` even refuses to
            // touch attachments that are already set), so without this the
            // resend below would rebuild from empty state and ship text-only.
            turn.contentImageURLs = content.imageURLs
            turns.append(turn)
            wireFiles = files.isEmpty ? nil : Self.filePayload(files)
        } else if let carried = turns.first(where: { $0.id == userMessageID }) {
            // Regenerate and edit: resend the carried turn's images verbatim so
            // the server's overwrite keeps the stored record multimodal.
            content = Self.resentUserContent(
                text: text, imageURLs: carried.contentImageURLs)
            let resent = Self.resentFilePayload(carried.attachments)
            wireFiles = resent.isEmpty ? nil : resent
        } else {
            // Unreachable from either regenerating call site
            // (`regenerate()` and `edit()`): each passes the id of a turn that
            // is still in `turns` — they only truncate the range *after* that
            // turn — so the lookup above hits. A main-actor interleave (e.g.
            // `selectSibling` rebuilding `turns` before this Task body runs)
            // could still miss; the fallback handles it. If the invariant ever
            // broke, the pre-issue-#7 text-only rewrite remains: it can drop
            // images, but guessing a body for a turn we cannot find is worse.
            content = .text(text)
            wireFiles = nil
        }
        let history = wireHistory(through: userMessageID, content: content)
        turns.append(Turn(id: assistantID, role: "assistant", streaming: true))

        // A socket that died in the background, or never came up because the
        // phone was mid-handover when the chat opened, would otherwise send
        // without a session_id — which silently drops the server's builtin tools
        // — and then listen on a dead connection, so the answer exists on the
        // server and never reaches the screen. `connect()` is a no-op when the
        // socket is already up, so this costs nothing on the normal path.
        hub.reconnectIfNeeded()

        // Subscribing before the POST matters: frames can arrive while the
        // request is still in flight, and the socket has no replay.
        let newChat = chat == Self.awaitingChatID
        // A brand new chat has no id to filter on, so the listener adopts the
        // first one it hears a frame for. #36: the token installed here is
        // the precise address of this run's pre-id listener — every
        // teardown path (finishLocally, abandon, recordPostError) ends
        // exactly it, never another model's.
        let frames: AsyncStream<ChatEventSocket.Frame>
        if newChat {
            let token = UUID()
            waitingToken = token
            frames = hub.framesAwaitingChatID(token: token) { [weak self] id in
                Task { @MainActor in self?.adopt(chatID: id) }
            }
        } else {
            waitingToken = nil
            frames = hub.frames(for: chat)
        }
        let request = CompletionRequest(
            model: model,
            messages: Self.systemPrefixed(history,
                prompt: SettingsStore.shared.defaults.systemPrompt),
            // Absent, not null: the server reads a missing `chat_id` as "this is
            // a new chat" and only then offers to name it.
            chatID: newChat ? nil : chat,
            parentID: parentID.map(CompletionRequest.ParentID.message) ?? .root,
            userMessage: CompletionRequest.WireMessage(
                id: userMessageID, role: "user", content: content,
                parentID: parentID, model: model),
            messageID: assistantID,
            features: Self.debugFeatureOverrides(base: features),
            files: wireFiles,
            // `ask` is what makes the server park on a tool call and wait for a
            // tap. Left unset the server runs every tool without asking, which is
            // right for a headless client and wrong for one in the hand.
            params: CompletionRequest.Params(
                temperature: SettingsStore.shared.defaults.temperature,
                system: SettingsStore.shared.defaults.systemPrompt
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : SettingsStore.shared.defaults.systemPrompt,
                functionCalling: Self.debugString("TIAI_FC"),
                toolApprovalMode: "ask"),
            toolIDs: tools.isEmpty ? nil : tools,
            terminalID: (features[ChatFeature.codeInterpreter.rawValue] == true)
                ? (terminalID ?? Self.debugString("TIAI_TERMINAL_ID"))
                : nil,
            // Left nil on purpose. `tool_servers` is for ad-hoc servers passed by
            // url, which is not what the picker offers: connected MCP servers
            // arrive from /tools/ as `server:mcp:N` and go in `tool_ids` like
            // any other tool. The field stays on the request because the server
            // accepts it, not because anything here sets it.
            toolServerIDs: nil,
            chatVariables: chatVariables,
            // Ask the server for a summarised title, the way the web client does.
            // Tags too, since they show up in the browser and the list is shared.
            // Not follow-ups: the app has nowhere to put them, and asking would be
            // a model call whose result nothing reads.
            sessionID: hub.sessionID,
            backgroundTasks: newChat
                ? ["title_generation": .bool(true), "tags_generation": .bool(true)] : nil)

        // Blocks for the whole generation and yields no body; what is left for it
        // to do is fail loudly (401, 429) and to close. The task inherits this
        // actor's isolation, so reporting from it needs no hop.
        // A failure recorded by an earlier run must never be mistaken for
        // this one's (issue #9).
        postFailureMessage = nil
        // #38: cleared with it, for the same reason — a transient failure that
        // leaked into the next run would capture a 401 into the outbox.
        postFailureIsTransient = false
        // #25: reclaim a POST still held by a superseded run. The occupant at
        // this point is provably nil or a strictly older run's task: the G3
        // guard above and this write are one main-actor synchronous region,
        // and there is one `post = Task` write per exchange and one exchange
        // per generation — so anything in the slot now belongs to an older run.
        // (The path that used to leave one: mid-run `load()` supersede, closed
        // since #19/#26.) Cancelling it reclaims the orphaned POST, and that
        // task's catch self-silences via `Task.isCancelled`.
        post?.cancel()
        post = Task {
            do { try await self.client.stream(request).drain() }
            catch {
                // The normal end of a run cancels this task while the POST is
                // still open — the completion stays in flight until the server
                // closes it — and the cancellation surfaces as a throw here.
                // Recording it stamped a spurious error onto a run that had
                // just finished, and (issue #9) could set the rollback flag of
                // the *next* run through the shared `phase.isBusy` guard.
                //
                // #25: `isCancelled` only covers a same-gen retirement. A run
                // superseded via `load()` + a new send is not cancelled at
                // supersede time — and if its POST dies on its own before the
                // next send's slot write (where it would then be cancelled),
                // it is never cancelled at all — so its late failure still
                // lands here; the gen guard inside `recordPostError` is what
                // silences that case.
                if Task.isCancelled { return }
                self.recordPostError(error, gen: gen)
            }
        }

        var outcome = await drain(frames, assistantID: assistantID, gen: gen)
        // G4 — the core of issue #11. A superseded run returning from its drain
        // must not cancel the *next* run's POST slot, roll its transcript back,
        // or drive its phase. The early return covers the whole post-drain
        // cluster: slot writes, `leafID`, the #9 rollback block, and the parked
        // `.ready` branch.
        guard isCurrent(gen) else { return }
        post?.cancel()
        post = nil

        // #38: any frame carrying this message is proof the server has the
        // exchange, so a replay that got this far has sent its message and the
        // entry is spent.
        //
        // Here rather than in the epilogue at the end of the run, because two
        // of the ways out of this function — the parked question below and the
        // #34 stop-discard — return before the epilogue, and a replay that
        // parked on a tool question would otherwise keep its entry and send
        // the message a second time on the next trigger.
        if let context = outboxReplayContext, context.gen == gen, outcome.sawAnyFrame {
            outboxReplayContext = nil
            outbox?.remove(id: context.entryID)
        }

        if outcome.parked {
            // The run is parked on a question, not finished. `leafID` stays where
            // it was: the answer this turn is still owed, and resending would
            // fork the chat instead of continuing it.
            //
            // And refetch until the question is there. Unlike a finished
            // answer, a parked question is never corrected later: the run is
            // stopped until the user answers, so a question that came through
            // unreadable has nothing that will ever fix it.
            await awaitQuestion(messageID: assistantID, gen: gen)
            // G5 (#17) — the mirror of resolve's R5. The refetch loop is a
            // long await: abandoning the parked run bumps the generation, but
            // this task keeps waiting (the refetch is uncancellable in
            // practice), and when it finally returns the run it belongs to is
            // dead. Stamping `.ready` here would end the *next* run's phase
            // while it is still waiting or streaming.
            guard isCurrent(gen) else { return }
            phase = .ready
            return
        }
        // Issue #9: the POST itself failed — dead server, refused request,
        // signed out — before the run produced a single frame. The exchange
        // never reached the server, so the local user turn and the empty
        // assistant placeholder are a fiction: the transcript showed a
        // question with a dead bubble under a banner that cleared itself.
        // Roll the send back — drop both turns, put the message and its
        // attachments back in the composer, and leave a persistent,
        // dismissible error saying what actually happened.
        //
        // The gates are the whole point:
        // - `postFailureMessage != nil` — only a POST that failed while
        //   `.waiting` with no frames sets it (see `recordPostError`);
        // - `regenerating == nil` — a regenerate/edit failure must not eat the
        //   pre-existing user turn it was re-running;
        // - `phase == .waiting` — a stop (`.stopping`) and a mid-stream drop
        //   (`.streaming`) are different stories with their own handling;
        // - `!outcome.sawAnyFrame` — once any frame for this message arrived
        //   the server knows about the exchange, and rolling back would lie
        //   about what was sent.
        // Issue #38: the outbox arm, and it has to be the first arm — a send
        // that is going to be retried must not also be handed back to the
        // composer or the queue, because then it would go out twice: once by
        // whoever picks up the copy, once by the replay.
        //
        // The gate is the #9 gate plus one of two claims:
        // - this run is a replay (the marker, generation-matched), whose
        //   failure belongs to the outbox and nowhere else; or
        // - it is a fresh composer send, on a chat that already exists, that
        //   failed for a reason worth trying again, with nothing attached that
        //   could not survive the wait.
        if let message = postFailureMessage, regenerating == nil,
           phase == .waiting, !outcome.sawAnyFrame,
           let fate = outboxFate(files: files, queuedRun: queuedRun, gen: gen) {
            postFailureMessage = nil
            postFailureIsTransient = false
            turns.removeAll { $0.id == userMessageID || $0.id == assistantID }
            // `recordPostError` stamped a red banner before this fork ran, and
            // the strip is not a banner: a pending message is not an error, and
            // showing both says "failed" and "waiting" about the same message.
            error = nil
            switch fate {
            case .park:
                outbox?.add(chatID: chat, userMessageID: userMessageID, text: text)
            case .repark(let entryID, let burnsAttempt):
                // A replay owns the queued-run put-back bookkeeping it has no
                // business in: `lastQueuedRun` is what a later `stop()` uses to
                // hand a message to the in-memory #37 queue, and this one's
                // queue is the durable one.
                lastQueuedRun = nil
                outbox?.revertToPending(id: entryID, burnsAttempt: burnsAttempt)
            case .gaveUp(let entryID):
                // Out of attempts. The entry goes and the message becomes what
                // the #9 rollback would have made it: the user's problem again,
                // in the composer, under the banner that says so.
                //
                // Spelled out rather than falling through to the arm below,
                // because that arm's `queuedRun` branch hands the message to
                // the in-memory queue — and a message whose durable entry has
                // just been deleted has nothing left to fall back on but the
                // composer.
                lastQueuedRun = nil
                outbox?.remove(id: entryID)
                var restoredDraft = false
                if draft.isEmpty { draft = text; restoredDraft = true }
                var banner = message == "Signed out." ? message : "Could not send — \(message)."
                if restoredDraft { banner += " It's back in the composer." }
                error = banner
            case .discarded:
                // The entry was cancelled (or deleted under us) while this
                // replay's POST was in flight. Nothing to park, nothing to
                // give back — the phantom turns are already rolled back above
                // and the banner is already cleared. `lastQueuedRun` is
                // cleared for the same reason `.repark` clears it: a replay
                // owns the queued-run put-back bookkeeping, and a discarded
                // run must not leave a cancelled message in a later `stop()`'s
                // hands.
                lastQueuedRun = nil
            }
            outboxReplayContext = nil
            phase = .ready
            await activity.finish(.stopped, characters: 0, chatID: chatID)
            return
        }
        if let message = postFailureMessage, regenerating == nil,
           phase == .waiting, !outcome.sawAnyFrame {
            postFailureMessage = nil
            // Cleared in lockstep with the message, same as everywhere else it
            // is cleared: a flag that outlives its failure would capture the
            // *next* run's non-transient error into the outbox arm above.
            postFailureIsTransient = false
            // By id, not index: nothing else should have moved the array, but
            // id-matching cannot eat the wrong turn if something did.
            turns.removeAll { $0.id == userMessageID || $0.id == assistantID }
            // Same rule as the upload-abort path in `send` (the established
            // precedent for putting a send back): a message typed while the
            // POST was in flight must not be clobbered by the rollback.
            // The draft and the attachments are tracked separately, because
            // the draft is editable mid-run: a user who re-typed while the
            // POST was in flight has their new text left untouched (correct —
            // the same no-clobber rule as above) and the failed text is
            // silently dropped. Claiming "It's back in the composer" then
            // would be a lie the rollback has no way to make true.
            var restoredDraft = false
            var restoredAttachments = false
            var restoredToQueue = false
            if queuedRun {
                // A queued run puts a failed send back where it came from. The
                // composer is somebody else's business by now — it may already
                // hold the message the user is typing next — and the messages
                // still waiting in the queue are the only other copy of this one.
                putBackInQueue(text: text, files: files)
                restoredToQueue = true
            } else {
                if draft.isEmpty { draft = text; restoredDraft = true }
                // `!files.isEmpty`: a text-only send has nothing to put back —
                // claiming "Attachments are back" for an empty list would be the
                // same lie the separate flags exist to prevent.
                if attachments.isEmpty, !files.isEmpty { attachments = files; restoredAttachments = true }
            }
            // "Could not send — Signed out." reads wrong; the 401 already
            // has its own plain sentence, so it stands alone.
            var banner = message == "Signed out." ? message : "Could not send — \(message)."
            if restoredDraft { banner += " It's back in the composer." }
            else if restoredAttachments { banner += " Attachments are back; re-type and send again." }
            else if restoredToQueue { banner += " It's back in the queue." }
            error = banner
            if chatID == nil {
                // A new chat that never learned an id never existed; put the
                // name back the way it was before the send named it after the
                // failed message.
                title = titleBeforeSend
                titleIsPlaceholder = placeholderBeforeSend
            }
            phase = .ready
            // `send` raised the Live Activity ribbon; this early return skips
            // the `finish` at the end of the exchange, so close it here —
            // again mirroring the upload-abort path.
            await activity.finish(.stopped, characters: 0, chatID: chatID)
            // The early return also skips the `emptyAnswerFailure` path below,
            // which would overwrite the real cause with "The server sent
            // nothing." — the misattribution this rollback exists to fix.
            return
        }
        if chatID == nil, userStopped, !turns.contains(where: { $0.id == assistantID }) {
            // #34: the stop-discarded shape. A stop on a brand-new chat
            // discarded the transcript while this exchange was still
            // unwinding (stop never bumps the generation, so the guards
            // above cannot see the discard, and cancellation is not observed
            // between the drain and here). Everything below — `leafID`, the
            // reconcile, the final flush — belongs to a chat that no longer
            // exists locally: writing `leafID` would leave a dangling parent
            // for the next send. Narrowly shaped on purpose: a missing row
            // alone is not enough (a mid-run reload can legitimately drop it
            // and #19's reconcile below re-adds it) — the nil id plus the
            // user-stop marker is what says "discarded".
            await activity.finish(.stopped, characters: 0, chatID: nil)
            return
        }
        if outcome.sawTerminal {
            leafID = assistantID
        } else if outcome.failure == nil {
            if phase == .stopping {
                // A stop the user asked for is not a failure, and saying
                // "Stopped." in an error banner made a working button look like
                // a broken one. The partial answer is the answer they got.
                leafID = assistantID
            } else {
                // No terminal frame at all. Pulling down Control Centre for a
                // second, or a quick app switch, kills the socket while the server
                // carries on writing — and a single look at the record at that
                // moment finds an empty message, which used to be reported as
                // "the server sent nothing" while it was mid-sentence. That is the
                // report of having to leave the chat and come back.
                //
                // So keep watching instead of guessing: this returns when the
                // server closes the message, parks on a question, or the answer
                // genuinely stops growing.
                await reconcileUntilClosed(messageID: assistantID)
                // G5: superseded during the reconcile fetch.
                guard isCurrent(gen) else { return }
                let settled = turns.first(where: { $0.id == assistantID })?.text ?? ""
                if settled.isEmpty {
                    // Issue #28: a run the reader stopped is not an empty
                    // answer. The `phase == .stopping` branch above already
                    // says a stop is not a failure, but it only catches the
                    // ordering where the drain unwinds before `finishLocally`
                    // settles the phase — which is the usual ordering for a
                    // stored chat (the terminal frame wins the race) and never
                    // the ordering of the #28 local abort, where the phase has
                    // been `.ready` since the button press and — for a chat the
                    // stream never named — `reconcileUntilClosed` has no id to
                    // read back from and comes straight back. `userStopped` is
                    // the durable marker for the same fact: it is set by
                    // `stop()` and cleared at the start of every drain, so it
                    // says "this run ended because the reader said so" whatever
                    // the interleaving. Saying "The server sent nothing."
                    // there blamed the server for the user's own tap.
                    if userStopped {
                        leafID = assistantID
                    } else {
                        // "The server sent nothing" is an accusation, and it was
                        // being made about the wrong party. iOS kills the socket on
                        // a background sojourn; if the server record still says the
                        // message is unfinished, the answer is on its way and the
                        // thing that failed was our connection. Saying so is the
                        // difference between a bug report and a dead end.
                        outcome.failure = Self.emptyAnswerFailure(
                            reported: outcome.reportedError,
                            serverStillWriting: detail?.messages[assistantID].map { !$0.done } ?? false)
                    }
                } else {
                    leafID = assistantID
                }
            }
            // And reconcile even when it *did* finish cleanly.
            //
            // A terminal frame says the run ended; it does not say this client
            // understood everything that arrived. Sources, attachments, usage,
            // and the continuation after a tool call all live in frames we may
            // parse incompletely or not at all, and the failure mode is
            // invisible: the answer looks fine until you leave the chat and
            // come back and it is suddenly longer. That "refresh fixes it"
            // feeling is the bug, in three places so far.
            //
            // One GET after every run is the cheap universal answer, and
            // `refresh` only ever grows a turn, so a good live stream is never
            // made worse by it.
            if outcome.failure == nil && !outcome.parked {
                await reconcileUntilClosed(messageID: assistantID)
                // G6: superseded during the post-run reconcile fetch.
                guard isCurrent(gen) else { return }
                leafID = assistantID
            }
            // Once the run is genuinely over nothing is parked any more. Not
            // done inside the flush: a parked run also flushes as final, because
            // the finish frame arrives before the pause frame, and clearing
            // there would wipe the question the user is meant to answer.
            if !outcome.parked, let index = turns.firstIndex(where: { $0.id == assistantID }) {
                turns[index].calls = Turn.reconciling(turns[index].calls, done: true)
            }
            // The title is a background job started when the answer landed, so it
            // is usually a second or two behind the run that triggered it.
            if newChat, outcome.failure == nil, let adopted = chatID {
                await awaitGeneratedTitle(chat: adopted)
            }
        }
        // G7: superseded during the terminal block's last await. Everything
        // below — the error stamp, `markChatRead`, the ribbon finish, the
        // completion notification (no banner for an abandoned run), the
        // streaming flag and `.ready` — belongs to the run that owns the state
        // now, not this one.
        guard isCurrent(gen) else { return }
        // An error that arrived alongside a real answer is noise about how the
        // answer was produced, not a reason to hide it. Only surface it when
        // there is genuinely nothing to show.
        if outcome.failure == nil, let reported = outcome.reportedError {
            let got = turns.first(where: { $0.id == assistantID })?.text ?? ""
            if got.isEmpty { outcome.failure = reported }
        }
        if let failure = outcome.failure { error = failure }
        // The answer just written bumped `updated_at`, which is exactly what the
        // server reads as "unread". Marking read on open is not enough for a chat
        // the app both asked and answered — nobody else needs to be told about it.
        if let chat = chatID, outcome.failure == nil { hub.markChatRead(chat) }
        await activity.finish(
            outcome.failure == nil ? .finished : .stopped,
            characters: turns.first(where: { $0.id == assistantID })?.text.count ?? 0,
            chatID: chatID)
        // Same family as #17: `activity.finish` is a real suspension on iOS
        // (ActivityKit's `end`), so an abandon can interleave exactly here.
        // The notification below, the streaming stamp and `.ready` belong to
        // the run that owns the state now — a just-abandoned run must not
        // announce an answer the user walked away from. (`abandon` has
        // already cleared the streaming flag and stamped `.ready` itself,
        // so returning here leaves nothing dangling.)
        guard isCurrent(gen) else { return }
        if outcome.failure == nil {
            // Only worth saying when nobody is watching: announcing an answer the
            // user is already reading is worse than silence, and the notifier
            // checks that itself rather than trusting the caller to remember.
            let finished = turns.first(where: { $0.id == assistantID })
            CompletionNotifier.answerReady(
                title: title, preview: finished?.text ?? "")
        }
        // Whatever the frame stream believed, the run is over. A turn left
    // flagged as streaming keeps drawing the working indicator, and the only
    // cure was leaving the chat and coming back — which is exactly what the user
    // reported: still "working" long after the answer had landed.
        if let index = turns.firstIndex(where: { $0.id == assistantID }) {
            turns[index].streaming = false
        }
        // #38: reaching here at all means the POST did not fail — it answered,
        // or it was cancelled while the run ended some other way — and the #9
        // fork above is the only other reader of the marker. So the server has
        // the message and the entry is spent. A run the *user* stopped is the
        // exception: no frame and no answer means nobody knows whether the
        // message got there, and an entry that is retried is a message that is
        // not lost, while an entry deleted on a guess is the opposite.
        if let context = outboxReplayContext, context.gen == gen {
            outboxReplayContext = nil
            if userStopped {
                outbox?.revertToPending(id: context.entryID, burnsAttempt: false)
            } else {
                outbox?.remove(id: context.entryID)
            }
        }
        phase = .ready
        // Issue #37: the clean end of a run, which is exactly when the queue is
        // owed its turn. Every other way out of `exchange` — the parked
        // question, the #9 rollback, the #34 discard, each generation-guarded
        // return — is an early return that does not get here, and none of them
        // is a chat that has become able to take a new message.
        settleQueue()
    }

    /// Wait for the server's generated title, up to a few seconds.
    ///
    /// The `chat:title` event often arrives mid-run and is picked up there, but
    /// it is a background task and can land after the stream closed, at which
    /// point nothing is listening any more. Re-reading the chat record is the
    /// part that does not depend on timing.
    private func awaitGeneratedTitle(chat: String) async {
        let placeholder = title
        // A summary is a second model call on a local engine, so it can trail the
        // run by a good ten seconds. Giving up early is what makes the fallback
        // fire when it should not have.
        for attempt in 0..<10 {
            try? await Task.sleep(for: .milliseconds(700 * (attempt + 1)))
            guard let fresh = try? await client.chat(id: chat) else { return }
            let generated = fresh.title
            if !generated.isEmpty, generated != placeholder, generated != "New Chat" {
                title = generated
                titleIsPlaceholder = false
                return
            }
        }
        // Nothing came. The server names a chat by generating a summary, and when
        // that does not happen the web client writes a truncated first line so the
        // chat is at least findable in a list it shares with every other client.
        // This is the same fallback, and it is deliberately last: writing it here
        // before the summary has had its chance is how a generated title gets
        // overwritten by the first 40 characters of a question.
        if titleIsPlaceholder, !incognito {
            _ = try? await client.setChatTitle(id: chat, title: placeholder)
        }
    }

    /// Set when the reader pressed Stop. A stopped run has nothing new attached
    /// to it, so the post-run refetch is skipped — it would only be a network call
    /// racing with the screen that just stopped showing things.
    private var userStopped = false
    /// The text of the most recent `send()`, kept so a stop on a brand-new
    /// chat can put it back in the composer when discarding the chat (#34).
    /// Not cleared on success — a stale value is only ever read by the nil-
    /// chatID stop branch, and only when the composer is empty.
    private var lastSendText = ""
    /// The pre-send chat name captured at `send()` for the same reason as
    /// `lastSendText` (#34): the discard restores the name `ensureChat` gave
    /// a chat that turned out to never happen.
    private var titleBeforeLastSend = ""
    private var placeholderBeforeLastSend = false

    struct DrainOutcome {
        var sawTerminal = false
        /// An error the server reported mid-run, kept apart from `failure`.
        ///
        /// A model backend can drop the connection mid-image and the run can
        /// carry on anyway — the user saw exactly that: "empty reply from
        /// server" in a red banner, the spinner off, and the full answer
        /// appearing when they reopened the chat. Recording it separately lets
        /// the run be judged on what actually arrived rather than on the worst
        /// frame that passed by.
        var reportedError: String?
        /// Waiting on the user to answer a tool call. Distinct from finishing,
        /// because nothing more will arrive until they do.
        var parked = false
        var failure: String?
        /// True once any frame belonging to *this* assistant message has been
        /// handled — even one with no text (an `ask_user` call, a bare title
        /// event) counts: it is proof the server knows about the exchange,
        /// which is the question a rollback asks (issue #9).
        var sawAnyFrame = false
    }

    /// A one-shot `hub.expire(chatID:)` on a budget — the silence watchdog and
    /// its handoff/error-recovery grace timers all install one.
    ///
    /// Cancellation must stand the timer down, not fire it — the `!Task.isCancelled`
    /// gate the #11 fix introduced: `try?` swallows the cancellation every
    /// drain gets on its way out, and without the gate `expire` would run
    /// immediately at the end of EVERY drain, finishing every listener for the
    /// chat — including a newer run's, when an abandoned run's drain unwinds
    /// after that newer run subscribed (issue #11). The listener this run
    /// installed is cleaned up anyway when the caller drops the stream.
    ///
    /// The two fire-time gates each close a window where firing is wrong:
    ///
    /// * `isCurrent(gen)` — a newer run may have installed its hub listener
    ///   but not yet its `pending`: a resolve subscribes, then awaits its POST
    ///   (a full network round trip) before its drain installs the buffer,
    ///   and `abandon` does not clear `pending`, so the id check alone still
    ///   passes there. Without the generation gate a superseded drain's timer
    ///   fires `hub.expire(chatID:)` on the shared chatID and kills the
    ///   NEWER run's listener (issue #21).
    /// * `pending?.id == assistantID` — a resolve reuses the parked message
    ///   id, so ids can collide across runs; this check is what encodes
    ///   "the watchdog only fires while this run still owns `pending`".
    ///
    /// Cancellation safety (relies on this type's `@MainActor` isolation):
    /// after the sleep, the isCancelled check, both fire-time gates and the
    /// `expire` run as ONE main-actor job with no suspension point, so a
    /// `cancel()` from the frame loop can never interleave between the check
    /// and the fire — a cancelled timer either never starts its block or
    /// returns at the isCancelled guard. If this Task ever loses MainActor
    /// inheritance (`Task.detached`, a nonisolated refactor), that property
    /// silently disappears and re-arming per frame could false-fire on a
    /// cancellation race. Keep it on the actor.
    private func hubExpireTimer(after limit: Duration, gen: Int, assistantID: String) -> Task<Void, Never> {
        Task { [hub] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            guard isCurrent(gen), pending?.id == assistantID else { return }
            // #42: pick the ADDRESS of this run's listener, not just the
            // id this model happens to hold. An existing chat's listener is
            // keyed by the chat id. A brand-new chat's listener may never
            // have adopted one — if no frame ever carried a chat_id, the
            // old unconditional `hub.expire(chatID: chatID ?? "")` expired
            // "" (nothing, ever), the stream never ended, and the run hung
            // "running" forever while the server sat on a finished record.
            // The #36 token reaches this model's subscriber whether it
            // adopted an id or not, so the watchdog lands in both shapes.
            if let chat = chatID {
                hub.expire(chatID: chat)
            } else if let token = waitingToken {
                hub.expire(waitingToken: token)
            }
        }
    }

    /// Drains frames for one assistant message until the run ends, is stopped,
    /// or parks on a tool call.
    ///
    /// Shared by sending and by resuming, because resolving a tool call starts a
    /// *new* completion on the server whose tokens arrive under the same
    /// assistant message id — the client has to listen again exactly as it did
    /// the first time, and a second copy of this loop is how the two would drift.
    ///
    /// `gen` is the generation the caller was started under; the watchdog and
    /// grace timers installed here fire only while it is still current (#21).
    private func drain(
        _ frames: AsyncStream<ChatEventSocket.Frame>,
        assistantID: String,
        gen: Int,
        continuing: Bool = false
    ) async -> DrainOutcome {
        var outcome = DrainOutcome()
        // A stop belongs to the run it stopped. The next one earns its refetch
        // back.
        userStopped = false
        // Buffered off the frame loop so a timer, not the next frame, decides
        // when it becomes visible. Flushing only "when a frame arrives and 60 ms
        // have passed" loses the tail: a stream that stops without a terminal
        // frame would leave its last tokens buffered and unseen.
        // On a resume the turn already holds the text streamed before the
        // question. Starting from an empty turn would let the first delta of the
        // continuation overwrite everything the answer said up to there.
        if continuing, let existing = turns.first(where: { $0.id == assistantID }) {
            pending = existing
            pending?.streaming = true
        } else {
            pending = Turn(id: assistantID, role: "assistant", streaming: true)
        }
        let flusher = Task { [weak self] in
            // Issue #24: the reveal cursor lives here, in the tick loop that
            // owns it — one owner, no shared mutable state, and a superseded
            // drain's flusher dies with its cursor unpublished-partial.
            // A resume starts from the text already on screen: revealing from
            // zero would blank the pre-resume answer for a tick.
            var revealed = continuing ? (self?.pending?.text.count ?? 0) : 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.flushInterval ?? Self.flushInterval)
                guard !Task.isCancelled else { return }
                revealed = self?.revealTick(keeping: assistantID, from: revealed) ?? revealed
            }
        }
        // Re-armed on every frame attributed to this message below, so this
        // measures silence, not total run time (issue #33).
        var watchdog = hubExpireTimer(after: silenceLimit, gen: gen, assistantID: assistantID)
        // #42: the absolute backstop, NEVER re-armed. The silence watchdog
        // can be outrun by a stream that keeps talking and never terminates
        // (terminal frame filtered, mis-keyed, or never sent); the ceiling
        // ends the stream on wall-clock regardless, and the caller's
        // reconcile reads the truth off the server record. Same gen/pending
        // gates as the watchdog, so a superseded drain's ceiling can never
        // expire a newer run's listener (#21's lesson).
        let ceiling = hubExpireTimer(after: runCeiling, gen: gen, assistantID: assistantID)

        var sawToolArguments = false
        var erroredOnce = false
        var grace: Task<Void, Never>?
        for await frame in frames {
            // A drain superseded after its caller's guard (exchange's G3, the
            // resume's R3) must stop writing: `abandon` bumps the generation
            // but neither expires the hub nor cancels frame iteration, so this
            // loop keeps delivering frames to a run that no longer owns
            // anything — and `pending` is the model-level buffer, so its
            // deltas would append into the NEW run's buffer (issue #16).
            // `break`, not `continue`, because a half-dead drain must stop
            // writing and must reach the watchdog/grace/flusher cancels below
            // the loop — which also unregisters the hub subscriber via the
            // stream's `onTermination`. (The silence watchdog is
            // generation-gated now — #21 — so a half-dead drain left iterating
            // can no longer expire the shared chatID out from under the newer
            // run; breaking is still the right exit.) The final flush is
            // already id-gated, so nothing stale flushes here (the #11 fix).
            // Why this guard can never false-fire mid-run: `pending` is
            // assigned only at this drain's install (just above, synchronously
            // after the caller's generation guard) and at the final flush
            // (after the loop), so mid-loop `pending?.id != assistantID` can
            // only mean superseded.
            guard pending?.id == assistantID else { break }
            if let messageID = frame.messageID, messageID != assistantID { continue }
            // Only frames for this message count — the filter above is what
            // makes that true, so the flag goes directly under it (issue #9).
            outcome.sawAnyFrame = true
            // Issue #33: a frame for THIS message is proof the stream is
            // alive, so the silence budget restarts here. The watchdog used
            // to be installed once per drain and never re-armed: it was an
            // absolute 60 s cap on live streaming. Healthy long runs got
            // `hub.expire(chatID:)` fired at them mid-generation, fell into
            // the chunky reconcile fallback, and looked dead (truncated
            // text, false "server sent nothing" banners) while the server
            // kept writing every word — leave-and-re-enter showed the full
            // answer. Frames for OTHER message ids never reach this line
            // (the filter above `continue`s past them) and must not re-arm:
            // a chatty neighbour must not keep a dead run's listener alive.
            watchdog.cancel()
            watchdog = hubExpireTimer(after: silenceLimit, gen: gen, assistantID: assistantID)
            if let delta = frame.delta { pending?.text += delta }
            if let thinking = frame.reasoningDelta { pending?.reasoning += thinking }
            if let pending {
                await activity.update(
                    phase: pending.text.isEmpty ? .thinking : .writing,
                    characters: pending.text.count,
                    chatID: chatID)
            }
            // Abandon plus a newer send can interleave at `activity.update`'s
            // await: everything below belongs to whoever owns `pending` now.
            guard pending?.id == assistantID else { break }
            if let usage = frame.usage { pending?.usage = usage }
            // The server's own summary for the chat, when it got one mid-run.
            if let generated = frame.title {
                title = generated
                titleIsPlaceholder = false
            }
            if let problem = frame.errorText {
                // Not `failure`: an error frame is the server reporting a
                // problem, not the run ending. Treating it as terminal stopped
                // the listener while the answer was still being written.
                outcome.reportedError = problem
            }
            if let answered = frame.answeredModel { pending?.model = answered }
            if let calls = frame.outputItems { pending?.calls = calls }
            if frame.isToolArgumentsDelta { sawToolArguments = true }
            if frame.isTerminal {
                // A finish_reason is not always the end of the turn.
                //
                // Two cases where the server keeps going under the same
                // assistant message id: a real tool is running (Sonos is off
                // fetching something), and `ask_user` staging its question. In
                // both, breaking here flips the composer back to "finished"
                // while the answer the user asked for is still to come — and with
                // several tool calls it happens several times in one turn.
                //
                // Bounded rather than infinite: if the tool never reports back,
                // the stream really is over and the turn settles on what was
                // stored. The silence watchdog stays as the backstop for a
                // run that goes silent (no frames to re-arm it).
                if pending?.awaitsTool == true
                    || (sawToolArguments && pending?.calls.isEmpty != false) {
                    sawToolArguments = false
                    grace = hubExpireTimer(after: Self.handoffLimit, gen: gen, assistantID: assistantID)
                    continue
                }
                // A run that reported an error and then "finished" is the one
                // case where finishing is not to be believed: the upstream
                // dropped, the server closed the stream, and then carried on
                // writing the answer anyway. Ending here is what turned a
                // recoverable hiccup into a red banner over an empty bubble
                // while the real answer was still being produced. So wait once,
                // on the same budget as a tool handoff, and see if it resumes.
                if outcome.reportedError != nil && !erroredOnce {
                    erroredOnce = true
                    grace = hubExpireTimer(after: Self.errorRecoveryLimit, gen: gen, assistantID: assistantID)
                    continue
                }
                // The stream says it is over. Ask the server anyway.
                //
                // A finish frame is the app's best guess about the end of a
                // turn; the stored message's `done` flag is the server's answer,
                // and on long runs they disagree — the upstream finishes one
                // segment while the run carries on under the same assistant
                // message id. Settling on the guess left the composer showing a
                // finished prompt over half an answer, and leaving and re-entering
                // the chat, which refetches, showed the real one. That asymmetry
                // is the whole bug: the truth was always in the stored message.
                // `chat` is `chatID` captured just before the fetch; a chat id
                // that is already set never changes, so the helper's
                // `chatID ?? ""` expires the same chat as the old inline
                // `hub.expire(chatID: chat)` did.
                if let chat = chatID, await serverStillOpen(chatID: chat, messageID: assistantID) {
                    grace = hubExpireTimer(after: Self.handoffLimit, gen: gen, assistantID: assistantID)
                    continue
                }
                outcome.sawTerminal = true
                break
            }
            // Any frame past this point proves the run is still alive, so the
            // handoff timer is stood down until the next finish frame re-arms it.
            grace?.cancel()
            grace = nil
            // Checked after the terminal test: a frame that both finishes and
            // asks would be a finished run with a question left on screen.
            if frame.isAwaitingUser { outcome.parked = true; break }
        }
        watchdog.cancel()
        ceiling.cancel()
        grace?.cancel()
        flusher.cancel()

        // `pending` is model-level, and a superseded run's drain can return
        // here only after a newer run has installed its own buffer — the
        // flusher's `publishPending` already refuses foreign buffers on this
        // same id check. Flushing a foreign buffer into THIS run's index and
        // then nil-ing it moved the newer run's text into the abandoned turn
        // and left the newer turn empty (issue #11). When the buffer is not
        // ours, take what is already on screen as the result (the abandoning
        // path already settled its streaming flag) and leave the buffer to
        // the run that owns it.
        let finished: Turn
        if pending?.id == assistantID, let buffer = pending {
            var flushed = buffer
            flushed.streaming = false
            flushed.error = outcome.failure
            flush(flushed, final: true)
            pending = nil
            finished = flushed
        } else {
            finished = turns.first(where: { $0.id == assistantID })
                ?? Turn(id: assistantID, role: "assistant")
        }
        // Sources are not streamed as deltas — the server attaches them when it
        // saves the message. Without this a citation only appeared after leaving
        // and re-entering the chat, which reads as the feature being broken.
        // Not gated on `sawTerminal`. A long run — twenty-odd tool calls, a
        // weasyprint build — can end by the listener expiring rather than by a
        // finish frame, and gating on the terminal frame meant exactly those runs
        // never looked at the stored message. Which is where the file the model
        // had just wrote lives. The fetch is cheap and idempotent; the cases it
        // used to skip were the ones that needed it.
        if outcome.failure == nil, !userStopped, let chat = chatID {
            let id = finished.id
            let streamed = finished.text
            // A `display_file` call means a card is owed. The result is written
            // when the server saves the message, which can land a beat after the
            // run ends, so keep looking for a few seconds rather than concluding
            // there is no file on the first miss.
            let owesFile = finished.calls.contains { $0.name == "display_file" }
            let api = client
            // Which run this adopt belongs to. The retry loop below can outlive
            // the run — and the rebuild in `adoptStoredMessage` is a wholesale
            // `turns` replacement, so it must refuse to run once a newer run
            // has started: that run's placeholder rows exist only locally and
            // a rebuild would delete them (issue #19).
            let gen = runGeneration
            Task { @MainActor [weak self] in
                for attempt in 0..<(owesFile ? 5 : 1) {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                    guard let model = self else { return }
                    if await ConversationModel.adoptStoredMessage(
                        model, client: api, chat: chat, id: id, streamed: streamed, gen: gen)
                    { break }
                }
            }
        }
        return outcome
    }

    /// Copies what the stored message knows onto the turn on screen, and reports
    /// whether the turn is now complete enough to stop looking.
    ///
    /// The server attaches sources and terminal files when it *saves* the message,
    /// not as stream deltas, so a run that ends the instant the model stops typing
    /// can be missing both. Leaving and re-entering the chat refetched and they
    /// appeared — which is the asymmetry that makes a feature look broken rather
    /// than late.
    ///
    /// This is also the post-run read that closes issue #19 on the clean-terminal
    /// path: `reconcileUntilClosed` is only reached by runs that ended without a
    /// terminal frame (and by the heal-on-open), so after a normal finish this
    /// fetch is the only thing that looks at the record — and when a mid-run
    /// reload dropped the streaming row, it is the only thing that can put it
    /// back.
    private static func adoptStoredMessage(
        _ model: ConversationModel, client: OWUIClient, chat: String,
        id: String, streamed: String, gen: Int
    ) async -> Bool {
        guard let detail = try? await client.chat(id: chat),
            let stored = detail.messages[id]
        else { return false }
        // Issue #19: the row may be gone. A mid-run reload whose server tree
        // did not yet contain this message dropped it, and flush skips every
        // write for an absent id (#14, correct), so growing the row here was
        // never an option — nothing re-added it and a visibly-live run showed
        // nothing until you left the chat and came back. The stored message
        // is here, so rebuild from the fresh detail: the same wholesale apply
        // load() does, safe since #14 because every stream write resolves by
        // id at write time, and it places the row at the tree-correct
        // position for free. Only while this run is still current — a newer
        // run's local placeholder rows are in no server tree, and rebuilding
        // over them would delete them.
        if model.turns.firstIndex(where: { $0.id == id }) == nil,
           model.runGeneration == gen {
            model.apply(detail)
        }
        guard let at = model.turns.firstIndex(where: { $0.id == id })
        else { return false }
        if stored.citedSources.isEmpty == false {
            model.turns[at].sources = stored.citedSources
        }
        if model.turns[at].terminalFiles.isEmpty, !stored.terminalFiles.isEmpty {
            model.turns[at].terminalFiles = stored.terminalFiles
        }
        if model.turns[at].attachments.isEmpty, !stored.messageAttachments.isEmpty {
            model.turns[at].attachments = stored.messageAttachments
        }
        // The Turn invariant: `contentImageURLs` mirrors the stored message's
        // image blocks (the image budget counts it). A stored message that
        // knows its image blocks has to leave them on the turn on screen.
        if !stored.contentImageURLs.isEmpty {
            model.turns[at].contentImageURLs = stored.contentImageURLs
        }
        // If the stored answer is longer than what arrived, the run outlived the
        // stream. Adopt the stored text rather than leaving half an answer up.
        let storedText = stored.content.text
        if storedText.count > streamed.count + 1 {
            model.turns[at].text = storedText
        }
        return model.turns[at].terminalFiles.isEmpty == false
            || stored.terminalFiles.isEmpty == false
    }

    /// Whether the server still considers this assistant message open.
    ///
    /// Only an explicit `done: false` counts as still running. A message that is
    /// not stored yet, or a chat that will not fetch, is not evidence that the
    /// run finished — but neither is it evidence that it is going, so this says
    /// no and lets the caller settle on what was streamed.
    private func serverStillOpen(chatID: String, messageID: String) async -> Bool {
        for attempt in 0..<3 {
            guard let detail = try? await client.chat(id: chatID) else { return false }
            guard let stored = detail.messages[messageID] else {
                // Not written yet. Give the save a moment rather than reading
                // absence as completion.
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(500)) }
                continue
            }
            return stored.doneFlag == false
        }
        return false
    }

    /// Bytes of a file attached to a message, fetched with the app's token.
    public func fileData(id: String) async -> Data? {
        try? await client.fileContent(id: id)
    }

    // MARK: - tool calls

    /// Answers a parked tool call and picks the run back up.
    ///
    /// The server resumes under the same assistant message id, so the answer
    /// continues the existing turn rather than starting a new one — which is
    /// what the transcript looks like when it works, and what makes it obvious
    /// when the client has gotten it wrong.
    public func resolve(
        messageID: String,
        call: ToolCall,
        action: ToolCallAction,
        answers: JSONValue? = nil
    ) {
        guard let chat = chatID, !phase.isBusy,
              let index = turns.firstIndex(where: { $0.id == messageID })
        else { return }

        phase = .streaming
        error = nil
        // Mark the call answered locally first. The round trip takes a moment and
        // a still-tappable button invites a second tap, which the server answers
        // with a 409.
        turns[index].calls = turns[index].calls.map { entry in
            guard entry.callID == call.callID else { return entry }
            var answered = entry
            answered.status = action == .reject ? .rejected : .completed
            return answered
        }
        // The turn was flushed as final when the question arrived, so without
        // this the resumed run has no "still working" state to render and the
        // thinking animation never appears — the screen just sits there until
        // the answer lands.
        turns[index].streaming = true

        // Subscribe before the POST: the resumed run can emit before the
        // response comes back, and the socket does not replay.
        let frames = hub.frames(for: chat)
        // Issue #12: the same call-site capture discipline as #11. This Task is
        // not stored in `run` — a resume belongs to the run that parked, so
        // (like `stop`) it must NOT bump the generation; it carries the one it
        // was started under and stays inert once a send/edit/regenerate or an
        // abandon has superseded it. Without this, an abandon during a parked
        // resolve let the resolve's post-await writes — error/phase/leafID and
        // the `turns` mutations below — land on the *next* run's state.
        let gen = runGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolveToolCall(
                    chatID: chat, messageID: messageID, callID: call.callID,
                    action: action, answers: answers)
            } catch let error as APIError {
                // R1: superseded while the resolve POST was in flight. The
                // banner, the `.ready` and the 404 branch's refresh all
                // describe the abandoned run, not the one that owns the state
                // now.
                guard self.isCurrent(gen) else { return }
                // 404 "Tool call not found" after an answer almost never means
                // the answer was lost — it means the server already took it and
                // moved on, and this client was holding a stale card. The run
                // continues under the same message, so the honest response is
                // to look at the message, not to shout.
                //
                // A multi-question prompt made this routine: answering question
                // one settles the whole call, and the second tap for question
                // two lands on an id that no longer exists.
                if case .http(404, _) = error {
                    await self.refresh(messageID: messageID)
                    // R2: superseded during the refetch. Settling the old turn
                    // and moving the leaf back under it is a write to a
                    // transcript the new run owns.
                    guard self.isCurrent(gen) else { return }
                    if let index = self.turns.firstIndex(where: { $0.id == messageID }) {
                        self.turns[index].streaming = false
                    }
                    self.leafID = messageID
                    self.phase = .ready
                    return
                }
                self.error = error.localizedDescription
                self.phase = .ready
                return
            } catch {
                guard self.isCurrent(gen) else { return }  // R1 (same as above)
                self.error = error.localizedDescription
                self.phase = .ready
                return
            }
            // R3: superseded during the POST's success hop. `drain` is not a
            // read — it installs this run's buffer into the model-level
            // `pending`, and a stale resume installing its buffer over a newer
            // run's is exactly the buffer hijack #11 fixed for `exchange`
            // (the newer run's deltas would land in the abandoned turn).
            guard self.isCurrent(gen) else { return }
            var outcome = await self.drain(frames, assistantID: messageID, gen: gen, continuing: true)
            // R4: the mirror of exchange's G4. Everything from here — the
            // parked `.ready`, the refresh, `leafID`, the calls reconcile and
            // the error stamp — belongs to the run that owns the state now.
            guard self.isCurrent(gen) else { return }
            if outcome.parked {
                // Same as the first run: keep looking until the question has
                // actually landed, because nothing later will fix it.
                await self.awaitQuestion(messageID: messageID, gen: gen)
                guard self.isCurrent(gen) else { return }  // R5: superseded mid-refetch
                self.phase = .ready
                return
            }
            if !outcome.sawTerminal && outcome.failure == nil
                && self.turns.first(where: { $0.id == messageID })?.text.isEmpty ?? true {
                outcome.failure = outcome.reportedError ?? "The server sent nothing."
            }
            // The continuation after a tool answer is the case that started
            // this: the resumed run announces itself in a shape this client had
            // not learned, so the text arrived and was dropped, and the screen
            // sat on the pre-question text until you left and came back.
            // Reconciling against the stored message makes the answer correct
            // regardless of which frames we happened to understand.
            if outcome.failure == nil && !outcome.parked {
                await self.refresh(messageID: messageID)
                guard self.isCurrent(gen) else { return }  // R6: superseded during the refetch
                self.leafID = messageID
            }
            if !outcome.parked, let index = self.turns.firstIndex(where: { $0.id == messageID }) {
                self.turns[index].calls = Turn.reconciling(self.turns[index].calls, done: true)
            }
            if outcome.failure == nil, let reported = outcome.reportedError {
                let got = self.turns.first(where: { $0.id == messageID })?.text ?? ""
                if got.isEmpty { outcome.failure = reported }
            }
            if let failure = outcome.failure { self.error = failure }
            self.phase = .ready
            // Issue #37: answering a tool call is a run ending — the same turn
            // the exchange epilogue gets. The parked branch above returns early
            // and does not: a chat waiting on a question is not a chat that has
            // become free.
            self.settleQueue()
        }
    }

    /// Refetches until a parked question has actually arrived.
    ///
    /// A park is detected the moment the server says it is waiting, which is
    /// *before* the model has finished streaming the question's arguments — so
    /// the first refetch lands on a call with empty or truncated arguments and
    /// the card has nothing to render. Retrying with a short backoff is what
    /// closes that gap; the alternative, which this client used to do, was to
    /// show a question that could never be answered.
    ///
    /// Bounded, and it gives up into the free-text fallback rather than spinning:
    /// a "Preparing the question…" that never resolves is the same dead end with
    /// a nicer animation, and at least a text field can be typed into.
    private func awaitQuestion(messageID: String, gen: Int) async {
        mark(messageID, questionIncoming: true)
        defer { mark(messageID, questionIncoming: false) }
        for attempt in 0..<10 {
            // #27: stand down promptly once this run is superseded. The loop
            // is a long, uncancellable-in-practice await (a hung GET extends
            // it past every sleep), and since #25 nothing incidental wakes it
            // any more — pre-#25 a superseded POST failure's ungated
            // `hub.expire` finished the parked drain's listener by accident.
            // Without this guard a superseded park grinds through all ten
            // refetch attempts (~11s of sleeps, ten GETs, its hub subscriber
            // pinned by the still-live exchange frame) until the G5/R5 guard
            // drops it at the end. Cancellation covers the exchange side
            // (abandon's `run?.cancel()` — the swallowed `try?` sleep returns
            // immediately); `isCurrent` covers resolve's untracked twin,
            // which no cancel ever reaches. Same ownership idiom as G5/R5,
            // one level earlier: bail while the work is still pointless
            // instead of after it.
            guard isCurrent(gen), !Task.isCancelled else { return }
            await refresh(messageID: messageID)
            guard isCurrent(gen), !Task.isCancelled else { return }
            guard let turn = turns.first(where: { $0.id == messageID }),
                  let awaiting = turn.awaitingCall,
                  !awaiting.hasStructuredArguments
            else { return }
            try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        }
    }

    private func mark(_ messageID: String, questionIncoming: Bool) {
        guard let index = turns.firstIndex(where: { $0.id == messageID }) else { return }
        turns[index].questionIncoming = questionIncoming
    }

    /// Pulls the stored message back after a resumed run.
    ///
    /// The answer the model gives after a question is real and saved — the web
    /// UI shows it — but this client has never caught it live, and the frame
    /// shape of a resumed run is not worth guessing at: a guess works until the
    /// server changes and then fails quietly. One GET is always right, and the
    /// comparison is by length so a partial live stream is only ever replaced by
    /// something more complete, never by less.
    private func refresh(messageID: String) async {
        guard let chat = chatID,
              let detail = try? await client.chat(id: chat),
              let message = detail.messages[messageID]
        else { return }
        self.detail = detail
        apply(message, to: messageID)
    }

    /// Copies a stored message onto the turn of the same id, growing only.
    private func apply(_ message: ChatMessage, to messageID: String) {
        guard let index = turns.firstIndex(where: { $0.id == messageID }) else { return }
        let fresh = Turn(message)
        var turn = turns[index]
        if fresh.text.count > turn.text.count { turn.text = fresh.text }
        if fresh.reasoning.count > turn.reasoning.count { turn.reasoning = fresh.reasoning }
        if !fresh.calls.isEmpty { turn.calls = fresh.calls }
        if !fresh.sources.isEmpty { turn.sources = fresh.sources }
        if !fresh.attachments.isEmpty { turn.attachments = fresh.attachments }
        turn.usage = fresh.usage ?? turn.usage
        // The stored message is the authority on how the run ended. If it is
        // settled and we are still showing a spinner, the live stream missed
        // the ending and there is nothing more coming.
        if message.done { turn.streaming = false }
        turns[index] = turn
    }

    /// Poll the stored message until the server has closed it.
    ///
    /// The stream is an optimisation; the stored message is the truth. A run that
    /// ends in the app before the server has finished writing is the worst
    /// failure this client can have: the answer looks finished, the composer
    /// unlocks, and the rest of it only appears after you leave the chat and
    /// come back. That report came in repeatedly, and every attempt to fix it by
    /// interpreting the stream more cleverly has failed, because the frames
    /// disagree with the record in more ways than one — a run can pause on a
    /// question, continue after a tool call, or simply outlive the socket.
    ///
    /// So this stops interpreting and starts checking. After a run, and whenever
    /// a chat opens onto a message the server still has open, it re-reads the
    /// record until one of three things is true:
    ///
    ///   * the message is `done` — the run is over;
    ///   * a tool call is waiting on the user — parked is a correct end state,
    ///     and polling it away would hide the question again;
    ///   * the budget runs out, which means the server really did stop.
    ///
    /// Two seconds is slow enough to be invisible and fast enough that a
    /// continuation lands before the user has looked away. Five minutes is
    /// longer than any run seen here.
    /// What to say when a run ends with no answer.
    ///
    /// Three different situations used to produce one message, and one of them
    /// was a false accusation: iOS kills the socket on a background sojourn, so
    /// an unfinished message on the server means the answer is still coming and
    /// the thing that failed was our connection, not the model.
    nonisolated static func emptyAnswerFailure(reported: String?, serverStillWriting: Bool) -> String {
        if let reported { return reported }
        return serverStillWriting
            ? "Still working — the connection dropped. Keep this chat open, or pull to refresh."
            : "The server sent nothing."
    }

    private func reconcileUntilClosed(messageID: String) async {
        guard let chat = chatID else { return }
        // A chat abandoned server-side — browser closed mid-run, worker died —
        // keeps `done: false` forever. Polling that for five minutes would show a
        // spinner on a dead chat, which is its own bug. So growth is the signal:
        // if neither the answer nor the reasoning has moved in half a minute,
        // nothing is coming.
        // Which run this reconcile is watching for. The rebuild below is the
        // one write in this loop that replaces `turns` wholesale, so it has to
        // refuse to run once this watch has been superseded (a stop, a new run)
        // — that newer run's local placeholder rows are not in any server tree
        // yet, and rebuilding would delete them. The per-message `apply` is
        // id-keyed and grow-only, so it never needed this.
        let gen = runGeneration
        var watch = RunWatch(stallLimit: reconcileStallLimit)
        // How many ticks an open tool call has been allowed to buy. Without a
        // cap a call that never settles in the record — the server moved on, the
        // worker died, the status string means something we have not seen —
        // holds the run "working" for the whole budget, which is five minutes of
        // spinner on an answer that finished in nine seconds.
        var toolGrace = 0
        for _ in 0..<reconcileBudget {
            guard let detail = try? await client.chat(id: chat) else {
                // A failed read says nothing about the run, so it must not end
                // the reconciliation — the next tick may be fine.
                try? await Task.sleep(for: reconcileInterval)
                continue
            }
            // Stop if the user started something else while we were waiting.
            guard phase == .streaming || phase == .stopping else { return }
            self.detail = detail
            guard let message = detail.messages[messageID] else { return }
            if turns.firstIndex(where: { $0.id == messageID }) != nil {
                apply(message, to: messageID)
            } else if isCurrent(gen) {
                // Issue #19: the server has the message but the local array
                // lost the row — the classic shape is a mid-run reload whose
                // tree did not contain the streaming assistant yet (the
                // server writes the message as the run goes). flush skips
                // every write for an absent id (#14, correct), and
                // `apply(message, to:)` only grows rows that exist, so
                // without this nothing in the session re-attached the row and
                // a visibly-live run showed nothing until you left the chat
                // and came back. Rebuilding from the detail is the same
                // wholesale `apply` load() already does — safe mid-run since
                // #14 because every stream write resolves its destination by
                // id at write time — and it places the row at the
                // tree-correct position for free, converging the whole
                // transcript rather than just the one row.
                apply(detail)
            }
            if message.done { return }
            if Turn(message).calls.contains(where: \.isAwaitingUser) {
                // The run is waiting on a tap, not on the server. Show the
                // question and stop watching.
                turns.firstIndex(where: { $0.id == messageID }).map {
                    turns[$0].streaming = false
                }
                return
            }
            // A tool that is running produces no text and no new output items,
            // so the size-based stall below would fire while Sonos was still
            // fetching — and an empty answer at that point became "the server
            // sent nothing". An unsettled call is proof of life: keep waiting
            // and forget the stall clock.
            if toolGrace < toolAliveTicks, Turn(message).calls.contains(where: { !$0.isSettled }) {
                toolGrace += 1
                watch = RunWatch(stallLimit: reconcileStallLimit)
                try? await Task.sleep(for: reconcileInterval)
                continue
            }
            if watch.observe(size: message.content.text.count + message.output.count) {
                // Nothing has moved in half a minute. Leave the answer on screen
                // and hand the composer back rather than spin over a dead run.
                turns.firstIndex(where: { $0.id == messageID }).map {
                    turns[$0].streaming = false
                }
                return
            }
            try? await Task.sleep(for: reconcileInterval)
        }
    }

    /// Tuning for `reconcileUntilClosed`, split out so the stall behaviour is
    /// testable without a test that waits half a minute.
    /// Two minutes of grace for an unsettled tool call: long enough for a slow
    /// Notion fetch, short enough that a call which never settles does not leave
    /// the chat pretending to work for five minutes.
    var toolAliveTicks = 60
    var reconcileInterval: Duration = .seconds(2)
    var reconcileStallLimit = 15
    var reconcileBudget = 150

    /// Tuning for the drain flush timer, same reasoning as `reconcileInterval`:
    /// a test that has to prove the flusher did *not* tick cannot sit out a
    /// 60 ms timer, so the interval is an instance knob. The static stays the
    /// production default.
    var flushInterval: Duration = ConversationModel.flushInterval

    /// Issue #24: typewriter reveal step, in graphemes per flush tick.
    /// Nil disables the reveal (every tick publishes the whole buffer, the
    /// pre-#24 behaviour). The default advances the published prefix by at
    /// most `max(revealStep, backlog/4)` graphemes per tick — bursts of
    /// several words become a smooth flow, and the proportional catch-up
    /// keeps the visible text roughly a quarter-second behind the server no
    /// matter how bursty the arrival. The final flush of a run (done, stop,
    /// error, tool park) always publishes the complete text, so the reveal
    /// can never hide or lose a word; that ordering is the same one 60ccb0c
    /// established for the buffer-before-ready publish.
    /// An instance knob for the same reason as `flushInterval`: a test has
    /// to pin pacing without waiting on wall-clock timing twice over.
    var revealStep: Int? = 3

    /// Tuning for the drain's silence watchdog, same reasoning as
    /// `flushInterval`: a test that has to prove a stale watchdog did *not*
    /// fire cannot sit out a 60 s timer, so the limit is an instance knob.
    /// The static stays the production default. The budget is read when a
    /// timer is (re-)armed — install and every per-frame re-arm — so a test
    /// that wants a short watchdog should set this before the run starts;
    /// a mid-run change only takes effect at the next re-arm.
    var silenceLimit: Duration = ConversationModel.silenceLimit

    /// Tuning for the #42 run ceiling, same reasoning as `silenceLimit`: a
    /// test has to prove the ceiling fired (and that a healthy run did not
    /// meet it) without sitting out fifteen minutes. The static stays the
    /// production default; the budget is read once when the drain installs
    /// the timer, so set it before the run starts.
    var runCeiling: Duration = ConversationModel.runCeiling

    /// A failed POST is reported only if the run has not already ended on its own
    /// terms — a stream closed by `stop()` errors on the way out, and calling
    /// that a failure would be a lie the user cannot act on.
    ///
    /// `gen` is the generation the caller's exchange was started under, and the
    /// first gate is ownership (#25). This is the event-driven path the #21
    /// timer gates cannot cover: the POST's catch fires whenever the POST dies,
    /// and a superseded run's late failure would pass `phase.isBusy` on the
    /// NEWER run's busy phase — stamping its banner, arming the #9 rollback for
    /// a send the newer run never made, and expiring the newer run's hub
    /// listener. `Task.isCancelled` at the call site covers a same-gen
    /// retirement (the slot owner cancelled the task); this covers cross-gen
    /// supersession. Since #19/#26 closed the mid-run `load()` supersede hole
    /// and `abandon` cancels the POST (whose catch then self-silences on
    /// `Task.isCancelled`), no reachable path leaves an uncancelled stale POST
    /// any more — the guard is defense-in-depth for the next supersede path,
    /// not a live unblock. `runGeneration` is monotonic, so the equality check
    /// is the whole ownership test; no second gate is needed.
    private func recordPostError(_ error: Error, gen: Int) {
        guard isCurrent(gen) else { return }
        guard phase.isBusy else { return }
        let message: String
        if let api = error as? APIError, api.isUnauthorized { message = "Signed out." }
        else { message = error.localizedDescription }
        self.error = message
        // Issue #9: a POST that dies before the first frame means the exchange
        // never reached the server, and `exchange` needs to know that — by
        // message, because the banner above will be overwritten by the drain's
        // own guess — so it can roll the send back.
        if phase == .waiting {
            postFailureMessage = message
            // #38: set in the same breath as the message and under the same
            // gate, because the outbox arm of the #9 fork asks this flag and
            // only ever asks it alongside the message. Anywhere they could be
            // set apart is a place a non-transient failure gets captured.
            postFailureIsTransient = (error as? APIError)?.isTransient ?? true
            // Unblock the drain: nothing will ever arrive on this run's
            // listener now. An existing chat's listener is keyed by id, and
            // `expire(chatID:)` reaches it. A new chat's listener is the
            // pre-id one — #36 made it addressable by the token this model
            // installed, so a failed first message ends exactly it (the old
            // global sweep needed #9's `chatID == nil` gate to avoid
            // expiring OTHER conversations' pending new-chat listeners;
            // that hazard is structurally gone). Without this the drain sat
            // out the 60 s silence watchdog and then reported
            // "The server sent nothing."
            if let chat = chatID {
                hub.expire(chatID: chat)
            } else if let token = waitingToken {
                hub.expire(waitingToken: token)
            }
            if let token = waitingToken {
                hub.expire(waitingToken: token)
                waitingToken = nil
            }
        }
    }

    /// Text accumulated from the socket but not yet published.
    @ObservationIgnored private var pending: Turn?

    /// Publishes whatever has arrived. Runs on the flush timer, so it must not
    /// invent a turn if the run has already been replaced (a regenerate, say).
    /// The index the callers used to pass is gone on purpose (issue #14):
    /// `flush` resolves the destination by id at write time, so a mid-run
    /// `load()` rebuilding `turns` cannot redirect this write to another turn.
    private func publishPending(keeping id: String) {
        guard let pending, pending.id == id else { return }
        flush(pending)
    }

    /// One typewriter tick (#24): advance the published prefix of the pending
    /// buffer toward its full text and return the new cursor. With the knob
    /// unset this is exactly the old `publishPending` — full buffer, cursor
    /// parked at the end — so setting the knob to nil restores the pre-#24
    /// path byte-for-byte.
    /// Ownership is unchanged: the write goes through `flush`, which resolves
    /// the destination by message id at write time (#14), and a buffer that
    /// is no longer this run's returns the cursor untouched (#11/#16).
    private func revealTick(keeping id: String, from cursor: Int) -> Int {
        guard let pending, pending.id == id else { return cursor }
        let full = pending.text.count
        guard let step = revealStep, cursor < full else {
            flush(pending)
            return full
        }
        // Proportional catch-up: a burst is smoothed to `step` per tick while
        // small, and a backlog that keeps growing drains at a quarter per
        // tick, so the reveal trails the server by roughly a quarter-second
        // and always converges before the answer ends.
        let advance = max(step, (full - cursor) / 4)
        let target = min(full, cursor + advance)
        var shown = pending
        shown.text = String(pending.text.prefix(target))
        flush(shown)
        return target
    }

    /// Publishes buffered text. Only touches `turns` on a flush, so the view
    /// diffs at ~16 Hz instead of once per token.
    ///
    /// The destination is resolved by message id at write time, never by a
    /// captured array index (issue #14). A pull-to-refresh mid-run calls
    /// `load()`, which neither bumps the generation nor cancels the run, and
    /// `apply` rebuilds `turns` wholesale — a server tree with more or fewer
    /// turns than the local array shifts everything a captured integer pointed
    /// at, and the next flush wrote the WRONG turn (an older answer overwritten
    /// with this run's deltas). The id cannot shift.
    ///
    /// When the id is gone — a reload whose server tree does not contain this
    /// message (yet) — the write is skipped silently, for this run and every
    /// later flush until something puts the turn back. The reloaded tree is
    /// canonical, and appending here would invent a turn the server tree does
    /// not have mid-run, twice over if the reload lands again. What puts the
    /// row back is `reconcileUntilClosed`: when its detail has the message but
    /// `turns` lacks the row, it rebuilds from the detail (issue #19), so a
    /// dropped row converges without leaving the chat. The `firstIndex` scan
    /// runs once per flush tick (~16 Hz), not per frame; transcript arrays are
    /// tens of entries, so the scan is noise.
    private func flush(_ source: Turn, final: Bool = false) {
        guard let at = turns.firstIndex(where: { $0.id == source.id }) else { return }
        var turn = turns[at]
        turn.text = source.text
        turn.reasoning = source.reasoning
        turn.usage = source.usage ?? turn.usage
        turn.model = source.model ?? turn.model
        turn.error = source.error
        // A parked call has to survive the flush or the question vanishes the
        // moment it arrives, which is worse than never showing it: the user sees
        // the answer stop and has no idea why.
        if !source.calls.isEmpty { turn.calls = source.calls }
        if !source.sources.isEmpty { turn.sources = source.sources }
        turn.streaming = final ? false : turn.streaming
        turns[at] = turn
        if !final && (!source.text.isEmpty || !source.reasoning.isEmpty), phase.isBusy {
            phase = .streaming
        }
    }

    /// The chat has to exist before the completion is sent, and a brand-new
    /// conversation does not exist until this returns.
    private func ensureChat(named text: String) async throws -> String {
        if let chatID, !incognito { return chatID }
        if incognito {
            // No POST /chats/create: a chat record is the thing incognito
            // promises not to leave behind. The id is derived, not allocated.
            guard let temporary = temporaryChatID else {
                throw APIError.unreachable("Waiting for the connection to open.")
            }
            chatID = temporary
            return temporary
        }
        // The server only names a chat it created itself. Allocating the id here
        // and POSTing /chats/new first made every app chat look like an existing
        // one, and that is the exact test the server uses to decide whether to
        // generate a title — so app chats kept a truncated first line while
        // browser chats got a summary. The first message now goes out with no id
        // and the real one is adopted from the stream.
        title = Self.title(from: text)
        titleIsPlaceholder = true
        return Self.awaitingChatID
    }

    /// True while the only name this chat has is the one the app made up from the
    /// first message. Cleared the moment the server supplies a real one, so a
    /// generated summary is never overwritten by the placeholder.
    private var titleIsPlaceholder = false

    /// Stand-in for "the server has not told us the id yet".
    static let awaitingChatID = "__awaiting__"

    /// Takes the id the server chose, once.
    private func adopt(chatID: String) {
        guard self.chatID == nil else { return }
        // #34: the callback only ever means "my live run's chat just got
        // named". A stop on a brand-new chat discards the chat and settles
        // the phase; a frame that arrived *before* the stop can still queue
        // this hop, and adopting then would hand the discarded model a real
        // id — the next load() would resurrect the phantom chat into the
        // empty transcript. Only a busy model still owns a run to adopt for.
        guard phase.isBusy else { return }
        self.chatID = chatID
        // Issue #37: the chat now has a name, so its queue moves onto it. Until
        // this moment a new chat's queued messages live under a stand-in key of
        // this model's own; leaving them there would mean they belong to no chat
        // anybody can open.
        rekeyQueue()
        // Issue #20: a brand-new chat raised its ribbon with no owner (there
        // was no id yet), and an unclaimed ribbon matches *any* finish — any
        // other chat's run ending could close it. The moment this chat has a
        // real id, upgrade the token so only this run can close its ribbon.
        // `claim` is only-while-nil, so if another chat's ribbon is live
        // (this chat's `start` no-oped) the claim cannot steal it.
        //
        // Chained onto the raise, not fired on the spot: on iOS `start`
        // suspends inside `Activity.request`, and the frame that carries the
        // adopted id can arrive first — claiming before the raise lands would
        // no-op (no ribbon yet) and then be written over by the raise's own
        // (nil) token. Awaiting the raise makes the order deterministic.
        //
        // The claim is staleness-gated (issue #20 review): a slow
        // `Activity.request` can land after this run already finished (fast
        // offline failure: finish no-ops on the nil activity, then the raise
        // finally strands a ribbon). Claiming that orphan would make it
        // owned-by-a-dead-run — worse than nil-owned, which any later finish
        // could clear. If this run no longer owns the model (generation
        // bumped) or is no longer busy, the ribbon it left behind is not
        // worth protecting. The gate also stops a late claim from this chat
        // stamping a *different* chat's freshly raised, still-unclaimed ribbon.
        let gen = runGeneration
        let raise = ribbonRaise
        Task { @MainActor [weak self] in
            await raise?.value
            guard let self, self.runGeneration == gen, self.phase.isBusy else { return }
            self.activity.claim(chatID: chatID)
        }
        // Deliberately no title write here. The server is generating a summary for
        // this chat right now; naming it from the client at this moment is a race
        // the client loses, and losing means a good title gets replaced by the
        // first 40 characters of the question. The fallback lives in
        // `awaitGeneratedTitle`, which only runs once the summary has failed to
        // turn up.
    }

    static func title(from text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Chat" : String(trimmed.prefix(40))
    }

    /// The thread in the shape the completion endpoint wants: oldest first, each
    /// message pointing at its parent. The message being (re)asked is included
    /// with the caller's text, since locally it is still the empty placeholder or
    /// the previous answer's text.
    /// The system prompt, as the server wants it.
    ///
    /// Not as `params.system`. That key is read from the *model's* admin-configured
    /// params (`routers/openai.py`: `params = model_info.params.model_dump()`, then
    /// `params.pop('system')`); a value a client sends there is merged into
    /// `form_data['params']` and recorded in `chat_context` for background runs,
    /// but it never reaches the prompt. The carrier is a `system` role message in
    /// `messages` — `utils/middleware.py` takes `get_system_message(form_data['messages'])`
    /// and puts it in front of the history it rebuilds from the chat tree. Sending
    /// it anywhere else looks correct on the wire and does nothing, which is
    /// exactly how it behaved.
    nonisolated static func systemPrefixed(_ history: [CompletionRequest.WireMessage],
                               prompt: String) -> [CompletionRequest.WireMessage] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !history.contains(where: { $0.role == "system" }) else {
            return history
        }
        return [CompletionRequest.WireMessage(id: UUID().uuidString, role: "system",
                                              content: .text(trimmed))]
            + history
    }

    private func wireHistory(through userMessageID: String, content: MessageContent)
        -> [CompletionRequest.WireMessage]
    {
        var out: [CompletionRequest.WireMessage] = []
        var parent: String?
        for turn in turns {
            let message: CompletionRequest.WireMessage?
            if turn.id == userMessageID {
                message = .init(
                    id: turn.id, role: "user", content: content, parentID: parent, model: model)
            } else if turn.isAssistant, !turn.text.isEmpty, !turn.streaming {
                message = .init(
                    id: turn.id, role: "assistant", content: .text(turn.text), parentID: parent,
                    model: turn.model ?? model)
            } else if turn.isUser, !turn.text.isEmpty {
                message = .init(
                    id: turn.id, role: "user", content: .text(turn.text), parentID: parent, model: model)
            } else {
                message = nil
            }
            if let message {
                out.append(message)
                parent = message.id
            }
        }
        return out
    }
}

/// The offer the image guard makes when a send is refused for crossing the
/// per-request image budget and the excess is in persisted messages the client
/// can rewrite (issue #2). Carries everything the confirmation dialog needs:
/// the numbers, and one preview line per message that will lose its images.
public struct ImageTrimOffer: Equatable, Sendable {
    /// One message the trim will rewrite, oldest-first in the offer's list.
    public struct Target: Equatable, Sendable {
        public let messageID: String
        /// How many images this message currently contributes — all of them
        /// go, because the trim rewrites a message wholesale.
        public let dropCount: Int
        /// One line describing the message (first text line or an
        /// image-only label, plus its date) for the confirm dialog.
        public let preview: String
    }

    /// The projected image count when the offer was made (persisted images
    /// plus the pending send and any uploads still on the wire).
    public let imagesInChat: Int
    /// The cap the projection crossed.
    public let cap: Int
    /// Total images the trim will drop — the N in "Remove N oldest images".
    public let dropTotal: Int
    /// The messages the trim will rewrite, oldest-first.
    public let targets: [Target]

    /// The confirm dialog's body: the preview the AC asks for — which images
    /// (messages, dates) will be replaced with a placeholder. There is no
    /// undo (these are server mutations); this gate is what satisfies that
    /// requirement.
    public var confirmationMessage: String {
        let lines = targets.map { "• \($0.preview)" }.joined(separator: "\n")
        return "The \(dropTotal) oldest images will be replaced with a placeholder:\n\(lines)"
    }
}
