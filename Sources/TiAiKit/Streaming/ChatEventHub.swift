import Foundation

/// One socket, many listeners.
///
/// The server emits every event to the room `user:<id>`, so a single connection
/// carries all chats and each screen filters by `chat_id`. That is the whole
/// reason this exists rather than one socket per conversation: reconnects are
/// per-connection, and a phone that walks out of wifi should cause one reconnect
/// and not five.
///
/// Frames are delivered to subscribers on the main actor. The socket's own
/// callback arrives on a Starscream queue, and letting that touch observable
/// state directly is how you get a UI update off the main thread — which is a
/// warning today and a crash on a bad day.
@MainActor
@Observable
public final class ChatEventHub {
    public private(set) var isConnected = false
    /// Set while a retry loop is running, so a foreground change in the middle of
    /// one does not start a second loop beside it.
    private var reconnecting = false
    public private(set) var lastError: String?

    /// See `ChatEventSocket.sessionID`. Sent as the completion's `session_id`,
    /// which is what unlocks the server's builtin tools.
    public var sessionID: String? { socket.sessionID }

    private let socket: ChatEventSocket
    private var subscribers: [UUID: Subscriber] = [:]
    private var installed = false

    private struct Subscriber {
        /// The chat this listener wants, or nil for a listener waiting to find
        /// out — see `framesAwaitingChatID`.
        var chatID: String?
        /// Called once, when a waiting listener learns the chat it belongs to.
        var onAdopt: ((String) -> Void)?
        let continuation: AsyncStream<ChatEventSocket.Frame>.Continuation
    }

