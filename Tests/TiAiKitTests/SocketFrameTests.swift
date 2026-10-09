import Foundation
import Testing

@testable import TiAiKit

/// Frames captured from the live server (0.11.4) — `tiai-frames.jsonl`, the
/// probe's own capture — not invented. They are reproduced here verbatim because
/// the shape is the surprising part and no amount of reading the web UI's source
/// produced it correctly on the first two attempts.
private func frame(_ json: String) throws -> ChatEventSocket.Frame {
    let data = try #require(json.data(using: .utf8))
    let dictionary = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(ChatEventSocket.Frame(dictionary))
}

/// The opening frame. An OpenAI chunk whose content is empty; it only announces
/// the role. A client that treats "first frame with a delta key" as the first
/// token measures 0 ms and shows nothing.
private let opener = """
{"message_id":"7B24","chat_id":"24e6","data":{"type":"response:completion","data":{"id":"chatcmpl-b2fc",\
"object":"chat.completion.chunk","created":1791532592,"model":"local-personal",\
"choices":[{"index":0,"delta":{"content":"","role":"assistant"}}]}}}
"""

/// A thinking token. Same envelope type as the answer, different inner type, and
/// it arrives first — 41 of these before the answer started.
private let reasoning = """
{"message_id":"7B24","chat_id":"24e6","data":{"type":"response:completion","data":{"delta":"The",\
"content_index":0,"type":"response.reasoning_text.delta","item_id":"r_811f","output_index":0}}}
"""

/// An answer token. `output_index` 1 vs 0 is the other tell.
private let output = """
{"message_id":"7B24","chat_id":"24e6","data":{"type":"response:completion","data":{"delta":"OK",\
"content_index":0,"type":"response.output_text.delta","item_id":"msg_7db4","output_index":1}}}
"""

/// The terminal frame. Note there is no `done` anywhere in a real run: this is
/// the only end-of-stream signal, and it arrives under `chat:completion`.
private let terminal = """
{"data":{"type":"chat:completion","data":{"id":"chatcmpl-b2fc","object":"chat.completion.chunk",\
"created":1791532592,"model":"local-personal","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}},\
"chat_id":"24e6","message_id":"7B24"}
"""

@Test func openingChunkAnnouncesTheRoleAndCarriesNoText() throws {
    let f = try frame(opener)
    #expect(f.kind == "response:completion")
    #expect(f.chatID == "24e6")
    #expect(f.messageID == "7B24")
    #expect(f.delta == "")
    #expect(f.reasoningDelta == nil)
    #expect(!f.isTerminal)
}

@Test func reasoningDeltasAreNotAnswerDeltas() throws {
    let r = try frame(reasoning)
    #expect(r.kind == "response:completion")
    #expect(r.innerType == "response.reasoning_text.delta")
    #expect(r.reasoningDelta == "The")
    #expect(r.delta == nil)

    let o = try frame(output)
    #expect(o.innerType == "response.output_text.delta")
    #expect(o.delta == "OK")
    #expect(o.reasoningDelta == nil)
}

@Test func terminalFrameIsFinishReasonNotDone() throws {
    let f = try frame(terminal)
    #expect(f.kind == "chat:completion")
    #expect(f.finishReason == "stop")
    #expect(f.isFinish)
    #expect(!f.isDone)  // nothing in a real run ever sets `done`
    #expect(f.isTerminal)
}

@Test func aWholeRunReconstructsInTheRightOrder() throws {
    // The property that actually matters: concatenating the answer deltas in
    // arrival order, excluding reasoning, yields the answer and nothing else.
    let frames = try [opener, reasoning, output].map { try frame($0) }
    #expect(frames.compactMap(\.delta).joined() == "OK")
    #expect(frames.compactMap(\.reasoningDelta).joined() == "The")
}

@Test func usageIsReadWhereProvidersPutIt() throws {
    let flat = try frame(
        #"{"chat_id":"c","data":{"type":"response:completion","data":{"type":"response.completed","usage":{"prompt_tokens":11,"completion_tokens":7}}}}"#)
    #expect(flat.usage?.promptTokens == 11)

    let nested = try frame(
        #"{"chat_id":"c","data":{"type":"response:completion","data":{"choices":[{"index":0,"delta":{},"usage":{"total_tokens":18}}]}}}"#)
    #expect(nested.usage?.totalTokens == 18)
}

@Test func malformedFramesAreIgnoredRatherThanCrashing() {
    #expect(ChatEventSocket.Frame(["data": "not an object"] as [String: Any])?.kind == "unknown")
    #expect(ChatEventSocket.Frame(["chat_id": "c"] as [String: Any])?.delta == nil)
}

/// The whole capture, replayed. This is the test that would have caught both
/// decoding mistakes: it asserts the properties that matter — the answer
/// reconstructs exactly, reasoning stays separate, exactly one terminal frame —
/// against 52 frames of real traffic rather than three hand-picked ones.
@Test func realCaptureReplaysIntoOneAnswer() throws {
    let lines = Fixture.string("socket-frames.jsonl")
        .split(separator: "\n", omittingEmptySubsequences: true)
    let frames = try lines.map { line -> ChatEventSocket.Frame in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let dictionary = try #require(object as? [String: Any])
        return try #require(ChatEventSocket.Frame(dictionary))
    }
    #expect(frames.count == 52)

    // Every frame belongs to one chat and one message: the filter the app keys
    // its conversation state on.
    #expect(Set(frames.compactMap(\.chatID)).count == 1)
    #expect(Set(frames.compactMap(\.messageID)).count <= 2)

    let answer = frames.compactMap(\.delta).joined()
    #expect(answer == "TIAI-PROBE-OK")
    #expect(frames.compactMap(\.reasoningDelta).joined().count > 100)

    let terminal = frames.filter(\.isTerminal)
    #expect(terminal.count == 1)
    #expect(terminal.first?.finishReason == "stop")

    // Nothing in the capture is silently dropped. Every frame is content,
    // reasoning, terminal, or a chat-list invalidation - including the opening
    // frame, whose delta is the empty string rather than nil.
    let understood = frames.filter {
        $0.delta != nil || $0.reasoningDelta != nil || $0.isTerminal || $0.kind == "chat:list"
    }
    #expect(understood.count == frames.count)
}
