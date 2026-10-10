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

    private let client: OWUIClient
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
    /// Deltas are coalesced before they reach observable state: a model emitting
    /// token by token would otherwise invalidate the transcript view per token,
    /// which is the difference between a smooth stream and a stuttering one.
    static let flushInterval: Duration = .milliseconds(60)

    public init(
        chatID: String?,
        title: String = "New Chat",
        models: [ChatModel] = [],
        client: OWUIClient,
        hub: ChatEventHub
    ) {
        self.chatID = chatID
        self.title = title
        self.client = client
        self.hub = hub
        modelIDs = models.map(\.id)
        model = models.first?.id ?? ""
        features = Self.seedFeatures(for: models.first)
    }

    /// The toggles a model starts a chat with.
    ///
    /// The server's own defaults first, so a model configured for web search
    /// starts with it on. Then memory, which the server leaves off unless the
    /// user enabled it globally — and a chat that quietly forgets what you told
    /// it is a worse surprise than one that remembers too much. Memory is only
    /// offered where the model reports the capability, because a toggle that
    /// does nothing is worse than no toggle.
    static func seedFeatures(for model: ChatModel?) -> [String: Bool] {
        guard let model else { return [:] }
        var seeded = Dictionary(
            uniqueKeysWithValues: (model.defaultFeatureIDs ?? []).map { ($0, true) })
        if model.supports(.memory) { seeded[ChatFeature.memory.rawValue] = true }
        return seeded
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isBusy
    }

    public func setModels(_ models: [ChatModel]) {
        modelIDs = models.map(\.id)
        if model.isEmpty { model = models.first?.id ?? "" }
        // A chat can open before the model list arrives, which leaves the
        // toggles unseeded. Fill them in, but never over a choice the user has
        // already made in this chat.
        if features.isEmpty { features = Self.seedFeatures(for: models.first) }
    }

    /// Called when the model changes: the defaults belong to the model, so the
    /// toggles have to follow it rather than keep the previous model's settings.
    public func select(model id: String, from models: [ChatModel]) {
        model = id
        features = Self.seedFeatures(for: models.first { $0.id == id })
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
        phase = .loading
        do {
            let detail = try await client.chat(id: chatID)
            title = detail.title
            turns = detail.thread.map(Turn.init)
            leafID = turns.last?.id
            chatVariables = detail.variables
            if let used = detail.models.first, !used.isEmpty { model = used }
            phase = .ready
        } catch {
            self.error = error.localizedDescription
            phase = .ready
        }
    }

    // MARK: - sending

    /// A file chosen in the composer and uploaded, waiting to be sent with the
    /// next message.
    public struct PendingAttachment: Identifiable, Equatable, Sendable {
        /// The server's file id — this is what goes in the completion's `files`.
        public let id: String
        public let name: String
        public let mimeType: String
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
        Task {
            defer { uploading = false }
            do {
                let file = try await client.uploadFile(data: data, filename: name, mimeType: mimeType)
                attachments.append(
                    PendingAttachment(id: file.id, name: file.filename, mimeType: mimeType))
            } catch {
                self.error = "Could not attach \(name): \(error.localizedDescription)"
            }
        }
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
        guard !text.isEmpty, !phase.isBusy else { return }
        let files = attachments
        attachments = []
        draft = ""
        error = nil
        // Set here rather than inside the task: the button's feedback should not
        // wait for a scheduling hop, and a caller that then awaits something
        // conditioned on the phase would otherwise race the run it just started.
        phase = .waiting
        run = Task { await self.exchange(text: text, regenerating: nil, files: files) }
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
            do { try await client.stop(chatID: chatID) }
            catch { self.error = error.localizedDescription }
        }
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
            turns.append(Turn(id: userMessageID, role: "user", text: text))
        }
        let history = wireHistory(through: userMessageID, userText: text)
        turns.append(Turn(id: assistantID, role: "assistant", streaming: true))
        let assistantIndex = turns.count - 1

        // Subscribing before the POST matters: frames can arrive while the
        // request is still in flight, and the socket has no replay.
        let frames = hub.frames(for: chat)
        let request = CompletionRequest(
            model: model,
            messages: history,
            chatID: chat,
            parentID: parentID.map(CompletionRequest.ParentID.message) ?? .root,
            userMessage: CompletionRequest.WireMessage(
                id: userMessageID, role: "user", content: .text(text),
                parentID: parentID, model: model),
            messageID: assistantID,
            features: features,
            files: files.isEmpty ? nil : files.map(\.id),
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
            sessionID: hub.sessionID)

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
            phase = .ready
            return
        }
        if outcome.sawTerminal {
            leafID = assistantID
        } else if outcome.failure == nil {
            outcome.failure = phase == .stopping ? "Stopped." : "The server sent nothing."
        }
        if let failure = outcome.failure { error = failure }
        phase = .ready
    }

    struct DrainOutcome {
        var sawTerminal = false
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
        var grace: Task<Void, Never>?
        for await frame in frames {
            if let messageID = frame.messageID, messageID != assistantID { continue }
            if let delta = frame.delta { pending?.text += delta }
            if let thinking = frame.reasoningDelta { pending?.reasoning += thinking }
            if let usage = frame.usage { pending?.usage = usage }
            if let problem = frame.errorText { outcome.failure = problem }
            if let answered = frame.answeredModel { pending?.model = answered }
            if let calls = frame.outputItems { pending?.calls = calls }
            if frame.isToolArgumentsDelta { sawToolArguments = true }
            if frame.isTerminal {
                // `ask_user` streams its arguments, then finishes, and only then
                // does the server stage the call and emit the pause frame with
                // `output`. Breaking on the finish frame loses the question and
                // leaves an empty turn — which is exactly what the first live
                // test showed. Wait a moment for the pause instead.
                if sawToolArguments && pending?.calls.isEmpty != false {
                    grace = Task { [hub] in
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { hub.expire(chatID: chatID ?? "") }
                    }
                    continue
                }
                outcome.sawTerminal = true
                break
            }
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
        return outcome
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

        // Subscribe before the POST: the resumed run can emit before the
        // response comes back, and the socket does not replay.
        let frames = hub.frames(for: chat)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolveToolCall(
                    chatID: chat, messageID: messageID, callID: call.callID,
                    action: action, answers: answers)
            } catch {
                self.error = error.localizedDescription
                self.phase = .ready
                return
            }
            var outcome = await self.drain(frames, assistantID: messageID, index: index, continuing: true)
            if outcome.parked {
                self.phase = .ready
                return
            }
            if outcome.sawTerminal { self.leafID = messageID }
            else if outcome.failure == nil { outcome.failure = "The server sent nothing." }
            await self.refresh(messageID: messageID)
            if let failure = outcome.failure { self.error = failure }
            self.phase = .ready
        }
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
              let message = detail.messages[messageID],
              let index = turns.firstIndex(where: { $0.id == messageID })
        else { return }
        let fresh = Turn(message)
        var turn = turns[index]
        if fresh.text.count > turn.text.count { turn.text = fresh.text }
        if fresh.reasoning.count > turn.reasoning.count { turn.reasoning = fresh.reasoning }
        if !fresh.calls.isEmpty { turn.calls = fresh.calls }
        turn.usage = fresh.usage ?? turn.usage
        turns[index] = turn
    }

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
        turn.streaming = final ? false : turn.streaming
        turns[index] = turn
        if !final && (!source.text.isEmpty || !source.reasoning.isEmpty), phase.isBusy {
            phase = .streaming
        }
    }

    /// The chat has to exist before the completion is sent, and a brand-new
    /// conversation does not exist until this returns.
    private func ensureChat(named text: String) async throws -> String {
        if let chatID { return chatID }
        let created = try await client.createChat(title: Self.title(from: text))
        chatID = created.id
        title = created.title
        return created.id
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
    private func wireHistory(through userMessageID: String, userText: String)
        -> [CompletionRequest.WireMessage]
    {
        var out: [CompletionRequest.WireMessage] = []
        var parent: String?
        for turn in turns {
            let message: CompletionRequest.WireMessage?
            if turn.id == userMessageID {
                message = .init(
                    id: turn.id, role: "user", content: .text(userText), parentID: parent, model: model)
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
