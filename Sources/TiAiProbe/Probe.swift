import Foundation
import TiAiKit

// tiaiprobe — the M0 spike.
//
// A command-line client that runs the assumptions this app is built on against
// a real Open WebUI instance and says which ones held. Two of them could not be
// settled by reading the web UI's source, and one of them turned out to be
// false; docs/M0-FINDINGS.md is the record. The short version: a completion that
// carries a message id returns an EMPTY REST body, because the server awaits the
// whole generation in the request, writes the reply to the chat, and emits the
// content over socket.io instead. The POST also does not return until the model
// has finished — it is not a fire-and-forget handoff.
//
//   TIAI_URL=https://chat.example.co \
//   TIAI_EMAIL=you@example.co TIAI_PASSWORD=… swift run tiaiprobe
//
// or with a token (Settings → API Keys, or a JWT from browser devtools):
//
//   TIAI_URL=… TIAI_TOKEN=… swift run tiaiprobe
//
// The only writes are a chat it names as a probe and then deletes.

@main
@MainActor
struct Probe {
    /// How long to wait for a completion before declaring the socket dead. A
    /// cold prefill on a local engine is legitimately slow (halogen: 30k tokens
    /// ≈ 22 s, 245k ≈ 170 s), so this is generous — but it has to be finite, and
    /// enforced by a watchdog rather than a check inside the loop, because a
    /// loop that only looks at the clock when a frame arrives hangs forever when
    /// nothing arrives.
    static let completionTimeout = Duration.seconds(120)

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let report = Report()

        guard let urlString = env["TIAI_URL"], let url = Server.parse(urlString) else {
            FileHandle.standardError.write(Data("TIAI_URL is required, e.g. https://chat.example.co\n".utf8))
            exit(2)
        }

        print("tiAi probe → \(url.absoluteString)")
        var server = Server(baseURL: url)
        var client = OWUIClient(server: server)

        // ---- 1. unauthenticated reachability -----------------------------
        await report.check("health (GET /health)") { _ = try await client.health() }
        if let version = try? await client.version() { report.note("version", version.version) }
        if let config = try? await client.config() {
            report.note("websocket advertised", config.enableWebsocket ? "yes" : "no")
        }

        // ---- 2. auth ------------------------------------------------------
        if let token = env["TIAI_TOKEN"], !token.isEmpty {
            server = server.withToken(token)
            client = OWUIClient(server: server)
            await report.check("token accepted (GET /auths/)") {
                let user = try await client.session()
                report.note("user", "\(user.name) <\(user.email)> role=\(user.role)")
            }
        } else if let email = env["TIAI_EMAIL"], let password = env["TIAI_PASSWORD"] {
            await report.check("password sign-in (POST /auths/signin)") {
                let user = try await client.signin(email: email, password: password)
                guard let token = user.token, !token.isEmpty else {
                    throw ProbeError.failure("no token in the response")
                }
                server = server.withToken(token)
                client = OWUIClient(server: server)
                report.note("user", "\(user.name) <\(user.email)> role=\(user.role)")
            }
        } else {
            print("Set TIAI_TOKEN, or TIAI_EMAIL + TIAI_PASSWORD. Stopping after the unauthenticated checks.")
            report.dump()
            exit(report.failed == 0 ? 0 : 1)
        }

        // ---- 3. models -----------------------------------------------------
        var defaultModel: String?
        await report.check("model list (GET /models)") {
            let models = try await client.models()
            guard !models.isEmpty else { throw ProbeError.failure("server returned no models") }
            for model in models.prefix(12) {
                let caps = model.capabilities.filter(\.value).keys.sorted().joined(separator: ",")
                report.note("model", "\(model.id)  caps=[\(caps)]  defaultFeatures=\(model.defaultFeatureIDs)")
            }
            defaultModel = models.first?.id
        }
        guard let model = defaultModel else { report.dump(); exit(1) }

        // ---- 4. the socket side channel ------------------------------------
        let socket = ChatEventSocket(server: server)
        await report.check("socket.io connects with the bearer token") {
            try await socket.connect(timeout: .seconds(15))
        }

