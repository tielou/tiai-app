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

// MARK: - StreamingSentenceReader (issue #53)

@Test func theReaderHoldsTheLastSentenceUntilItIsProvedComplete() {
    var r = StreamingSentenceReader()
    // One sentence, however final it looks, is still the LAST one: it is
    // held. Emitting it and then receiving " more" would speak a word twice.
    #expect(r.feed("Hello world.") == [])
    #expect(r.feed("Hello world. Se") == ["Hello world."])
    #expect(r.feed("Hello world. Second one. Thi") == ["Second one."])
    // The flush is the only way the tail comes out, and it comes out once.
    // ("Second one." already went out with the feed that proved it.)
    #expect(r.flush("Hello world. Second one. Third one.") == ["Third one."])
    #expect(r.flush("Hello world. Second one. Third one.") == [])
}

@Test func theReaderNeverRepeatsAcrossFeeds() {
    var r = StreamingSentenceReader()
    var heard: [String] = []
    let full = "Alpha. Beta. Gamma. Delta. Epsilon"
    // Feed it one character at a time: the worst case for a splitter.
    for i in 1...full.count {
        heard += r.feed(String(full.prefix(i)))
    }
    heard += r.flush(full)
    #expect(heard == ["Alpha.", "Beta.", "Gamma.", "Delta.", "Epsilon"])
}

@Test func theReaderKeepsTheListMarkerAndUrlTraps() {
    var r = StreamingSentenceReader()
    // "1." is a list marker, not a sentence end; the whole line is ONE
    // sentence and must not come out until a successor exists.
    #expect(r.feed("Steps: 1. Fundament is the base. Next") == ["Steps: 1. Fundament is the base."])
    var u = StreamingSentenceReader()
    #expect(u.feed("See https://example.com/page for more. Done") == ["See https://example.com/page for more."])
}

@Test func theReaderStaysQuietInsideAStreamingCodeFence() {
    var r = StreamingSentenceReader()
    // Fences live on their own lines (that is what stripCode keys on).
    // Mid-fence the code is not speakable, and the sentence before the
    // fence is only released once something provably follows it.
    #expect(r.feed("Intro.\n```\ncode()") == [])
    #expect(r.feed("Intro.\n```\ncode()\n```") == [])
    // Fence closed, prose after it: stripCode leaves "Intro." and "Out".
    #expect(r.feed("Intro.\n```\ncode()\n```\nOut") == ["Intro."])
    #expect(r.flush("Intro.\n```\ncode()\n```\nOut") == ["Out"])
}

@Test func theReaderSurvivesASettledSingleSentenceAnswer() {
    // The shape every short answer takes: nothing ever streams out, and
    // the settle flush says the whole thing — identical to the pre-#53
    // whole-text read.
    var r = StreamingSentenceReader()
    #expect(r.feed("MAGIC") == [])
    #expect(r.flush("MAGIC") == ["MAGIC"])
}

// MARK: - language-aware voice + prefetch (TTS improvement, no issue)

@Test("the language of the answer picks the voice; english keeps the server default")
func languagePicksTheVoice() {
    // Detection needs a few words to have an opinion; real answers always
    // have them. English is deliberately NOT in the map — the server
    // default is English and stays the authority for it.
    #expect(VoiceLanguage.voice(
        for: "Hallo, hier ist eine ausfuehrliche Antwort auf Deutsch, damit die Erkennung etwas hat.")
        == "de-DE-KatjaNeural")
    #expect(VoiceLanguage.voice(
        for: "Bonjour, voici une reponse un peu longue en francais pour la reconnaissance.")
        == "fr-FR-DeniseNeural")
    #expect(VoiceLanguage.voice(
        for: "Hello, this is a longer English answer so the recognizer has something to work with.")
        == nil)
}

/// Transport that answers /audio/speech with a small body, records the
/// `voice` of every request and the moment each request started, and takes
/// a beat per request so fetch/play overlap is observable.
@MainActor
final class SpeechRecordingTransport: APITransport, @unchecked Sendable {
    struct Call { let voice: String?; let started: Date }
    var calls: [Call] = []
    var fetchDelay: Duration = .milliseconds(100)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls.append(Call(voice: Self.voice(in: request), started: .now))
        try await Task.sleep(for: fetchDelay)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"])!
        return (Data([0xFF, 0xFB, 0x90, 0x00]), http)
    }
    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (ByteStream { AsyncThrowingStream { $0.finish() } }, http)
    }

    private static func voice(in request: URLRequest) -> String? {
        guard let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: String]
        else { return nil }
        return json["voice"]
    }
}

/// Playback seam double: "plays" by sleeping, and records when it finished.
@MainActor
final class FakeSpeechEngine: SpeechPlaying, @unchecked Sendable {
    private(set) var playEnds: [Date] = []
    var playTime: Duration = .milliseconds(300)

    func play(data: Data, mime: String) async {
        try? await Task.sleep(for: playTime)
        playEnds.append(.now)
    }
    func stop() {}
}

@Test("a picked voice always wins over the detected language")
@MainActor func userVoiceWins() async throws {
    let transport = SpeechRecordingTransport()
    let client = OWUIClient(
        server: Server(baseURL: URL(string: "https://chat.example.co")!, token: "tok"),
        transport: transport)
    let player = SpeechPlayer(client: client, engine: FakeSpeechEngine())
    let german = "Hallo, hier ist eine ausfuehrliche Antwort auf Deutsch, damit die Erkennung etwas hat."

    player.read(german)
    for _ in 0..<200 where player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
    #expect(transport.calls.allSatisfy { $0.voice == "de-DE-KatjaNeural" })

    transport.calls.removeAll()
    player.setVoice("my-voice")
    player.read(german)
    for _ in 0..<200 where player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!transport.calls.isEmpty)
    #expect(transport.calls.allSatisfy { $0.voice == "my-voice" })
}

@Test("the next chunk is fetched while the current one is still playing")
@MainActor func prefetchOverlapsPlayback() async throws {
    // Three chunks: fetch takes 100ms, playback 300ms. Sequential code
    // starts fetch #2 only after play #1 ends (~400ms in); a prefetching
    // reader starts it right after fetch #1 lands (~100ms in). The margin
    // is wide enough that a loaded CI runner cannot flip the verdict.
    let transport = SpeechRecordingTransport()
    let engine = FakeSpeechEngine()
    let client = OWUIClient(
        server: Server(baseURL: URL(string: "https://chat.example.co")!, token: "tok"),
        transport: transport)
    let player = SpeechPlayer(client: client, engine: engine)

    let sentence = String(repeating: "wort ", count: 130)   // ~650 chars, one chunk each
    player.read("\(sentence). A. \(sentence). B. \(sentence). C.")
    for _ in 0..<500 where player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }

    #expect(transport.calls.count >= 2)
    #expect(engine.playEnds.count >= 1)
    let margin: TimeInterval = 0.15
    #expect(transport.calls[1].started.timeIntervalSince(transport.calls[0].started)
            < engine.playEnds[0].timeIntervalSince(transport.calls[0].started) - margin,
            "chunk 2 was fetched only after chunk 1 finished playing — no prefetch")
}
