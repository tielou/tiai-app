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
                // Everything that ends in `.delta` except the two that are not
                // the answer. `response.function_call_arguments.delta` also ends
                // in `.delta`, and streaming it into the prose prints the tool's
                // JSON as the model's reply — which is exactly what happened on
                // the first live `ask_user` call: the user read the schema
                // instead of being asked the question.
                guard type.hasSuffix(".delta"),
                      !type.contains("reasoning"),
                      !type.contains("function_call"),
                      !type.contains("arguments")
                else { return nil }
                return flatDelta
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

        /// Which model actually answered. Usually the one asked; an arena or
        /// auto-routed model reports something else here, and the transcript
        /// should say what really replied.
        public var answeredModel: String? { inner?["model"]?.stringValue }

        /// An error the model run reported mid-stream, if any.
        public var errorText: String? {
            data["error"]?.stringValue ?? inner?["error"]?.stringValue
        }

        /// A frame some servers end with. Not observed on 0.11.4 — the terminal
        /// frame there is `chat:completion` carrying `finish_reason` — so
        /// nothing may rely on this alone.
        ///
        /// `done` is not one flag. A `status` frame ends with `done: true` to mean
        /// "this step is finished", live: `{"type":"status","data":{"count":0,
        /// "action":"sources_retrieved","done":true}}`. Reading that as the end of
        /// the run stops the listener before a single token arrives — which is
        /// what happened on every image message, because retrieving the image
        /// emits one: the answer streamed, the app just was not watching any more.
        public var isDone: Bool {
            // `done` only ends a run on the frames that end one: the closing
            // `chat:completion`, or an OpenAI chunk. Anything else that carries
            // the flag is reporting on itself.
            let endsARun = kind == "chat:completion"
                || inner?["choices"] != nil || inner?["object"] != nil
            guard endsARun else { return false }
            return data["done"]?.boolValue == true || inner?["done"]?.boolValue == true
        }

        /// Marks the end of the model's output. Not the same as `isDone`: the
        /// server still writes the transcript and emits a terminal frame after
        /// it, so a client that stops here loses the tail.
        /// Tool calls and `ask_user` questions the run is waiting on.
        ///
        /// When the server pauses for a decision it emits
        /// `chat:completion` with `{done: false, output: […]}` and returns —
        /// there is no terminal frame, because from the server's side the run is
        /// not over, it is parked. A client that only watches deltas keeps
        /// spinning here.
        public var outputItems: [ToolCall]? {
            guard let items = inner?["output"]?.arrayValue ?? data["output"]?.arrayValue else { return nil }
            let calls = ToolCall.calls(from: items)
            return calls.isEmpty ? nil : calls
        }

        /// Whether this frame says "the run is parked waiting for the user".
        public var isAwaitingUser: Bool {
            outputItems?.contains(where: \ .isAwaitingUser) ?? false
        }

        /// A streamed tool-call argument fragment. Not the answer, and a signal
        /// that a pause frame is coming after the finish frame.
        public var isToolArgumentsDelta: Bool {
            innerType?.contains("function_call") == true || innerType?.contains("arguments") == true
        }

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
        #if DEBUG
        // Whether the socket came up at all decides which of two very different
        // problems "no frames arrived" is.
        client.on(clientEvent: .connect) { data, _ in
            Self.dump(raw: ["_connect", Self.describe(data)])
        }
        client.on(clientEvent: .disconnect) { data, _ in
            Self.dump(raw: ["_disconnect", Self.describe(data)])
        }
        client.on(clientEvent: .error) { data, _ in
            Self.dump(raw: ["_error", Self.describe(data)])
        }
        #endif
    }

    deinit {
        manager.disconnect()
    }

    public var isConnected: Bool { client.status == .connected }

    /// The socket's own session id, handed out by the server on connect.
    ///
    /// This is the switch that decides whether the server treats a completion
    /// request as coming from a client it can talk back to. In `middleware.py`:
    /// "Only inject when the request originates from the UI (identified by
    /// session_id). API callers don't expect hidden tools." Without it the
    /// builtin tools — `ask_user` among them — are simply not offered to the
    /// model, and the model then says it has no such tool, which reads like a
    /// client bug and is one, just not a visible one.
    ///
    /// Nil until the socket has connected, so a chat opened before the socket
    /// came up sends without it and gets the plain tool set.
    public var sessionID: String? { client.sid }

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
            // Dumped before parsing: a frame that arrives and fails to parse is
            // invisible to the UI too, and "nothing arrived" versus "it arrived
            // and we dropped it" need different fixes.
            Self.dump(raw: payload)
            guard let dictionary = payload.first as? [String: Any], let frame = Frame(dictionary) else { return }
            for handler in self.handlers.value { handler(frame) }
        }
    }

    #if DEBUG
    /// Appends every frame to `TIAI_DEBUG_DUMP` as JSON lines.
    ///
    /// A run that produced a visible answer on reload but nothing on screen was
    /// either the server sending something unexpected or the client dropping it,
    /// and a screenshot cannot tell those apart. Same reasoning as the response
    /// dump: read the bytes instead of theorising.
    static func dump(raw payload: [Any]) {
        guard let dir = ProcessInfo.processInfo.environment["TIAI_DEBUG_DUMP"] else { return }
        let object: Any = payload.count == 1 ? payload[0] : payload
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        guard let line = String(data: line, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("frames.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8) ?? Data())
    }
    #endif

    private static func describe(_ data: [Any]) -> String {
        data.first.map { String(describing: $0) } ?? "unknown"
    }
}