        var chatID: String?
        await report.check("create chat (POST /chats/new)") {
            chatID = try await client.createChat(title: "tiAi probe — safe to delete").id
        }
        guard let newChat = chatID else { report.dump(); exit(1) }

        // Leave the bytes on disk; the decoder gets written against these, not
        // against a 200-character console sample.
        let feed = FrameFeed(socket: socket, chatID: newChat, dumpTo: env["TIAI_FRAMES"] ?? "tiai-frames.jsonl")

        let prompt = "Reply with exactly this text and nothing else: TIAI-PROBE-OK"
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString

        await report.check("completion arrives over the socket (REST body is empty by design)") {
            let request = CompletionRequest(
                model: model,
                messages: [CompletionRequest.WireMessage(id: userMessageID, role: "user", content: .text(prompt))],
                chatID: newChat,
                parentID: .root,
                userMessage: CompletionRequest.WireMessage(
                    id: userMessageID, role: "user", content: .text(prompt), parentID: nil, model: model),
                messageID: assistantMessageID,
                features: [:],
                stream: true)

            // The POST does not return until the model has finished — the
            // server awaits the whole generation inside the request and answers
            // with an empty body at the end. So the POST and the frame
            // collection have to run at the same time, and the POST has to be
            // started before anything is awaited.
            let post = Task { try await client.stream(request).drain() }
            let outcome = await feed.collect(timeout: Self.completionTimeout)
            _ = await post.result
            feed.report(report, outcome)

            guard !outcome.text.isEmpty else {
                throw ProbeError.failure(
                    "\(outcome.total) frames arrived but none carried content — the delta path is wrong"
                    + (outcome.otherChats > 0
                        ? " (\(outcome.otherChats) frames were for other chats)"
                        : ""))
            }
            guard outcome.text.contains("TIAI-PROBE-OK") else {
                throw ProbeError.failure("streamed text does not match what was asked for")
            }
            guard outcome.sawDone || outcome.sawFinish else {
                throw ProbeError.failure("no terminal frame (neither done nor finish_reason)")
            }
            // Deliberately not an ordering assertion. Reasoning normally leads,
            // but nothing promises it, and a client that requires an order will
            // fail on a model that interleaves them. Both are captured; the app
            // renders them in separate places.
            if let thinking = outcome.firstReasoning, let token = outcome.firstToken, thinking > token {
                report.note("note", "reasoning lagged the answer by \(Probe.string(thinking - token))")
            }
        }

        // ---- 5. the transcript is actually on the server -------------------
        await report.check("server persisted the exchange (GET /chats/{id})") {
            try await Task.sleep(for: .seconds(2))
            let thread = try await client.chat(id: newChat).thread
            report.note("persisted turns", thread.map(\.role).joined(separator: " → "))
            guard thread.contains(where: { $0.isUser && $0.content.text.contains("TIAI-PROBE-OK") }) else {
                throw ProbeError.failure("the user turn is missing from the transcript")
            }
            guard let assistant = thread.last(where: \.isAssistant), !assistant.content.text.isEmpty else {
                throw ProbeError.failure("the assistant turn is empty")
            }
            report.note("assistant text", String(assistant.content.text.prefix(80)))
            report.note("done flag", assistant.done ? "true" : "false")
            report.note("status trail", "\(assistant.statusHistory.count) entries")
            report.note("sources", "\(assistant.sources?.count ?? 0) entries")
        }

