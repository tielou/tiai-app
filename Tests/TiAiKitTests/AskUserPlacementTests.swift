import Foundation
import Testing
@testable import TiAiKit

/// Recorded from a live 0.12.3 chat where the model wrote a 4000-character
/// answer and *then* asked three questions. The app showed the answer and no
/// questions at all — not because the call was missing (it parsed fine) but
/// because every call was drawn above the text, so the questions sat a full
/// screen above what the user was looking at.
@Test("a question asked after the answer belongs below it")
func questionFollowsTheAnswer() throws {
    let data = Fixture.data("ask-user-after-answer.json")
    let message = try JSONDecoder().decode(ChatMessage.self, from: data)
    let turn = Turn(message)

    let ask = try #require(turn.calls.first { $0.isAskUser })
    #expect(ask.isAwaitingUser)
    #expect(ask.afterText)

    // The whole point: the question is on the far side of the prose, not the
    // near side, so it is on screen with the answer it follows.
    let afterHasQuestion = turn.callsAfterText.contains { $0.isAskUser }
    let beforeHasQuestion = turn.callsBeforeText.contains { $0.isAskUser }
    #expect(afterHasQuestion)
    #expect(!beforeHasQuestion)

    let prompt = try #require(AskUserPrompt(arguments: ask.arguments))
    #expect(prompt.questions.count == 3)
    #expect(prompt.questions.first?.header == "Geräte")
}

@Test("a tool that produced the answer still sits above it")
func toolCallBeforeTheAnswerStaysAbove() throws {
    let json = """
    {"id":"m2","role":"assistant","done":false,"content":"The file is ready.",
     "output":[{"type":"function_call","name":"display_file","call_id":"c1","id":"c1",
                "status":"completed","arguments":"{\\"path\\":\\"/home/user/a.pdf\\"}"},
               {"type":"message","message":"The file is ready."}]}
    """
    let message = try JSONDecoder().decode(
        ChatMessage.self, from: Data(json.utf8))
    let turn = Turn(message)
    #expect(turn.callsBeforeText.count == 1)
    #expect(turn.callsAfterText.isEmpty)
}

// Tool cards belong above the answer — they are the work that produced it. Only
// `ask_user` is position-sensitive, because a question asked after an answer has
// to sit under it or the user scrolls back to find what was asked.
@Test func ordinaryToolCallsStayAboveTheAnswer() throws {
    func call(_ id: String, _ name: String) throws -> ToolCall {
        let text = "{\"type\":\"function_call\",\"call_id\":\"\(id)\",\"name\":\"\(name)\",\"arguments\":\"{}\"}"
        return try #require(ToolCall(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))))
    }
    var turn = Turn(id: "m1", role: "assistant")
    turn.calls = try [call("c1", "sonos"), call("c2", "ask_user")].map {
        var c = $0; c.afterText = true; return c
    }
    #expect(turn.calls.first { $0.id == "c2" }?.isAskUser == true)
    #expect(turn.callsBeforeText.map(\.id) == ["c1"],
            "a tool that ran after the text still belongs at the top")
    #expect(turn.callsAfterText.map(\.id) == ["c2"],
            "only the question stays where it was asked")
}
