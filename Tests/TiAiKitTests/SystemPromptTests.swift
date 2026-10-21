import Foundation
import Testing

@testable import TiAiKit

/// The system prompt is a `system` message, not a `params` field.
///
/// This was wrong for a long time and looked completely healthy: `params.system`
/// is a real Open WebUI field, it appears on the wire, and the server accepts it
/// without complaint. It is just read from the *model's* admin-configured params
/// rather than from the request, so a client that sends it there changes nothing
/// about the answer. The only symptom is a feature that silently does not.
///
/// Serialized because the settings live in a process-wide singleton and the wire
/// tests write to it; run concurrently they read each other's prompts.
@Suite(.serialized) struct SystemPromptOnTheWire {
    @MainActor
    private func sentMessages(prompt: String) async throws -> [[String: Any]] {
        let server = Server(baseURL: URL(string: "https://test.invalid")!, token: "t")
        let transport = ScriptedTransport()
        let conversation = ConversationModel(
            chatID: nil,
            models: [ChatModel.stub("local-personal")],
            client: OWUIClient(server: server, transport: transport),
            hub: ChatEventHub(server: server))

        // Set after the model exists: pointing the store at a host reloads that
        // host's defaults, which would otherwise wipe what was just written.
        let store = SettingsStore.shared
        let previous = store.defaults.systemPrompt
        store.defaults.systemPrompt = prompt
        defer { store.defaults.systemPrompt = previous }

        conversation.draft = "hello there"
        conversation.send()
        try await transport.awaitCompletion()

        let raw = try #require(transport.completionBody)
        let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return try #require(json["messages"] as? [[String: Any]])
    }

    private func text(of message: [String: Any]) -> String {
        switch message["content"] {
        case let string as String: return string
        case let blocks as [[String: Any]]:
            return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        default: return ""
        }
    }

    @Test @MainActor func systemPromptTravelsAsASystemMessage() async throws {
        let messages = try await sentMessages(prompt: "Answer as a pirate.")
        let system = try #require(messages.first { ($0["role"] as? String) == "system" })
        #expect(text(of: system).contains("Answer as a pirate."),
                "the prompt must be in the message the server actually reads")
    }

    @Test @MainActor func systemMessageComesBeforeTheConversation() async throws {
        let messages = try await sentMessages(prompt: "Be terse.")
        let roles = messages.compactMap { $0["role"] as? String }
        #expect(roles.first == "system", "the system message goes in front of the history")
    }

    @Test @MainActor func noSystemPromptSendsNoSystemMessage() async throws {
        let messages = try await sentMessages(prompt: "   ")
        #expect(!messages.contains { ($0["role"] as? String) == "system" },
                "whitespace is not an instruction; sending it would override the server's own")
    }
}

@Test func anEmptyPromptLeavesTheRequestAlone() {
    let history = [CompletionRequest.WireMessage(id: "1", role: "user", content: .text("hi"))]
    #expect(ConversationModel.systemPrefixed(history, prompt: "").count == 1)
    #expect(ConversationModel.systemPrefixed(history, prompt: "\n\t ").count == 1)
    let withPrompt = ConversationModel.systemPrefixed(history, prompt: "Be brief")
    #expect(withPrompt.count == 2)
    #expect(withPrompt.first?.role == "system")
}

/// A model configured in the admin panel with its own system prompt wins: the
/// server applies it over whatever arrives, replacing `messages[0]`. Nothing the
/// app can do about that, but it is worth knowing which side wins when a prompt
/// appears to be ignored.
@Test func anExistingSystemMessageIsNotDoubled() {
    let history = [
        CompletionRequest.WireMessage(id: "s", role: "system", content: .text("already there")),
        CompletionRequest.WireMessage(id: "u", role: "user", content: .text("hi")),
    ]
    let out = ConversationModel.systemPrefixed(history, prompt: "Be brief")
    #expect(out.count == 2, "two system messages would make the server keep only one anyway")
}
