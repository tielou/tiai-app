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
        /// `data.type`, e.g. `response:completion`, `chat:completion`,
        /// `chat:list`. Observed live on 0.11.4.
        public let kind: String
        /// The envelope: `{"type": ..., "data": ...}`.
        public let data: [String: JSONValue]
        public let raw: String

        init?(_ dictionary: [String: Any]) {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dictionary),
                  let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: jsonData)
            else { return nil }
            raw = String(decoding: jsonData, as: UTF8.self)
            chatID = decoded["chat_id"]?.stringValue
            messageID = decoded["message_id"]?.stringValue
            let payload = decoded["data"]?.objectValue ?? [:]
            data = payload
            kind = payload["type"]?.stringValue ?? payload.keys.sorted().first ?? "unknown"
        }

        /// The inner payload, `data.data`. It is one of two shapes and both
        /// occur inside a single completion, so the decoder has to handle both:
        ///
        /// * an OpenAI chunk (`choices`, `object`) — seen as the opening frame
        ///   announcing the role and as the closing frame carrying
        ///   `finish_reason`
        /// * a Responses-API event (`type`, `delta`, `item_id`, `output_index`)
        ///   — every actual content token
        ///
        /// Reading only the second shape loses the terminal frame; reading only
        /// the first loses the whole answer. Both mistakes have now been made
        /// once, against live traffic.
        public var inner: [String: JSONValue]? { data["data"]?.objectValue }

        /// The inner type tag: `response.output_text.delta`,
        /// `response.reasoning_text.delta`, … Absent on OpenAI chunks.
        public var innerType: String? { inner?["type"]?.stringValue }

        private var choice: [String: JSONValue]? { inner?["choices"]?.firstArrayElement?.objectValue }
        private var openAIDelta: [String: JSONValue]? { choice?["delta"]?.objectValue }
        private var flatDelta: String? { inner?["delta"]?.stringValue }

        /// Thinking tokens, kept apart from the answer because the app renders
        /// them in a disclosure. Matched on the suffix rather than the exact
        /// string so `response.reasoning_summary_text.delta` and whatever comes
        /// next still land here instead of in the answer.
        public var reasoningDelta: String? {
            if let type = innerType {
                return type.hasSuffix(".delta") && type.contains("reasoning") ? flatDelta : nil
            }
            return openAIDelta?["reasoning_content"]?.stringValue
                ?? openAIDelta?["reasoning"]?.stringValue
        }

        public var delta: String? {
            if let type = innerType {
                return type.hasSuffix(".delta") && !type.contains("reasoning") ? flatDelta : nil
            }
            return openAIDelta?["content"]?.stringValue
        }

        public var finishReason: String? {
            choice?["finish_reason"]?.stringValue ?? choice?["finishReason"]?.stringValue
        }

        public var usage: TokenUsage? {
            guard let value = inner?["usage"] ?? choice?["usage"],
                  let encoded = try? JSONEncoder().encode(value),
                  let decoded = try? JSONDecoder().decode(TokenUsage.self, from: encoded)
            else { return nil }
            return decoded
        }

        /// An error the model run reported mid-stream, if any.
        public var errorText: String? {
            data["error"]?.stringValue ?? inner?["error"]?.stringValue
        }

        /// A frame some servers end with. Not observed on 0.11.4 — the terminal
        /// frame there is `chat:completion` carrying `finish_reason` — so
        /// nothing may rely on this alone.
        public var isDone: Bool {
            data["done"]?.boolValue == true || inner?["done"]?.boolValue == true
        }

        /// Marks the end of the model's output. Not the same as `isDone`: the
        /// server still writes the transcript and emits a terminal frame after
        /// it, so a client that stops here loses the tail.
        public var isFinish: Bool { finishReason != nil }

        /// What the app should treat as the end. On 0.11.4 this is reached via
        /// `isFinish`; `isDone` is kept because other paths emit it.
        public var isTerminal: Bool { isDone || isFinish }
    }

    private let manager: SocketManager
    private let client: SocketIOClient
    private let handlers = SendableBox<[(Frame) -> Void]>([])
    private let token: String

    /// Where Open WebUI mounts its socket.io ASGI app:
    /// `app.mount('/ws', socket_app)` with `socketio_path = '/ws/socket.io'`.
    /// Not `/socket.io` — that path falls through to the SPA and hands back
    /// index.html, which is a confusingly silent failure.
    public static let socketPath = "/ws/socket.io"

    /// Open WebUI creates its AsyncServer with `transports=['websocket']` when
    /// websocket support is on, so polling is refused with "Invalid transport".
    /// There is no polling fallback to configure; skipping it is not an
    /// optimisation, it is the only working option.
    public static let websocketOnly = true

    public init(server: Server) {
        token = server.token
        manager = SocketManager(
            socketURL: server.baseURL,
            config: [
                .path(Self.socketPath),
                .forceWebsockets(Self.websocketOnly),
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
