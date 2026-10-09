import Foundation
import Testing

@testable import TiAiKit

/// Frames captured from the live server (0.11.4) rather than invented. Content
/// lives at `data.data.choices[0].delta.content` — the upstream chunk relayed
/// almost verbatim — which is not where a first guess put it, and the probe could
/// see 50 content frames and still report "no text" because of it.
private func frame(_ json: String) -> ChatEventSocket.Frame? {
    guard let data = json.data(using: .utf8),
          let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ChatEventSocket.Frame(dictionary)
}

@Test func socketDeltaUsesTheOpenAIChunkPath() throws {
    let f = try #require(
        frame(
            """
            {"message_id":"4C66","chat_id":"62dd","data":{"type":"response:completion","data":{
              "id":"chatcmpl-4d8b","object":"chat.completion.chunk","created":1791532077,
              "model":"local-personal","choices":[{"index":0,"delta":{"content":"TIAI"},"finish_reason":null}]}}}
            """
        ))
    #expect(f.kind == "response:completion")
    #expect(f.chatID == "62dd")
    #expect(f.messageID == "4C66")
    #expect(f.delta == "TIAI")
    #expect(f.finishReason == nil)
    #expect(!f.isDone && !f.isFinish)
}

@Test func socketReasoningIsKeptApartFromContent() throws {
    let f = try #require(
        frame(
            """
            {"chat_id":"c","data":{"type":"response:completion","data":{"choices":[
              {"index":0,"delta":{"reasoning_content":"hmm"}}]}}}
            """
        ))
    #expect(f.delta == nil)
    #expect(f.reasoningDelta == "hmm")
}

@Test func socketFinishAndDoneAreDifferentThings() throws {
    let finish = try #require(
        frame(
            """
            {"chat_id":"c","data":{"type":"response:completion","data":{"choices":[
              {"index":0,"delta":{},"finish_reason":"stop"}]}}}
            """
        ))
    #expect(finish.isFinish)
    #expect(!finish.isDone)

    let done = try #require(frame(#"{"chat_id":"c","data":{"type":"response:completion","data":{"done":true}}}"#))
    #expect(done.isDone)
}

@Test func socketUsageDecodesFromTheChunk() throws {
    let f = try #require(
        frame(
            """
            {"chat_id":"c","data":{"type":"response:completion","data":{"choices":[],"usage":{
              "prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}}}
            """
        ))
    #expect(f.usage?.promptTokens == 11)
    #expect(f.usage?.completionTokens == 7)
}

@Test func socketIgnoresWhatItCannotParse() {
    #expect(frame("[]") == nil)
    // A frame whose payload is not an object still routes; it just has no kind.
    #expect(frame(#"{"chat_id":"c","data":"not an object"}"#)?.kind == "unknown")
}
