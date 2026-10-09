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
    public private(set) var lastError: String?

    /// See `ChatEventSocket.sessionID`. Sent as the completion's `session_id`,
    /// which is what unlocks the server's builtin tools.
    public var sessionID: String? { socket.sessionID }

    private let socket: ChatEventSocket
    private var subscribers: [UUID: Subscriber] = [:]
    private var installed = false

    private struct Subscriber {
        let chatID: String
        let continuation: AsyncStream<ChatEventSocket.Frame>.Continuation
    }

    public init(server: Server) {
        socket = ChatEventSocket(server: server)
        // Registered once, here, because `onFrame` appends: calling it per
        // subscriber would deliver every frame N times to the Nth listener.
        socket.onFrame { [weak self] frame in
            Task { @MainActor in self?.receive(frame) }
        }
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

    public func disconnect() {
        socket.disconnect()
        isConnected = false
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

    /// Ends every listener for a chat. Used when a run is over, and by the
    /// silence watchdog — a stream nobody finishes is a conversation stuck in
    /// "streaming" with a spinner that never stops.
    public func expire(chatID: String) {
        for (token, subscriber) in subscribers where subscriber.chatID == chatID {
            subscriber.continuation.finish()
            subscribers[token] = nil
        }
    }

    /// Delivers a frame to matching listeners. Split out from the socket
    /// callback so tests can feed the hub real frames without a socket.
    func receive(_ frame: ChatEventSocket.Frame) {
        for subscriber in subscribers.values where subscriber.chatID == frame.chatID {
            subscriber.continuation.yield(frame)
        }
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
