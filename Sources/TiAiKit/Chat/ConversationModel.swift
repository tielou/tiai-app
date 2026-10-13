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
    /// The message the next reply will be filed under. Tracked explicitly rather
    /// than derived from `turns`, because "the last thing in the tree" is exactly
    /// the thing regenerate and edit change.
    private var leafID: String?

    /// How long to wait on a silent stream before calling it dead. Longer than
    /// the slowest cold prefill you have seen, shorter than someone's patience.
    static let silenceLimit: Duration = .seconds(180)
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

    public init(
        chatID: String?,
        title: String = "New Chat",
        models: [ChatModel] = [],
        incognito: Bool = false,
        client: OWUIClient,
        hub: ChatEventHub
    ) {
        self.incognito = incognito
        self.chatID = chatID
        self.title = title
        self.client = client
        self.hub = hub
        self.models = models
        modelIDs = models.map(\.id)
        model = models.first?.id ?? ""
        features = Self.seedFeatures(for: models.first, incognito: incognito)
    }

    /// The toggles a model starts a chat with.
    ///
    /// The server's own defaults first, so a model configured for web search
    /// starts with it on. Then memory, which the server leaves off unless the
    /// user enabled it globally — and a chat that quietly forgets what you told
    /// it is a worse surprise than one that remembers too much. Memory is only
    /// offered where the model reports the capability, because a toggle that
    /// does nothing is worse than no toggle.
    static func seedFeatures(for model: ChatModel?, incognito: Bool = false) -> [String: Bool] {
        guard let model else { return [:] }
        var seeded = Dictionary(
            uniqueKeysWithValues: model.defaultFeatureIDs.map { ($0, true) })
        // Incognito has to mean something. Remembering what the user just said
        // in a chat that is supposed to vanish is the opposite of the request.
        if model.supports(.memory) && !incognito { seeded[ChatFeature.memory.rawValue] = true }
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
        return (hasText || !attachments.isEmpty || uploading) && !phase.isBusy
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
        phase = .loading
        do {
            let detail = try await client.chat(id: chatID)
            self.detail = detail
            title = detail.title
            turns = detail.thread.map(Turn.init)
            leafID = turns.last?.id
            chatVariables = detail.variables
            if let used = detail.models.first, !used.isEmpty { model = used }
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
            self.error = error.localizedDescription
            phase = .ready
        }
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
        uploading = true
        error = nil
        uploadsInFlight += 1
        pendingUploads.append(Task {
            defer {
                uploadsInFlight -= 1
                uploading = uploadsInFlight > 0
            }
            do {
                let file = try await client.uploadFile(data: data, filename: name, mimeType: mimeType)
                attachments.append(
                    PendingAttachment(id: file.id, name: file.filename, mimeType: mimeType, data: data))
            } catch {
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

    private func waitForUploads() async {
        guard !pendingUploads.isEmpty else { return }
        let waiting = pendingUploads
        pendingUploads = []
        for task in waiting { _ = await task.value }
    }

    /// A file the picker handed over and the app could not read.
    public func attachmentFailed(_ name: String) {
        error = "Could not read \(name)."
    }

    public func detach(_ attachment: PendingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // `uploading` counts as content. A picture that is still on the wire is
        // not an absent picture, and refusing to send until it lands is better
        // than sending a message that quietly lost it.
        guard !(text.isEmpty && attachments.isEmpty && !uploading), !phase.isBusy else { return }
        draft = ""
        error = nil
        // Set here rather than inside the task: the button's feedback should not
        // wait for a scheduling hop, and a caller that then awaits something
        // conditioned on the phase would otherwise race the run it just started.
        phase = .waiting
        run = Task {
            // Taken *after* the wait, because until the upload answers there is
            // no file id to take.
            await self.waitForUploads()
            let files = self.attachments
            self.attachments = []
            await self.exchange(text: text, regenerating: nil, files: files)
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
        guard !clean.isEmpty, !phase.isBusy, let index = turns.firstIndex(where: { $0.id == messageID })
        else { return }
        error = nil
        turns[index].text = clean
        // Everything after the edited message belongs to the branch being
        // replaced; leaving it on screen would show an answer to a question that
        // no longer says that.
        turns.removeSubrange(turns.index(after: index)..<turns.endIndex)
        leafID = messageID
        run = Task {
            do { try await client.updateMessage(chatID: chatID ?? "", messageID: messageID, content: clean) }
            catch { self.error = error.localizedDescription; return }
            await self.exchange(text: clean, regenerating: messageID, files: [])
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
    ///
    /// The server lists at least one message as its own child, so the walk
    /// refuses to revisit anything it has already stood on.
    private func leaf(below id: String) -> String {
        guard let detail else { return id }
        var cursor = id
        var seen: Set<String> = [id]
        while let node = detail.messages[cursor],
            let next = node.childrenIDs.last(where: { !seen.contains($0) }) {
            seen.insert(next)
            cursor = next
        }
        return cursor
    }

    /// The child of `messageID` that leads to the message the branch ends on.
    private func branchChild(of messageID: String) -> String? {
        guard let detail, var id = leafID else { return nil }
        var guardCount = 0
        while guardCount < 500, let node = detail.messages[id], let parent = node.parentID {
            if parent == messageID { return id }
            id = parent
            guardCount += 1
        }
        return nil
    }

    /// Re-runs the last user message. That message's id is reused, so the server
    /// files the new answer as a sibling in the message tree instead of a new
    /// turn — which is what makes the web UI's "2/3" possible, and costs nothing
    /// here because the app already knows the id.
    public func regenerate() {
        guard !phase.isBusy, let index = turns.lastIndex(where: \.isUser) else { return }
        let last = turns[index]
        error = nil
        turns.removeSubrange(turns.index(after: index)..<turns.endIndex)
        leafID = last.id
        phase = .waiting
        run = Task { await self.exchange(text: last.text, regenerating: last.id, files: []) }
    }

    /// Asks the server to halt the run in flight.
    ///
    /// It has to be a separate request: the completion POST is still open for the
    /// whole generation, so there is no other channel to shout down. A 200 here
    /// is not proof anything stopped — hence `stopping` rather than `ready`, and
    /// the terminal frame is what actually ends it.
    public func stop() {
        guard let chatID, phase.isBusy else { return }
        phase = .stopping
        Task {
            do {
                try await client.stop(chatID: chatID)
            } catch {
                self.error = error.localizedDescription
            }
            // The server has confirmed the task is stopped. Waiting for a frame
            // to prove it was the old design, and on a real stop that frame
            // never came: the run was over but nothing terminal was emitted, so
            // the button stayed red and the chat looked frozen even though
            // nothing was happening. A Stop button that stops is what was asked
            // for. Whatever arrived stays on screen.
            finishLocally(chatID: chatID)
        }
    }

    /// Ends the run in the app, whatever the server does next.
    private func finishLocally(chatID: String) {
        run?.cancel()
        post?.cancel()
        post = nil
        hub.expire(chatID: chatID)
        // A brand new chat may still be waiting for its id when stop is pressed.
        hub.expireWaitingListeners()
        if let index = turns.lastIndex(where: \.isAssistant) {
            turns[index].streaming = false
        }
        phase = .ready
    }

    /// Gives up on the local view of a run — used when the app goes to the
    /// background, where the socket will be cut anyway.
    public func abandon() {
        run?.cancel()
        post?.cancel()
        post = nil
        if let index = turns.lastIndex(where: \.isAssistant) { turns[index].streaming = false }
        phase = .ready
    }

    // MARK: - the exchange

    private struct Located {
        var turn: Turn
        var index: Int
    }

    /// Whether the current model can be shown a picture at all.
    private var modelSupportsVision: Bool {
        models.first { $0.id == model }?.supportsVision ?? false
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
            .object([
                "type": .string("file"),
                "id": .string(file.id),
                "name": .string(file.name),
                "file": .object([
                    "id": .string(file.id),
                    "filename": .string(file.name),
                    "meta": .object([
                        "name": .string(file.name),
                        "content_type": .string(file.mimeType),
                    ]),
                ]),
            ])
        }
    }

    private func exchange(text: String, regenerating: String?, files: [PendingAttachment]) async {
        guard !model.isEmpty else {
            error = "No model selected."
            return
        }
        phase = .waiting
        let chat: String
        do {
            chat = try await ensureChat(named: text)
        } catch {
            self.error = error.localizedDescription
            phase = .ready
            return
        }

        let userMessageID = regenerating ?? UUID().uuidString
        let assistantID = UUID().uuidString
        let parentID = regenerating ?? leafID

        if regenerating == nil {
            turns.append(
                Turn(
                    id: userMessageID, role: "user", text: text,
                    attachments: files.map {
                        MessageAttachment(id: $0.id, name: $0.name, isImage: $0.isImage)
                    }))
        }
        let content = Self.userContent(text: text, files: files, vision: modelSupportsVision)
        let history = wireHistory(through: userMessageID, content: content)
        turns.append(Turn(id: assistantID, role: "assistant", streaming: true))
        let assistantIndex = turns.count - 1

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
            messages: history,
            // Absent, not null: the server reads a missing `chat_id` as "this is
            // a new chat" and only then offers to name it.
            chatID: newChat ? nil : chat,
            parentID: parentID.map(CompletionRequest.ParentID.message) ?? .root,
            userMessage: CompletionRequest.WireMessage(
                id: userMessageID, role: "user", content: content,
                parentID: parentID, model: model),
            messageID: assistantID,
            features: features,
            files: files.isEmpty ? nil : Self.filePayload(files),
            // `ask` is what makes the server park on a tool call and wait for a
            // tap. Left unset the server runs every tool without asking, which is
            // right for a headless client and wrong for one in the hand.
            params: CompletionRequest.Params(toolApprovalMode: "ask"),
            toolIDs: tools.isEmpty ? nil : tools,
            // Left nil on purpose. `tool_servers` is for ad-hoc servers passed by
            // url, which is not what the picker offers: connected MCP servers
            // arrive from /tools/ as `server:mcp:N` and go in `tool_ids` like
            // any other tool. The field stays on the request because the server
            // accepts it, not because anything here sets it.
            toolServerIDs: nil,
            chatVariables: chatVariables,
            // Ask the server for a summarised title, the way the web UI does.
            // Without this the chat keeps the placeholder built from the first
            // line, which is why app-created chats read as truncated messages
            // while browser-created ones read as titles.
            sessionID: hub.sessionID,
            tasks: newChat ? ["title_generation": .object([:])] : nil)

        // Blocks for the whole generation and yields no body; what is left for it
        // to do is fail loudly (401, 429) and to close. The task inherits this
        // actor's isolation, so reporting from it needs no hop.
        post = Task {
            do { try await self.client.stream(request).drain() }
            catch { self.recordPostError(error) }
        }

        var outcome = await drain(frames, assistantID: assistantID, index: assistantIndex)
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
            phase = .ready
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
                // No terminal frame at all: usually a socket blip rather than a
                // failed run, so look before claiming "the server sent nothing"
                // while it sent everything.
                await refresh(messageID: assistantID)
                if turns.first(where: { $0.id == assistantID })?.text.isEmpty ?? true {
                    // The server's own reason beats our guess. "The server sent
                    // nothing" is true but useless next to "Empty reply from
                    // server", which names the thing that actually broke.
                    outcome.failure = outcome.reportedError ?? "The server sent nothing."
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
        // An error that arrived alongside a real answer is noise about how the
        // answer was produced, not a reason to hide it. Only surface it when
        // there is genuinely nothing to show.
        if outcome.failure == nil, let reported = outcome.reportedError {
            let got = turns.first(where: { $0.id == assistantID })?.text ?? ""
            if got.isEmpty { outcome.failure = reported }
        }
        if let failure = outcome.failure { error = failure }
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
        for attempt in 0..<6 {
            try? await Task.sleep(for: .milliseconds(700 * (attempt + 1)))
            guard let fresh = try? await client.chat(id: chat) else { return }
            let generated = fresh.title
            if !generated.isEmpty, generated != placeholder {
                title = generated
                return
            }
        }
    }

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
        index: Int,
        continuing: Bool = false
    ) async -> DrainOutcome {
        var outcome = DrainOutcome()
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
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.publishPending(keeping: assistantID, index: index)
            }
        }
        let watchdog = Task { [hub] in
            try? await Task.sleep(for: Self.silenceLimit)
            hub.expire(chatID: chatID ?? "")
        }

        var sawToolArguments = false
        var erroredOnce = false
        var grace: Task<Void, Never>?
        for await frame in frames {
            if let messageID = frame.messageID, messageID != assistantID { continue }
            if let delta = frame.delta { pending?.text += delta }
            if let thinking = frame.reasoningDelta { pending?.reasoning += thinking }
            if let usage = frame.usage { pending?.usage = usage }
            // The server's own summary for the chat, when it got one mid-run.
            if let generated = frame.title { title = generated }
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

        var finished = pending ?? Turn(id: assistantID, role: "assistant")
        finished.streaming = false
        finished.error = outcome.failure
        flush(finished, into: index, final: true)
        pending = nil
        // Sources are not streamed as deltas — the server attaches them when it
        // saves the message. Without this a citation only appeared after leaving
        // and re-entering the chat, which reads as the feature being broken.
        if outcome.failure == nil, outcome.sawTerminal, let chat = chatID {
            let id = finished.id
            let streamed = finished.text
            Task { @MainActor [weak self] in
                guard let self,
                    let detail = try? await client.chat(id: chat),
                    let stored = detail.messages[id],
                    let at = self.turns.firstIndex(where: { $0.id == id })
                else { return }
                // Sources are not streamed as deltas — the server attaches them
                // when it saves the message. Without this a citation only
                // appeared after leaving and re-entering the chat, which reads
                // as the feature being broken.
                if stored.citedSources.isEmpty == false {
                    self.turns[at].sources = stored.citedSources
                }
                // And if the stored answer is longer than what arrived, the run
                // outlived the stream. Adopt the stored text rather than leaving
                // a truncated answer on screen; the refetch that used to be the
                // only way to see it is now the safety net instead of the fix.
                let storedText = stored.content.text
                if storedText.count > streamed.count + 1 {
                    self.turns[at].text = storedText
                }
            }
        }
        return outcome
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolveToolCall(
                    chatID: chat, messageID: messageID, callID: call.callID,
                    action: action, answers: answers)
            } catch let error as APIError {
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
                self.error = error.localizedDescription
                self.phase = .ready
                return
            }
            var outcome = await self.drain(frames, assistantID: messageID, index: index, continuing: true)
            if outcome.parked {
                // Same as the first run: keep looking until the question has
                // actually landed, because nothing later will fix it.
                await self.awaitQuestion(messageID: messageID)
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
    private func reconcileUntilClosed(messageID: String) async {
        guard let chat = chatID else { return }
        // A chat abandoned server-side — browser closed mid-run, worker died —
        // keeps `done: false` forever. Polling that for five minutes would show a
        // spinner on a dead chat, which is its own bug. So growth is the signal:
        // if neither the answer nor the reasoning has moved in half a minute,
        // nothing is coming.
        var still = 0
        var seen = 0
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
            let size = message.content.text.count + message.output.count
            still = size == seen ? still + 1 : 0
            seen = max(seen, size)
            if still >= reconcileStallLimit {
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
    var reconcileInterval: Duration = .seconds(2)
    var reconcileStallLimit = 15
    var reconcileBudget = 150

    /// A failed POST is reported only if the run has not already ended on its own
    /// terms — a stream closed by `stop()` errors on the way out, and calling
    /// that a failure would be a lie the user cannot act on.
    private func recordPostError(_ error: Error) {
        guard phase.isBusy else { return }
        if let api = error as? APIError, api.isUnauthorized { self.error = "Signed out." }
        else { self.error = error.localizedDescription }
    }

    /// Text accumulated from the socket but not yet published.
    @ObservationIgnored private var pending: Turn?

    /// Publishes whatever has arrived. Runs on the flush timer, so it must not
    /// invent a turn if the run has already been replaced (a regenerate, say).
    private func publishPending(keeping id: String, index: Int) {
        guard let pending, pending.id == id else { return }
        flush(pending, into: index)
    }

    /// Publishes buffered text. Only touches `turns` on a flush, so the view
    /// diffs at ~16 Hz instead of once per token.
    private func flush(_ source: Turn, into index: Int, final: Bool = false) {
        guard index < turns.count else { return }
        var turn = turns[index]
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
        turns[index] = turn
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
        return Self.awaitingChatID
    }

    /// Stand-in for "the server has not told us the id yet".
    static let awaitingChatID = "__awaiting__"

    /// Takes the id the server chose, once.
    private func adopt(chatID: String) {
        guard self.chatID == nil else { return }
        self.chatID = chatID
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
