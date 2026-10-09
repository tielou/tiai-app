import Foundation
import SocketIO

/// The socket.io side channel.
///
/// This is not a nicety. When a completion carries a message id — which it must,
/// or nothing is persisted — the server consumes the upstream stream in a
/// background task, writes the reply to the chat, emits every delta over
/// socket.io, and returns an **empty REST body**. The web UI gets streaming
/// because it is on this socket; a client that is not sees nothing until the
/// answer is finished. No REST call yields both the tokens and a stored
/// transcript. See docs/M0-FINDINGS.md.
///
/// The connection authenticates with the same bearer token as the REST calls
/// (`auth: {token}`), and the server puts the session in the room `user:<id>` on
/// connect, which is where every chat event is emitted.
public final class ChatEventSocket: @unchecked Sendable {
    /// A frame as it arrived, decoded just enough to route it.
    ///
    /// Deliberately raw-ish. The server's event vocabulary is a moving target —
    /// deltas arrive as `response.output_text.delta`, whole-output resends under
    /// `output`, usage and error as their own keys, and the set has changed
    /// between releases. Capturing the payload before interpreting it is what
    /// lets the client survive the next change — and it is what let the probe
    /// discover the shape in the first place.
    public struct Frame: Sendable {
        public let chatID: String?
        public let messageID: String?
        /// `data.type` when present, otherwise the key that carried the payload
        /// (`usage`, `error`, `output`, …).
        public let kind: String
        public let data: [String: JSONValue]
        public let raw: String

        /// The text delta, if this frame is one.
        public var delta: String? { data["delta"]?.stringValue }

        public var isDone: Bool { data["done"]?.boolValue == true }

        init?(_ dictionary: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
                  let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            else { return nil }
            raw = String(decoding: data, as: UTF8.self)
            chatID = decoded["chat_id"]?.stringValue
            messageID = decoded["message_id"]?.stringValue
            let payload = decoded["data"]?.objectValue ?? [:]
            self.data = payload
            if let type = payload["type"]?.stringValue {
                kind = type
            } else if let first = payload.keys.sorted().first {
                kind = first
            } else {
                kind = "unknown"
            }
        }
    }

    private let manager: SocketManager
    private let client: SocketIOClient
    private let handlers = SendableBox<[(Frame) -> Void]>([])
    private let token: String

    public init(server: Server) {
        token = server.token
        manager = SocketManager(
            socketURL: server.baseURL,
            config: [
                .path("/socket.io"),
                .compress,
                .log(false),
                // A phone walks out of wifi constantly. Reconnecting forever is
                // right here; the alternative is a chat that silently stops
                // streaming and nobody knows why.
                .reconnects(true),
                .reconnectAttempts(-1),
                .reconnectWait(1),
                .reconnectWaitMax(30),
            ])
        // The root namespace, which is where Open WebUI mounts its handlers and
        // where `get_event_emitter` emits to `user:<id>`.
        client = manager.defaultSocket
    }

    deinit {
        manager.disconnect()
    }

    public var isConnected: Bool { client.status == .connected }

    public func disconnect() {
        client.disconnect()
    }

    /// Connects and waits for the handshake, so the first completion cannot race
    /// the socket and lose its deltas.
    public func connect(timeout: Duration = .seconds(10)) async throws {
        if isConnected { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let settled = SendableBox(false)
            func settle(_ result: Result<Void, any Error>) {
                guard !settled.value else { return }
                settled.value = true
                continuation.resume(with: result)
            }
            client.on(clientEvent: .connect) { _, _ in settle(.success(())) }
            client.on(clientEvent: .error) { data, _ in
                settle(.failure(APIError.unreachable(Self.describe(data))))
            }
            client.on(clientEvent: .disconnect) { data, _ in
                settle(.failure(APIError.unreachable("closed: \(Self.describe(data))")))
            }
            // The token rides in the socket.io CONNECT packet, which is where
            // the server's connect handler reads `auth`.
            client.connect(withPayload: ["token": token])
            Task {
                try? await Task.sleep(for: timeout)
                settle(.failure(APIError.unreachable("no response within \(timeout)")))
            }
        }
    }

    /// Subscribes to every `events` frame. The caller filters by chat and
    /// message; the socket itself is one shared connection for the whole app.
    public func onFrame(_ handler: @escaping (Frame) -> Void) {
        handlers.value = handlers.value + [handler]
        client.on("events") { [weak self] payload, _ in
            guard let self else { return }
            guard let dictionary = payload.first as? [String: Any], let frame = Frame(dictionary) else { return }
            for handler in self.handlers.value { handler(frame) }
        }
    }

    private static func describe(_ data: [Any]) -> String {
        data.first.map { String(describing: $0) } ?? "unknown"
    }
}