    public init(server: Server) {
        socket = ChatEventSocket(server: server)
        // Registered once, here, because `onFrame` appends: calling it per
        // subscriber would deliver every frame N times to the Nth listener.
        socket.onFrame { [weak self] frame in
            Task { @MainActor in self?.receive(frame) }
        }
        // The socket reconnects itself; this is how the hub finds out.
        //
        // A drop is not immediately fatal to a run — Starscream is usually back
        // within a second, and tearing the listener down that fast would throw
        // away live streaming over a wifi blip. So there is a grace period, and
        // if the connection is still dead after it, every listener is ended.
        // Their runs then fall into the reconcile path and read the answer off
        // the server record, which is the thing that already works when you
        // leave the chat and come back.
        socket.onStatusChange { [weak self] up in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = up
                if up { self.lastError = nil; return }
                try? await Task.sleep(for: Self.reconnectGrace)
                if !self.isConnected { self.expireAll() }
            }
        }
    }

    /// How long the socket may be down before runs stop waiting for it.
    ///
    /// Four seconds was too impatient: a phone resuming from background has to
    /// bring the radio back and redo the websocket handshake, and expiring the
    /// run at 4s meant a stream was declared dead about five seconds before the
    /// socket that would have fed it arrived. Still far short of the 60s silence
    /// watchdog, so a genuinely dead run does not hang.
    static let reconnectGrace: Duration = .seconds(10)

    /// Ends every listener. A run whose stream ends this way has seen no terminal
    /// frame, so its caller reconciles against the server instead of hanging.
    public func expireAll() {
        for (_, subscriber) in subscribers { subscriber.continuation.finish() }
        subscribers.removeAll()
    }

    /// Connects if not already connected. Safe to call from every screen.
    public func connect() async throws {
        do {
            try await socket.connect()
            isConnected = true
            lastError = nil
        } catch {
            isConnected = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Kicks a reconnect without waiting for it, and keeps trying for a while.
    ///
    /// A single attempt was not enough. The common case is unlocking the phone:
    /// the radio is still coming back, the first attempt fails for a reason that
    /// fixes itself a second later, and nothing tried again — so the app sat
    /// showing a dead socket until the next thing you did. Backoff rather than a
    /// hammer, and it stops rather than retrying a server that is genuinely down:
    /// a send still works without the socket, and the refetch a run already does
    /// recovers any frames that were missed.
    public func reconnectIfNeeded() {
        guard !isConnected, !reconnecting else { return }
        reconnecting = true
        Task { [weak self] in
            guard let self else { return }
            var delay: TimeInterval = 0.5
            for _ in 0..<6 {
                if isConnected { break }
                do {
                    try await self.socket.connect()
                    self.isConnected = true
                    self.lastError = nil
                    break
                } catch {
                    self.lastError = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
            self.reconnecting = false
        }
    }

    public func disconnect() {
        socket.disconnect()
        isConnected = false
    }

    /// Tells the server this chat has been read.
    ///
    /// Fire-and-forget by design: nothing in the app depends on the answer, and a
    /// read receipt that blocks a screen is worse than one that is occasionally
    /// lost. Dropped silently when the socket is down — the next open marks it
    /// again, and the browser's blue dot is not worth queueing work for.
    public func markChatRead(_ chatID: String) {
        socket.emit("events:chat", with: [
            "chat_id": chatID,
            "data": ["type": "last_read_at"],
        ])
    }

    /// Frames belonging to one chat. The stream ends when the caller stops
    /// iterating, when `expire(chatID:)` runs, or when the hub is deallocated.
    public func frames(for chatID: String) -> AsyncStream<ChatEventSocket.Frame> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatEventSocket.Frame.self)
        let token = UUID()
        subscribers[token] = Subscriber(chatID: chatID, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[token] = nil }
        }
        return stream
    }

    /// A listener for a chat that does not have an id yet.
    ///
    /// The server only generates a chat's title when the completion looks like a
    /// brand new chat, and it decides that from the request: `parent_id` present
    /// and null, and *no* `chat_id`. A client that allocates the id itself and
    /// POSTs /chats/new first is, by that test, never new — which is why
    /// app-created chats kept a truncated first line while browser-created ones
    /// got a summary. So the first message goes out without an id and the app
    /// learns the server's from the first frame that carries one.
    ///
    /// #36: the caller supplies `token`, which becomes the subscriber's
    /// identity, and `expire(waitingToken:)` ends exactly that listener. This
    /// replaces the global `expireWaitingListeners()` sweep: a model can
    /// address its own pre-id listener precisely, so one model stopping can
    /// never end another's — the hazard #9, #28 and #30 could only ever bound
    /// by gates is structurally gone. The token keeps working after the
    /// listener adopts a real id (the subscriber keeps its token as its key
    /// through adoption), which also closes #30's documented residual: a
    /// listener that adopted an id while the model's chatID was still nil was
    /// addressed by neither of the old sweeps.
    public func framesAwaitingChatID(
        token: UUID,
        _ onAdopt: @escaping (String) -> Void
    ) -> AsyncStream<ChatEventSocket.Frame> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatEventSocket.Frame.self)
        subscribers[token] = Subscriber(
            chatID: nil, onAdopt: onAdopt, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[token] = nil }
        }
        return stream
    }

    /// Ends every listener for a chat. Used when a run is over, and by the
    /// silence watchdog — a stream nobody finishes is a conversation stuck in
    /// "streaming" with a spinner that never stops.
    public func expire(chatID: String) {
        for (token, subscriber) in subscribers where subscriber.chatID == chatID {
            subscriber.continuation.finish()
            subscribers[token] = nil
        }
    }

    /// Ends exactly the listener registered under `token` by
    /// `framesAwaitingChatID(token:_:)` — whether it is still waiting or has
    /// since adopted a chat id (the subscriber keeps its token as its dict
    /// key through adoption). An absent or already-removed token is a no-op,
    /// so a caller may hold it for a whole run without racing the adopt hop.
    /// #36: this is what the global `expireWaitingListeners()` sweep should
    /// have been from the start; the sweep is gone.
    public func expire(waitingToken token: UUID) {
        subscribers[token]?.continuation.finish()
        subscribers[token] = nil
    }

    /// Delivers a frame to matching listeners. Split out from the socket
    /// callback so tests can feed the hub real frames without a socket.
    func receive(_ frame: ChatEventSocket.Frame) {
        for (token, subscriber) in subscribers {
            if let wanted = subscriber.chatID {
                if wanted == frame.chatID { subscriber.continuation.yield(frame) }
                continue
            }
            // Awaiting listener: the first frame with a real chat id names the
            // chat, and the listener becomes a normal one for everything after.
            guard let actual = frame.chatID else { continue }
            subscribers[token]?.chatID = actual
            let adopt = subscriber.onAdopt
            subscriber.continuation.yield(frame)
            adopt?(actual)
        }
    }

    /// Whether a listener for `chatID` is currently registered — the same
    /// lookup `waitForSubscriber` polls, as a question. Test-support for
    /// teardown assertions (issue #4): "abandon ended this chat's stream" is
    /// only observable from outside the hub as the absence of a subscriber.
    func hasListener(for chatID: String) -> Bool {
        subscribers.values.contains { $0.chatID == chatID }
    }

    /// Whether a WAITING listener (a brand-new chat whose id the socket has
    /// not named yet — `chatID == nil`) is registered. Test-support for the
    /// #9 sweep constraint (#30): a stop on one chat must not sweep another
    /// model's waiting listener.
    var hasWaitingListener: Bool {
        subscribers.values.contains { $0.chatID == nil }
    }

    /// Blocks until something is listening to `chatID`.
    ///
    /// A test that injects frames before the conversation has subscribed loses
    /// them — the hub has no replay, same as the real socket — so "wait for the
    /// listener" is the only honest way to sequence them.
    func waitForSubscriber(_ chatID: String, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while !subscribers.values.contains(where: { $0.chatID == chatID }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
