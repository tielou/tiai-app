import Foundation
import TiAiKit

// tiaiprobe — the M0 spike.
//
// A command-line client that runs the assumptions this app is built on against
// a real Open WebUI instance and says which ones held. It exists because two of
// those assumptions cannot be settled by reading the web UI's source:
//
//   1. that a completion streams over plain REST SSE with no websocket session
//      (Open WebUI emits its *rich* events over socket.io; the REST path is a
//      pass-through of the upstream chunks),
//   2. that the server persists the transcript well enough that a REST-only
//      client can reconcile a finished message from `GET /chats/{id}`.
//
// If either is false the plan changes, so this runs before anything is built on
// top of it.
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
        await report.check("health (GET /health)") {
            _ = try await client.health()
        }
        if let version = try? await client.version() {
            report.note("version", version.version)
        }
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
                report.note(
                    "model",
                    "\(model.id)  name=\(model.name)  caps=[\(caps)]  defaultFeatures=\(model.defaultFeatureIDs)")
            }
            defaultModel = models.first?.id
        }
        guard let model = defaultModel else {
            report.dump()
            exit(1)
        }

        // ---- 4. the socket side channel ------------------------------------
        // Round 3 of the probe established that a completion carrying a message
        // id returns an EMPTY REST body: the server writes the reply to the chat
        // and emits the content here instead. So this is the streaming path, and
        // the first run of this section doubles as a capture of the server's real
        // event vocabulary.
        let socket = ChatEventSocket(server: server)
        await report.check("socket.io connects with the bearer token") {
            try await socket.connect()
        }

        var chatID: String?
        await report.check("create chat (POST /chats/new)") {
            chatID = try await client.createChat(title: "tiAi probe — safe to delete").id
        }
        guard let newChat = chatID else {
            report.dump()
            exit(1)
        }

        let (frames, continuation) = AsyncStream<ChatEventSocket.Frame>.makeStream()
        socket.onFrame { frame in
            if frame.chatID == newChat { continuation.yield(frame) }
        }

        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        let prompt = "Reply with exactly this text and nothing else: TIAI-PROBE-OK"

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

        var firstToken: Duration?
        var received = ""
        var usage: TokenUsage?
        var sawDone = false
        var kinds: [String: Int] = [:]
        var samples: [String: String] = [:]

        let started = ContinuousClock.now
        await report.check("completion arrives over the socket (POST returns empty by design)") {
            // The REST call returns as soon as the server has taken the job.
            for try await _ in try await client.stream(request) {}

            let deadline = ContinuousClock.now + .seconds(90)
            for await frame in frames {
                if ContinuousClock.now > deadline { break }
                kinds[frame.kind, default: 0] += 1
                if samples[frame.kind] == nil {
                    samples[frame.kind] = String(frame.raw.prefix(200))
                }
                if frame.delta != nil || frame.kind.contains("delta") {
                    if firstToken == nil { firstToken = started.duration(to: .now) }
                    received += frame.delta ?? ""
                }
                if let encoded = try? JSONEncoder().encode(frame.data),
                   let decoded = try? JSONDecoder().decode(UsageEnvelope.self, from: encoded)
                { usage = decoded.usage ?? usage }
                if frame.isDone { sawDone = true; break }
            }
            for kind in kinds.keys.sorted() {
                report.note("event \(kind)", "x\(kinds[kind] ?? 0)  \(samples[kind] ?? "")")
            }
            report.note("time to first token", Self.string(firstToken ?? .zero))
            report.note("text", String(received.prefix(120)).replacingOccurrences(of: "\n", with: " "))
            report.note("usage", usage.map { "\($0.promptTokens ?? 0) in / \($0.completionTokens ?? 0) out" } ?? "none reported")
            report.note("terminal done event", sawDone ? "yes" : "no (timed out or ended early)")
            guard !received.isEmpty else {
                throw ProbeError.failure("nothing arrived over the socket")
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
            let assistant = thread.last { $0.isAssistant }
            guard let assistant, !assistant.content.text.isEmpty else {
                throw ProbeError.failure("the assistant turn is empty")
            }
            report.note("assistant text", String(assistant.content.text.prefix(80)))
            report.note("assistant done flag", assistant.done ? "true" : "false")
            report.note("status trail", "\(assistant.statusHistory.count) entries")
            report.note("sources", "\(assistant.sources?.count ?? 0) entries")
        }

        // ---- 6. stop a generation for real ---------------------------------
        await report.check("stop a running generation (POST /api/tasks/chat/{id}/stop)") {
            let id = UUID().uuidString
            let longPrompt = "Count slowly from 1 to 500, one number per line, with a short comment on each."
            let request = CompletionRequest(
                model: model,
                messages: [
                    CompletionRequest.WireMessage(id: id, role: "user", content: .text(longPrompt))
                ],
                chatID: newChat,
                parentID: .message(assistantMessageID),
                userMessage: CompletionRequest.WireMessage(
                    id: id, role: "user", content: .text(longPrompt),
                    parentID: assistantMessageID, model: model),
                messageID: UUID().uuidString,
                stream: true)

            var deltas = 0
            try await client.stream(request)
            for await frame in frames {
                if frame.delta != nil {
                    deltas += 1
                    if deltas > 5 {
                        try await client.stop(chatID: newChat)
                        break
                    }
                }
            }
            guard deltas > 0 else { throw ProbeError.failure("nothing arrived to stop") }
            report.note("deltas before stop", "\(deltas)")
            try await Task.sleep(for: .seconds(2))
            let after = try await client.chat(id: newChat).thread.last { $0.isAssistant }
            report.note("stopped message length", "\(after?.content.text.count ?? 0) chars")
        }

        socket.disconnect()

        // ---- 7. the screens that are not chat ------------------------------
        await report.check("memories (GET /memories/)") {
            report.note("memories", try await client.memories().count)
        }
        await report.check("prompts (GET /prompts/)") {
            report.note("prompts", try await client.prompts().count)
        }
        await report.check("chat list (GET /chats/list)") {
            report.note("chats", try await client.chatList().count)
        }

        // ---- 8. clean up the chat this probe made --------------------------
        await report.check("delete the probe chat (DELETE /chats/{id})") {
            try await client.deleteChat(id: newChat)
        }

        report.dump()
        exit(report.failed == 0 ? 0 : 1)
    }

    private static func string(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.1fs", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}

/// Usage arrives as its own socket event, not on the stream.
private struct UsageEnvelope: Decodable { let usage: TokenUsage? }

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
