import Foundation
import AVFoundation

/// Splitting an answer into pieces worth speaking.
///
/// Two reasons this is not one request. A TTS engine has a context of its own and
/// a 4000-character answer will run past it, and the reader would wait for the
/// whole thing to synthesise before hearing a word. Chunking means the first
/// sentence plays while the rest is still being fetched.
///
/// Code is dropped rather than read out: "public func perform underscore open
/// paren" is not information, it is noise.
enum SpeechText {
    static let chunkLimit = 700

    static func chunks(_ markdown: String) -> [String] {
        let plain = TextSanitizer.plain(stripCode(markdown))
        var out: [String] = []
        var current = ""
        for sentence in sentences(plain) {
            // One sentence longer than the limit goes on its own rather than
            // being cut mid-word, which is audible.
            if !current.isEmpty, current.count + sentence.count + 1 > chunkLimit {
                out.append(current)
                current = ""
            }
            current = current.isEmpty ? sentence : current + " " + sentence
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Fenced blocks out, prose left alone.
    static func stripCode(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Sentences, split on terminal punctuation followed by a space or a line
    /// break, and on the line break itself.
    ///
    /// Two traps. A bare number before a dot is a list marker — "1. Fundament"
    /// read as "one point." then "Fundament" is worse than a long chunk. And a
    /// dot inside a word ("www.example.com") is not a boundary at all, which the
    /// following-space rule already handles.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { flush(); i += 1; continue }
            current.append(c)
            if ".!?…".contains(c) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if (next == " " || next == "\n"), !isListMarker(chars, dotAt: i) { flush() }
            }
            i += 1
        }
        flush()
        return out
    }

    /// True when the dot closes a numbered-list marker like `3.` rather than a
    /// sentence.
    private static func isListMarker(_ chars: [Character], dotAt: Int) -> Bool {
        var j = dotAt - 1
        var digits = 0
        while j >= 0, chars[j].isNumber { digits += 1; j -= 1 }
        guard digits > 0 else { return false }
        return j < 0 || chars[j] == " " || chars[j] == "\t"
    }
}

/// Plays an answer out loud.
///
/// Chunks are fetched one at a time and queued, so speech starts after the first
/// one lands. A failure on the first chunk is reported; a failure later on just
/// ends the reading, because losing the tail of an answer is not worth an error
/// banner over the transcript.
@MainActor
public final class SpeechPlayer: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?

    private let client: OWUIClient
    private var voice: String?
    private let engine = SpeechEngine()
    private var task: Task<Void, Never>?

    public init(client: OWUIClient) {
        self.client = client
    }

    public func setVoice(_ voice: String?) { self.voice = voice }

    /// Clears a reported failure. The banner that shows `error` has a dismiss
    /// button; a banner with no way to dismiss it is a permanent smear of red
    /// (the lesson from issue #9).
    public func dismissError() { error = nil }

    public func read(_ markdown: String) {
        stop()
        let chunks = SpeechText.chunks(markdown)
        guard !chunks.isEmpty else {
            error = "There is nothing to read in that message."
            return
        }
        error = nil
        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            for (index, chunk) in chunks.enumerated() {
                if Task.isCancelled { break }
                do {
                    let (data, type) = try await self.client.speech(text: chunk, voice: self.voice)
                    if Task.isCancelled { break }
                    await self.engine.play(data: data, mime: type)
                } catch {
                    // Only the first failure is worth saying out loud.
                    if index == 0 {
                        self.error = (error as? LocalizedError)?.errorDescription
                            ?? "Could not produce audio."
                    }
                    break
                }
            }
            self.isPlaying = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        engine.stop()
        isPlaying = false
    }
}

/// The audio hardware, kept out of the view model.
///
/// Split out because the session plumbing is platform-specific and the queueing
/// logic above is worth being able to read without that noise. Main-actor isolated
/// like its owner: `AVAudioPlayer` is, and the wait loop yields the actor while a
/// chunk plays rather than blocking it.
@MainActor
final class SpeechEngine {
    #if os(iOS)
    private var player: AVAudioPlayer?

    func play(data: Data, mime: String) async {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, options: [.interruptSpokenAudioAndMixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        guard let file = write(data, mime: mime) else { return }
        let player = try? AVAudioPlayer(contentsOf: file)
        self.player = player
        player?.play()
        // The queue is sequential by construction: the next chunk is not asked
        // for until this one has finished, which keeps memory flat on a long
        // answer instead of holding the whole reading in RAM.
        while let p = self.player, p.isPlaying {
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? FileManager.default.removeItem(at: file)
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func write(_ data: Data, mime: String) -> URL? {
        let ext: String
        switch mime.lowercased() {
        case let m where m.contains("wav"): ext = "wav"
        case let m where m.contains("ogg"): ext = "ogg"
        case let m where m.contains("flac"): ext = "flac"
        case let m where m.contains("mp4"): ext = "m4a"
        default: ext = "mp3"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiai-speech-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
    #else
    // The kit builds on macOS for tests; nothing here is exercised there.
    func play(data: Data, mime: String) async {}
    func stop() {}
    #endif
}
