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