        // ---- 6. stop a generation for real ---------------------------------
        await report.check("stop a running generation (POST /api/tasks/chat/{id}/stop)") {
            let id = UUID().uuidString
            let long = "Count slowly from 1 to 500, one number per line, with a short comment on each."
            let request = CompletionRequest(
                model: model,
                messages: [CompletionRequest.WireMessage(id: id, role: "user", content: .text(long))],
                chatID: newChat,
                parentID: .message(assistantMessageID),
                userMessage: CompletionRequest.WireMessage(
                    id: id, role: "user", content: .text(long), parentID: assistantMessageID, model: model),
                messageID: UUID().uuidString,
                stream: true)

            // Stop has to happen while the POST is still in flight, which is
            // exactly what the app's Stop button has to do too.
            // A second feed: the first one's stream was ended by its watchdog,
            // and reusing it is how this step reported "nothing arrived".
            let stopFeed = FrameFeed(socket: socket, chatID: newChat)
            let post = Task { try await client.stream(request).drain() }
            var deltas = 0
            let deadline = Task {
                try? await Task.sleep(for: .seconds(60))
                stopFeed.finish()
            }
            for await frame in stopFeed.frames {
                if frame.delta != nil { deltas += 1 }
                if deltas > 5 {
                    try? await client.stop(chatID: newChat)
                    break
                }
            }
            deadline.cancel()
            _ = await post.result
            report.note("deltas before stop", deltas)
            guard deltas > 0 else { throw ProbeError.failure("nothing arrived to stop") }

            try await Task.sleep(for: .seconds(2))
            let after = try await client.chat(id: newChat).thread.last(where: \.isAssistant)
            report.note("stopped message length", "\(after?.content.text.count ?? 0) chars")
        }

        socket.disconnect()

        // ---- 7. the screens that are not chat ------------------------------
        await report.check("memories (GET /memories/)") { report.note("memories", try await client.memories().count) }
        await report.check("prompts (GET /prompts/)") { report.note("prompts", try await client.prompts().count) }
        await report.check("chat list (GET /chats/list)") { report.note("chats", try await client.chatList().count) }

        // ---- 8. clean up the chat this probe made --------------------------
        await report.check("delete the probe chat (DELETE /chats/{id})") { try await client.deleteChat(id: newChat) }

        report.dump()
        exit(report.failed == 0 ? 0 : 1)
    }
}

extension ChatEventStream {
    /// Reads a completion stream to the end. The body is empty when a message id
    /// was sent; draining it is what keeps the connection honest and the error
    /// handling honest too — a 401 surfaces from here.
    func drain() async throws {
        for try await _ in self {}
    }
}

/// A lock-guarded counter, so the socket callback can tally frames it ignores
/// without the probe pretending Swift 6 concurrency does not exist.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Collects the socket frames belonging to one chat, with a deadline that
/// actually fires.
@MainActor
final class FrameFeed {
    let frames: AsyncStream<ChatEventSocket.Frame>
    private let continuation: AsyncStream<ChatEventSocket.Frame>.Continuation
    private let dropped = Counter()
    /// Appends every frame to a file so the decoder can be written against real
    /// traffic instead of a truncated console sample.
    private let dump: ((String) -> Void)?

    struct Outcome {
        var text = ""
        var reasoning = ""
        var firstToken: Duration?
        var usage: TokenUsage?
        var kinds: [String: Int] = [:]
        var samples: [String: String] = [:]
        var sawDone = false
        var sawFinish = false
        var firstReasoning: Duration?
        var errors: [String] = []
        var timedOut = false
        var otherChats = 0
        var total = 0
    }

    init(socket: ChatEventSocket, chatID: String, dumpTo: String? = nil) {
        let (stream, cont) = AsyncStream.makeStream(of: ChatEventSocket.Frame.self, bufferingPolicy: .unbounded)
        frames = stream
        continuation = cont
        if let dumpTo { dump = FrameFeed.appending(to: dumpTo) } else { dump = nil }
        let dropped = self.dropped
        // Frames for other chats are counted, not dropped silently: "no frames
        // arrived" and "frames arrived for a chat id we did not expect" are
        // different bugs, and the first probe run needs to be able to tell them
        // apart.
        socket.onFrame { frame in
            if frame.chatID == chatID { cont.yield(frame) } else { dropped.bump() }
        }
    }

    /// Ends the feed. Used by the stop check, which only needs the first frames.
    func finish() { continuation.finish() }

    /// Line-oriented append, opened once. Cheap, and it means the probe run
    /// leaves behind the exact bytes the server sent.
    private static func appending(to path: String) -> ((String) -> Void)? {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        return { line in
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        }
    }

