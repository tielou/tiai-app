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
    /// Takes the error banner away. Errors used to clear themselves on the next
    /// send or on the next successful run, which is fine for a failure that
    /// fixes itself but not for one the user has already read — a banner that
    /// outlives its meaning is noise, and the dismiss affordance has to be
    /// honest about what it dismisses (issue #9).
    public func dismissError() { error = nil }
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

    /// How long to wait on a silent stream before calling it dead. Longer than
    /// the slowest cold prefill you have seen, shorter than someone's patience.
    static let silenceLimit: Duration = .seconds(60)
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
        func key(for url: String) -> String {
            let prefix = "file_id://"
            return url.hasPrefix(prefix) ? String(url.dropFirst(prefix.count)) : url
        }
        var total = 0
        for turn in turns {
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
            total += count
        }
        return total + outgoing.filter(\.isImage).count
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
        guard count > Self.maxImagesPerRequest else { return nil }
        let subject = outgoing.contains(where: \.isImage) || inFlight > 0
            ? "This message would send \(count) images"
            : "This chat already contains \(count) images"
        return "\(subject) — the model can see at most \(Self.maxImagesPerRequest) per request. Start a new chat to keep using images."
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

    /// The chat id a temporary run uses, or nil until the socket has one.
    private var temporaryChatID: String? {
        hub.sessionID.map { "temporary:\($0)" }
    }

    /// The Live Activity ribbon. Defaults to the process singleton — one
    /// ribbon app-wide — but is injectable so tests can drive two models that
    /// share one ribbon without racing every other test's use of `.shared`.
    private let activity: GenerationActivity

    public init(
        chatID: String?,
        title: String = "New Chat",
        models: [ChatModel] = [],
        incognito: Bool = false,
        client: OWUIClient,
        hub: ChatEventHub,
        activity: GenerationActivity = .shared
    ) {
        self.incognito = incognito
        self.chatID = chatID
        self.title = title
        self.client = client
        self.hub = hub
        self.activity = activity
        self.models = models
        modelIDs = models.map(\.id)
        model = models.first?.id ?? ""
        features = Self.seedFeatures(for: models.first, incognito: incognito)
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
        if features.isEmpty { features = Self.seedFeatures(for: models.first, incognito: incognito) }
    }

    /// Called when the model changes: the defaults belong to the model, so the
    /// toggles have to follow it rather than keep the previous model's settings.
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

    public func load() async {
        guard let chatID else { return }
        // A temporary chat has no history to fetch — that is the whole point —
        // and asking for one is a guaranteed 404 on an id the server never
        // stored, which would put a red error banner on a perfectly good chat.
        if incognito || chatID.hasPrefix("temporary:") || chatID.hasPrefix("local:") {
            phase = .ready
            return
        }
        let cacheKey = DiskCache.key("chat-\(chatID)",
                                     host: client.server.baseURL.host ?? "local")
        // Cached first. Opening a chat used to be a blank screen for the length
        // of a round trip, which is the single thing that most makes the app feel
        // slow — the transcript is already on the phone from the last time you
        // read it. The network then replaces it, and a failure leaves the cached
        // transcript on screen instead of trading it for an error banner.
        if let cached = DiskCache.load(ChatDetail.self, key: cacheKey) {
            apply(cached)
            phase = .ready
        } else {
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
            if let last = turns.last, !last.isUser,
               let stored = detail.messages[last.id], stored.done != true {
                phase = .streaming
                Task {
                    await self.reconcileUntilClosed(messageID: last.id)
                    // Only hand the composer back if nothing else took it while
                    // we were watching — a send started mid-heal owns the phase.
                    if case .streaming = phase, post == nil { phase = .ready }
                }
            } else {
                phase = .ready
            }
        } catch {
            // Only worth complaining about when there is nothing to show. With a
            // cached transcript on screen, a dead network should keep the screen
            // as it is, not replace readable messages with a red banner.
            if detail == nil { self.error = error.localizedDescription }
            phase = .ready
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
        guard !phase.isBusy else {
            error = "Wait for the current answer to finish before adding attachments."
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
        guard !(text.isEmpty && attachments.isEmpty && !uploading), !phase.isBusy, phase != .loading
        else { return }
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
        draft = ""
        error = nil
        // Set here rather than inside the task: the button's feedback should not
        // wait for a scheduling hop, and a caller that then awaits something
        // conditioned on the phase would otherwise race the run it just started.
        phase = .waiting
        runGeneration += 1
        let gen = runGeneration
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
        run = Task {
            // Taken *after* the wait, because until the upload answers there is
            // no file id to take.
            let uploadsTimedOut = await self.waitForUploads()
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
            let sawNewFailure = uploadFailureCount > uploadFailuresAtLastSend
            uploadFailuresAtLastSend = uploadFailureCount
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
                // this task already runs on the main actor.
                await ribbon.value
                await activity.finish(.stopped, characters: 0, chatID: chatID)
                return
            }
            let files = self.attachments
            self.attachments = []
            await self.exchange(text: text, regenerating: nil, files: files, gen: gen)
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
    public func stop() {
        guard let chatID, phase.isBusy else { return }
        // A stop belongs to the run it stops: capture the generation, never bump
        // it. If a newer run starts while the stop POST is in flight, the slow
        // stop must not come back and finish *that* run (issue #5).
        let gen = runGeneration
        userStopped = true
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
        }
    }

    /// Ends the run in the app, whatever the server does next.
    private func finishLocally(chatID: String, gen: Int) {
        guard gen == runGeneration else { return }
        run?.cancel()
        post?.cancel()
        post = nil
        hub.expire(chatID: chatID)
        // A brand new chat may still be waiting for its id when stop is pressed.
        hub.expireWaitingListeners()
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
        if let index = turns.lastIndex(where: \.isAssistant) { turns[index].streaming = false }
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

    private func exchange(text: String, regenerating: String?, files: [PendingAttachment], gen: Int) async {
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

        let userMessageID = regenerating ?? UUID().uuidString
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
        // first one it hears a frame for.
        let frames = newChat
            ? hub.framesAwaitingChatID { [weak self] id in
                Task { @MainActor in self?.adopt(chatID: id) }
            }
            : hub.frames(for: chat)
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
        post = Task {
            do { try await self.client.stream(request).drain() }
            catch {
                // The normal end of a run cancels this task while the POST is
                // still open — the completion stays in flight until the server
                // closes it — and the cancellation surfaces as a throw here.
                // Recording it stamped a spurious error onto a run that had
                // just finished, and (issue #9) could set the rollback flag of
                // the *next* run through the shared `phase.isBusy` guard.
                if Task.isCancelled { return }
                self.recordPostError(error)
            }
        }

        var outcome = await drain(frames, assistantID: assistantID)
        // G4 — the core of issue #11. A superseded run returning from its drain
        // must not cancel the *next* run's POST slot, roll its transcript back,
        // or drive its phase. The early return covers the whole post-drain
        // cluster: slot writes, `leafID`, the #9 rollback block, and the parked
        // `.ready` branch.
        guard isCurrent(gen) else { return }
        post?.cancel()
        post = nil

        if outcome.parked {
            // The run is parked on a question, not finished. `leafID` stays where
            // it was: the answer this turn is still owed, and resending would
            // fork the chat instead of continuing it.
            //
            // And refetch until the question is there. Unlike a finished
            // answer, a parked question is never corrected later: the run is
            // stopped until the user answers, so a question that came through
            // unreadable has nothing that will ever fix it.
            await awaitQuestion(messageID: assistantID)
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
        if let message = postFailureMessage, regenerating == nil,
           phase == .waiting, !outcome.sawAnyFrame {
            postFailureMessage = nil
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
            if draft.isEmpty { draft = text; restoredDraft = true }
            // `!files.isEmpty`: a text-only send has nothing to put back —
            // claiming "Attachments are back" for an empty list would be the
            // same lie the separate flags exist to prevent.
            if attachments.isEmpty, !files.isEmpty { attachments = files; restoredAttachments = true }
            // "Could not send — Signed out." reads wrong; the 401 already
            // has its own plain sentence, so it stands alone.
            var banner = message == "Signed out." ? message : "Could not send — \(message)."
            if restoredDraft { banner += " It's back in the composer." }
            else if restoredAttachments { banner += " Attachments are back; re-type and send again." }
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
                    // "The server sent nothing" is an accusation, and it was
                    // being made about the wrong party. iOS kills the socket on
                    // a background sojourn; if the server record still says the
                    // message is unfinished, the answer is on its way and the
                    // thing that failed was our connection. Saying so is the
                    // difference between a bug report and a dead end.
                    outcome.failure = Self.emptyAnswerFailure(
                        reported: outcome.reportedError,
                        serverStillWriting: detail?.messages[assistantID].map { !$0.done } ?? false)
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
        phase = .ready
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

    /// Drains frames for one assistant message until the run ends, is stopped,
    /// or parks on a tool call.
    ///
    /// Shared by sending and by resuming, because resolving a tool call starts a
    /// *new* completion on the server whose tokens arrive under the same
    /// assistant message id — the client has to listen again exactly as it did
    /// the first time, and a second copy of this loop is how the two would drift.
    private func drain(
        _ frames: AsyncStream<ChatEventSocket.Frame>,
        assistantID: String,
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
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.flushInterval ?? Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.publishPending(keeping: assistantID)
            }
        }
        let watchdog = Task { [hub] in
            try? await Task.sleep(for: Self.silenceLimit)
            // Cancellation must stand the watchdog down, not fire it — the
            // same `if !Task.isCancelled` gate the grace tasks below use.
            // Without it, `try?` swallows the cancellation this task gets at
            // the end of every drain and `expire` runs immediately, finishing
            // EVERY listener for the chat — including a newer run's, when an
            // abandoned run's drain unwinds after that newer run subscribed
            // (issue #11). The listener this run installed is cleaned up
            // anyway when `exchange` drops the stream.
            guard !Task.isCancelled else { return }
            hub.expire(chatID: chatID ?? "")
        }

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
            // `break`, not `continue`, because a half-dead drain's 60 s
            // silence watchdog is not generation-gated: left iterating it
            // would later fire `hub.expire(chatID:)` on the shared chatID and
            // kill the NEWER run's listener. Breaking also reaches the
            // watchdog/grace/flusher cancels below the loop and unregisters
            // the hub subscriber via the stream's `onTermination`; the final
            // flush is already id-gated, so nothing stale flushes here (the
            // #11 fix).
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
                // stored. The silence watchdog stays as the outer limit.
                if pending?.awaitsTool == true
                    || (sawToolArguments && pending?.calls.isEmpty != false) {
                    sawToolArguments = false
                    grace = Task { [hub] in
                        try? await Task.sleep(for: Self.handoffLimit)
                        if !Task.isCancelled { hub.expire(chatID: chatID ?? "") }
                    }
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
                    grace = Task { [hub] in
                        try? await Task.sleep(for: Self.errorRecoveryLimit)
                        if !Task.isCancelled { hub.expire(chatID: chatID ?? "") }
                    }
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
                if let chat = chatID, await serverStillOpen(chatID: chat, messageID: assistantID) {
                    grace = Task { [hub] in
                        try? await Task.sleep(for: Self.handoffLimit)
                        if !Task.isCancelled { hub.expire(chatID: chat) }
                    }
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
            Task { @MainActor [weak self] in
                for attempt in 0..<(owesFile ? 5 : 1) {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                    guard let model = self else { return }
                    if await ConversationModel.adoptStoredMessage(
                        model, client: api, chat: chat, id: id, streamed: streamed)
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
    private static func adoptStoredMessage(
        _ model: ConversationModel, client: OWUIClient, chat: String,
        id: String, streamed: String
    ) async -> Bool {
        guard let detail = try? await client.chat(id: chat),
            let stored = detail.messages[id],
            let at = model.turns.firstIndex(where: { $0.id == id })
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
            var outcome = await self.drain(frames, assistantID: messageID, continuing: true)
            // R4: the mirror of exchange's G4. Everything from here — the
            // parked `.ready`, the refresh, `leafID`, the calls reconcile and
            // the error stamp — belongs to the run that owns the state now.
            guard self.isCurrent(gen) else { return }
            if outcome.parked {
                // Same as the first run: keep looking until the question has
                // actually landed, because nothing later will fix it.
                await self.awaitQuestion(messageID: messageID)
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
    private func awaitQuestion(messageID: String) async {
        mark(messageID, questionIncoming: true)
        defer { mark(messageID, questionIncoming: false) }
        for attempt in 0..<10 {
            await refresh(messageID: messageID)
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
            apply(message, to: messageID)
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

    /// A failed POST is reported only if the run has not already ended on its own
    /// terms — a stream closed by `stop()` errors on the way out, and calling
    /// that a failure would be a lie the user cannot act on.
    private func recordPostError(_ error: Error) {
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
            // Unblock the drain: nothing will ever arrive on this run's
            // listener now. An existing chat's listener is keyed by id, and
            // `expire(chatID:)` reaches it. A new chat's `framesAwaitingChatID`
            // listener has chatID nil, which `expire(chatID: "")` never
            // matches, so it needs `expireWaitingListeners` — without it that
            // drain sat out the 60 s silence watchdog and then reported
            // "The server sent nothing." But the sweep is global and the hub
            // is shared per server (`SessionStore`): firing it on an existing
            // chat's failure would expire OTHER conversations' pending
            // new-chat listeners, so it runs only in the one case that needs
            // it — the nil-chatID listener of a brand-new chat.
            hub.expire(chatID: chatID ?? "")
            if chatID == nil { hub.expireWaitingListeners() }
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
    /// later flush until some reload puts the turn back. The reloaded tree is
    /// canonical, and `apply(message, to:)`/`adoptStoredMessage` grow turns
    /// that exist but never re-add a missing one — the streamed text is safe
    /// on the server and the next reload shows it, but nothing in this
    /// session re-attaches the row (filed: reconcile should insert a turn the
    /// server has and `turns` lacks). Appending here would invent a turn the
    /// server tree does not have mid-run, twice over if the reload lands
    /// again. The `firstIndex` scan runs once per flush tick (~16 Hz), not per
    /// frame; transcript arrays are tens of entries, so the scan is noise.
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
        self.chatID = chatID
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
