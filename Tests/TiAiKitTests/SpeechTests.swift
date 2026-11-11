import Foundation
import Testing
@testable import TiAiKit

@Test("sentences split on punctuation followed by a space, not on every dot")
func sentenceSplitting() {
    // Splitting on the character alone turns a numbered list and a URL into
    // confetti — "1." becomes its own utterance and gets read as "one point".
    #expect(SpeechText.sentences("Alpha. Beta. Gamma") == ["Alpha.", "Beta.", "Gamma"])
    #expect(SpeechText.sentences("See 1. Fundament now").count == 1)
    #expect(SpeechText.sentences("One\nTwo") == ["One", "Two"])
}

@Test("code is dropped rather than read out")
func codeIsNotSpoken() {
    let md = """
    Set it up:

    ```python
    def perform(x): return x
    ```

    That is all.
    """
    let chunks = SpeechText.chunks(md)
    let joined = chunks.joined(separator: " ")
    #expect(!joined.contains("def"))
    #expect(!joined.contains("python"))
    #expect(joined.contains("Set it up"))
    #expect(joined.contains("That is all."))
}

@Test("long answers arrive in speakable pieces, never mid-word")
func chunkingKeepsWholeSentences() {
    let sentence = "The quick brown fox jumps over the lazy dog."
    let long = Array(repeating: sentence, count: 60).joined(separator: " ")
    let chunks = SpeechText.chunks(long)
    #expect(chunks.count > 1, "one giant request would make the reader wait for all of it")
    for chunk in chunks {
        #expect(chunk.count <= SpeechText.chunkLimit + sentence.count,
                "a chunk may exceed the limit only by being one long sentence")
        // Every chunk is whole sentences, so nothing is cut mid-word.
        #expect(!chunk.hasSuffix("do"), "cut mid-word: \(chunk.suffix(20))")
    }
    // Nothing is lost between the pieces.
    #expect(chunks.joined(separator: " ").split(separator: " ").count
            == long.split(separator: " ").count)
}

@Test("markdown formatting does not come along")
func markupIsStrippedForSpeech() {
    let chunks = SpeechText.chunks("## Title\n\nUse **bold** and `code` here.")
    let joined = chunks.joined(separator: " ")
    #expect(!joined.contains("##"))
    #expect(!joined.contains("**"))
    #expect(!joined.contains("`"))
    #expect(joined.contains("Title"))
}

@Test("an empty answer says so instead of going quiet")
func nothingToRead() {
    #expect(SpeechText.chunks("   \n\n  ").isEmpty)
    #expect(SpeechText.chunks("```\nonly code\n```").isEmpty)
}

@Test("a failed read-aloud reports itself instead of going silent")
@MainActor func failureIsReported() async throws {
    // Issue #47: the speaker button used to flip its icon back with no
    // explanation. The failure has to land in `error` for the banner to show.
    final class FailingTransport: APITransport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), http)
        }
        func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (ByteStream { AsyncThrowingStream { $0.finish() } }, http)
        }
    }
    let client = OWUIClient(
        server: Server(baseURL: URL(string: "https://chat.example.co")!, token: "tok"),
        transport: FailingTransport())
    let player = SpeechPlayer(client: client)

    player.read("Hello there.")
    // `read` runs the request in a task; wait for it to settle.
    for _ in 0..<200 where player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }

    #expect(!player.isPlaying)
    let message = try #require(player.error)
    #expect(message.contains("text-to-speech"), "got: \(message)")

    // The banner's dismiss button goes through this; a stale error must not
    // survive it.
    player.dismissError()
    #expect(player.error == nil)
}