    func collect(timeout: Duration) async -> Outcome {
        var outcome = Outcome()
        // The watchdog, not a check inside the loop: if nothing ever arrives the
        // loop body never runs, and a deadline read there is a deadline that
        // never happens.
        let continuation = self.continuation
        var watchdog = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        let started = ContinuousClock.now
        for await frame in frames {
            dump?(frame.raw + "\n")
            outcome.total += 1
            outcome.kinds[frame.kind, default: 0] += 1
            if outcome.samples[frame.kind] == nil { outcome.samples[frame.kind] = String(frame.raw.prefix(400)) }
            if let delta = frame.delta {
                // The opening chunk carries an empty delta alongside the role.
                // Counting it as the first token reports the moment the server
                // accepted the job, not the moment text appeared.
                if outcome.firstToken == nil && !delta.isEmpty {
                    outcome.firstToken = started.duration(to: .now)
                }
                outcome.text += delta
            }
            if let thinking = frame.reasoningDelta {
                // Reasoning arrives before the answer, so it must not count as
                // time to first token - that number is what tells a user whether
                // the model is thinking or the link is dead.
                if outcome.firstReasoning == nil { outcome.firstReasoning = started.duration(to: .now) }
                outcome.reasoning += thinking
            }
            outcome.usage = frame.usage ?? outcome.usage
            if let error = frame.errorText { outcome.errors.append(error) }
            if frame.isFinish && !outcome.sawFinish {
                outcome.sawFinish = true
                // The model is done talking; the server still has to write the
                // transcript and emit the terminal frame. Give it a moment
                // rather than sitting on the 120 s watchdog for a frame that may
                // never come.
                watchdog.cancel()
                watchdog = Task {
                    try? await Task.sleep(for: .seconds(5))
                    continuation.finish()
                }
            }
            if frame.isTerminal { outcome.sawDone = frame.isDone; break }
        }
        watchdog.cancel()
        outcome.otherChats = dropped.count
        if !outcome.sawDone { outcome.timedOut = true }
        return outcome
    }

    func report(_ report: Report, _ outcome: Outcome) {
        for kind in outcome.kinds.keys.sorted() {
            report.note("event \(kind)", "x\(outcome.kinds[kind] ?? 0)  \(outcome.samples[kind] ?? "")")
        }
        report.note("frames", "\(outcome.total) for this chat, \(outcome.otherChats) for others")
        report.note("finish_reason seen", outcome.sawFinish ? "yes" : "no")
        for error in outcome.errors.prefix(3) { report.note("stream error", String(error.prefix(160))) }
        report.note("time to first reasoning", outcome.firstReasoning.map(Probe.string) ?? "none")
        report.note("time to first token", Probe.string(outcome.firstToken ?? .zero))
        report.note("reasoning", "\(outcome.reasoning.count) chars")
        report.note("text", String(outcome.text.prefix(120)).replacingOccurrences(of: "\n", with: " "))
        report.note(
            "usage", outcome.usage.map { "\($0.promptTokens ?? 0) in / \($0.completionTokens ?? 0) out" }
                ?? "none reported")
        report.note(
            "terminal event",
            outcome.sawDone
                ? "done"
                : (outcome.sawFinish
                    ? "finish_reason, no done frame - the app must treat this as the end" : "none (timed out)"))
    }
}

enum ProbeError: Error {
    case failure(String)
}

/// Pass/fail with the measurements next to it. Deliberately not a test target:
/// a test needs a fixture and this is the opposite of that.
@MainActor
final class Report {
    private var lines: [String] = []
    private(set) var failed = 0

    func check(_ name: String, _ body: () async throws -> Void) async {
        print("  … \(name)")
        do {
            try await body()
            lines.append("  PASS  \(name)")
        } catch let error as ProbeError {
            failed += 1
            if case let .failure(message) = error { lines.append("  FAIL  \(name): \(message)") }
        } catch let error as APIError {
            failed += 1
            lines.append("  FAIL  \(name): \(error.localizedDescription)")
        } catch {
            failed += 1
            lines.append("  FAIL  \(name): \(error)")
        }
    }

    func note(_ label: String, _ value: Any) {
        lines.append("        \(label): \(value)")
    }

    func dump() {
        for line in lines { Swift.print(line) }
        Swift.print(failed == 0 ? "\nAll checks passed." : "\n\(failed) check(s) failed.")
    }
}

extension Probe {
    static func string(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.1fs", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}
