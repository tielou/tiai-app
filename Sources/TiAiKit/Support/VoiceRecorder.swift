#if os(iOS)
import AVFoundation
import Foundation

/// Records a short voice note and hands the text back.
///
/// The app records and the server transcribes. `OWUIClient.transcribe` posts to
/// Open WebUI's own `/audio/transcriptions`, so which model does the work —
/// Whisper today, something else next month — is a server setting and never an
/// app release. That also means the app inherits the instance's language
/// detection and its splitting of long audio for free.
///
/// 16 kHz mono AAC at 32 kbit/s: that is what Whisper wants on the input side
/// and what costs the least to upload from a phone. A minute of it is a few
/// hundred kilobytes.
@MainActor
@Observable
public final class VoiceRecorder {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording
        case transcribing
        /// Nothing came back. Not a failure: a few seconds of silence really
        /// does transcribe to nothing, and telling the user that in an error
        /// style makes a working feature look broken.
        case empty
        case failed(String)
    }

    /// Notes about the last attempt fade out on their own. A mic result that
    /// sits there permanently is worse than one that is missed.
    static let noteLifetime: Duration = .seconds(2.5)
    static let errorLifetime: Duration = .seconds(6)

    public private(set) var phase: Phase = .idle
    public private(set) var elapsed: TimeInterval = 0

    /// Beyond this the recording is abandoned rather than transcribed. Whisper
    /// chunks long audio and a fifteen-minute pocket-dial would sit in the
    /// queue for a while, and nobody means to record that.
    static let limit: TimeInterval = 120

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ticker: Timer?
    private var noteTask: Task<Void, Never>?

    public var isRecording: Bool { phase == .recording }
    public var isBusy: Bool { phase == .recording || phase == .transcribing || phase == .starting }

    /// Begin or end a recording. On a successful transcription `onText` is
    /// called with the words; the caller decides where they go.
    public func toggle(client: OWUIClient, onText: @escaping (String) -> Void) async {
        switch phase {
        case .recording: await stop(client: client, onText: onText)
        case .transcribing, .starting: break
        default: await start()
        }
    }

    /// Start, for a caller that also wants to stop on its own schedule — the
    /// composer holds the mic, so a press starts and a release may end it.
    public func start() async { await begin() }

    /// Stop and transcribe.
    public func stop(client: OWUIClient, onText: @escaping (String) -> Void) async {
        guard phase == .recording else { return }
        await finish(client: client, onText: onText)
    }

    // MARK: - recording

    private func begin() async {
        // Already recording: a second start would overwrite `recorder` and
        // orphan the running `AVAudioRecorder` — the mic stays lit with
        // nothing transcribing it. The composer's own toggle routes
        // "recording" to `stop`, so this only ever trips for an external
        // `start()` (voice mode's capture, which cancels first); it is the
        // belt to that braces.
        guard phase != .recording else { return }
        // Said out loud while the permission prompt is up. Without it the button
        // sat inert for the second or two the system dialog takes, which reads as
        // a tap that did nothing.
        phase = .starting
        defer { if phase == .starting { phase = .idle } }

        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                phase = .idle
                note(.failed("Microphone access is off — enable it in Settings."))
                return
            }
            // Started straight away. Making the user tap a second time after
            // saying yes felt broken: the first tap appeared to do nothing, and
            // there was nothing on screen to say why a second one was needed.
        }
        await startRecording()
    }

    private func startRecording() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            phase = .failed("Could not open the microphone: \(error.localizedDescription)")
            return
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiai-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            recorder.delegate = nil
            guard recorder.prepareToRecord(), recorder.record() else {
                note(.failed("The microphone is in use by another app."))
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            self.recorder = recorder
            self.url = file
            phase = .recording
            elapsed = 0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.elapsed += 0.25
                    // Stopping on the limit rather than letting it run: the
                    // user stopped meaning to press the button once already.
                    if self.elapsed >= Self.limit { await self.stopOnly() }
                }
            }
        } catch {
            note(.failed("Could not start recording: \(error.localizedDescription)"))
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func stopOnly() async {
        recorder?.stop()
        recorder = nil
        ticker?.invalidate()
        ticker = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finish(client: OWUIClient, onText: (String) -> Void) async {
        let seconds = elapsed
        guard let file = url else { await stopOnly(); phase = .idle; return }
        await stopOnly()
        defer { try? FileManager.default.removeItem(at: file) }

        // Under about a second there is nothing worth a round trip, and Whisper
        // reliably returns empty or nonsense for it. It still has to say so: a
        // button that swallows a short recording without a word back is
        // indistinguishable from a button that is broken.
        guard seconds >= 1.0, let data = try? Data(contentsOf: file), !data.isEmpty else {
            note(.empty)
            return
        }

        phase = .transcribing
        do {
            let text = try await client.transcribe(
                data: data, filename: file.lastPathComponent, mimeType: "audio/m4a")
            phase = .idle
            if let text { onText(text) } else { note(.empty) }
        } catch {
            note(.failed(error.localizedDescription))
        }
    }

    /// Show a note that clears itself, so the composer does not accumulate a
    /// permanent complaint about a two-second recording.
    private func note(_ next: Phase) {
        noteTask?.cancel()
        phase = next
        let life = switch next {
        case .failed: Self.errorLifetime
        default: Self.noteLifetime
        }
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: life)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.phase == next else { return }
                self.phase = .idle
            }
        }
    }

    /// Called by the view when it goes away mid-recording, so a discarded sheet
    /// does not leave the microphone lit.
    public func cancel() {
        noteTask?.cancel()
        if let file = url { try? FileManager.default.removeItem(at: file) }
        url = nil
        Task { await stopOnly() }
        phase = .idle
    }
}
#endif
