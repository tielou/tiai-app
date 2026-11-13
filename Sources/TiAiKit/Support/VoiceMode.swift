import Foundation
#if os(iOS)
import AVFoundation
#endif

/// The microphone side of hands-free mode (issue #49).
///
/// Split from the controller because the real implementation is iOS-only
/// (AVAudioRecorder plus a server round trip) while the loop it feeds is the
/// part worth testing. The contract is "open the mic, hold until told to stop,
/// hand back the words" — the controller never learns how the words were made.
@MainActor
protocol VoiceModeRecorder: AnyObject {
    /// Open the mic and hold until `finish()` is called; return the words,
    /// nil for "nothing heard". Throws `VoiceModeFailure`.
    func recordUntilStopped(client: OWUIClient) async throws -> String?
    /// Tap-to-stop the recording; the transcription then runs and this call
    /// returns its result.
    func finish()
    /// Abort without transcribing.
    func cancel()
}

/// The loudspeaker side of hands-free mode.
@MainActor
protocol VoiceModeSpeaker: AnyObject {
    /// Read aloud until done or `stop()` is called. Throws if the engine failed.
    func speak(_ text: String) async throws
    func stop()
}

/// What a recorder or speaker says when it fails, split by whether the loop
/// can do anything about it. A denied permission will still be denied on the
/// next attempt, so the loop stops; everything else (a transcription request
/// that timed out, a TTS voice that hiccuped) is worth another try.
enum VoiceModeFailure: Error, Equatable {
    case permission(String)
    case message(String)

    var message: String {
        switch self {
        case .permission(let text), .message(let text): return text
        }
    }

    var isPermission: Bool {
        if case .permission = self { return true }
        return false
    }
}

/// The hands-free loop (issue #49): record, transcribe, send, listen, read
/// aloud, record again — one tap to start, one tap to stop, no other chore.
///
/// The whole design follows from one rule: *the loop must never wedge*. A
/// hands-free mode that needs a force-quit after a bad answer is worse than
/// dictation. So every wait is a cancellable poll, every catch checks
/// cancellation before treating anything as an error (a `stop()` is never an
/// error), every failure either re-arms the mic or lands in `.off` with a
/// visible reason, and `stop()` works from every phase and leaves a clean,
/// re-startable state.
///
/// The loop drives a REAL `ConversationModel` — send, the queue, the outbox,
/// parked `ask_user` questions all behave exactly as they do for a typed
/// message. What it adds is only the sequencing and the reading.
@MainActor
@Observable
final class VoiceModeController {
    enum Phase: Equatable {
        case off
        case listening
        /// Between the mic letting go and the message going out — the
        /// transcription round trip lives inside the recorder, so this is
        /// brief; it exists so the status line never lies about silence.
        case transcribing
        case thinking
        case speaking
    }

    private(set) var phase: Phase = .off
    /// Persistent until dismissed or the next full success. A voice loop runs
    /// with the phone in a pocket or on a table; an error that fades on its own
    /// is an error that was never seen.
    var error: String?

    var statusText: String {
        switch phase {
        case .off: ""
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }

    private let conversation: ConversationModel
    private let recorder: any VoiceModeRecorder
    private let speaker: any VoiceModeSpeaker
    /// The wait granularity. Tests shrink it; production never notices.
    private let poll: Duration
    /// How long a sent message may take to settle before the loop gives up on
    /// the answer. A backstop for a stream that goes silent without the model
    /// ever saying so — the run's own watchdogs normally beat it.
    private let runTimeout: Duration
    private var task: Task<Void, Never>?

    /// One beat to wait after a run parks on a question before reading it: the
    /// model refetches the chat to get the question's full arguments, and the
    /// question is the one thing the user has to hear correctly.
    private static let settleBeat: Duration = .milliseconds(500)
    /// The same beat between a recorder failure and the re-arm, so a mic that
    /// cannot open does not spin the loop against a wall.
    private static let failureBackoff: Duration = .milliseconds(500)
    /// Three strikes. A mic that cannot open fails identically every time
    /// (another app holds it, the session will not activate), and a loop that
    /// retries it every backoff beat forever is a fan spinning against a
    /// wall — the bar says "Listening" while nothing can ever be heard. The
    /// third consecutive failure exits the way a denied permission does,
    /// with the reason on screen. A recording that worked clears the count.
    private static let maxConsecutiveFailures = 3
    private var consecutiveFailures = 0
    /// True when the busy run — if there is one — is one this loop started
    /// (or queued), not one the user started by hand. A send that went into
    /// the #37 queue does not own the run still in flight; it owns nothing
    /// until its own assistant turn shows up. Read-only and internal for
    /// the same reason `lastOutcome` is: the queued-run test must wait for
    /// the flip to land rather than race it.
    private(set) var loopOwnsCurrentRun = false
    /// How the last completed run ended. Internal and read-only so the tests
    /// can pin which branch a parked run actually took instead of inferring
    /// it from timing.
    private(set) var lastOutcome: Outcome = .answer

    init(
        conversation: ConversationModel,
        recorder: any VoiceModeRecorder,
        speaker: any VoiceModeSpeaker,
        poll: Duration = .milliseconds(100),
        runTimeout: Duration = .seconds(300)
    ) {
        self.conversation = conversation
        self.recorder = recorder
        self.speaker = speaker
        self.poll = poll
        self.runTimeout = runTimeout
    }

    /// The one button. Off starts the loop; while the mic is open it stops the
    /// recording (which is the same press dictation uses); in every other
    /// phase it means "the whole thing, stop".
    func toggle() {
        switch phase {
        case .off: start()
        case .listening: recorder.finish()
        default: stop()
        }
    }

    func start() {
        guard phase == .off else { return }
        // A fresh session gets a fresh strike count. Without this the manual
        // restart after a three-strike exit exits on the FIRST failure — the
        // restart is the user saying "try again", and the old session's
        // strikes are no evidence about the new one.
        consecutiveFailures = 0
        task = Task { [weak self] in await self?.runLoop() }
    }

    /// Stop from any phase, cleanly. The recorder and speaker are told even
    /// when the loop is not in their phase — cheap no-ops, and it means one
    /// press cannot leave the mic lit or the voice talking. The conversation
    /// is stopped only when the run in flight is the one this loop sent: a
    /// message the user typed by hand is none of voice mode's business —
    /// and neither is the user's run that a *queued* voice send is still
    /// waiting behind, which is why `loopOwnsCurrentRun` has to say so.
    func stop() {
        task?.cancel()
        task = nil
        recorder.cancel()
        speaker.stop()
        if phase == .thinking, conversation.phase.isBusy, loopOwnsCurrentRun {
            conversation.stop()
        }
        phase = .off
    }

    func dismissError() { error = nil }

    // MARK: - the loop

    private func runLoop() async {
        cycle: while !Task.isCancelled {
            // 1. Record. A permission refusal takes the loop out of the game —
            // re-arming would throw the same error a second later, and a
            // banner that reappears faster than it is read is noise.
            phase = .listening
            let text: String?
            do {
                text = try await recorder.recordUntilStopped(client: conversation.client)
            } catch {
                if Task.isCancelled { break }
                let failure = error as? VoiceModeFailure
                self.error = failure?.message ?? error.localizedDescription
                if failure?.isPermission == true {
                    phase = .off
                    return
                }
                // A mic that fails the same way three times in a row is not
                // having a moment; take the permission exit rather than
                // backoff-and-retry against a wall forever.
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    phase = .off
                    return
                }
                // Everything else (a transcription that failed, a mic busy for
                // one reason) is worth another try: say so, wait a beat, re-arm.
                try? await Task.sleep(for: Self.failureBackoff)
                if Task.isCancelled { break }
                continue
            }
            if Task.isCancelled { break }
            // A recording that worked is a fresh start for the failure count.
            consecutiveFailures = 0
            // Nothing heard is not a failure — silence really does transcribe
            // to nothing. Re-arm in silence.
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            // 2. Send. The draft is the composer's, so a half-typed message
            // loses to the spoken one the same way typing over dictation does.
            phase = .transcribing
            let before = conversation.turns.last?.id
            let outboxBefore = conversation.pendingOutbox.count
            // A send into a busy chat goes through the #37 queue, and until
            // this message's own turn exists the busy run is the user's —
            // `stop()` must not put the phone down on someone else's run.
            let queuedSend = conversation.phase.isBusy
            conversation.draft = text
            guard conversation.send() else {
                error = conversation.error ?? "The message could not be sent."
                phase = .off
                return
            }
            loopOwnsCurrentRun = !queuedSend
            phase = .thinking
            // A new run starts with a fresh outcome: anything reading this
            // (the tests, to pin which branch a parked run took) reads the
            // branch of THIS run, never a stale one from the last cycle.
            // It resets at send time rather than at the top of the cycle
            // because a cycle that records but never sends has no outcome
            // to invalidate — clearing it there would erase the very value
            // the parked-question test pins after the mic re-arms.
            lastOutcome = .answer

            // 3a. Read-as-it-streams. Sentences go to the speaker while the
            // answer is still arriving, instead of waiting for the last
            // token: `reader` releases only sentences that cannot change
            // any more, and this child task speaks them in order while the
            // wait loop below keeps polling. The `defer` closes the stream
            // on EVERY way out of this cycle — normal end, `continue`,
            // timeout `return`, cancellation — so the child can never
            // outlive the cycle that made it, which is what makes it safe
            // to be a child task at all.
            let (speech, speechFeed) = AsyncStream<String>.makeStream()
            var reader = StreamingSentenceReader()
            var streamedAny = false
            let speakTask = Task { () -> String? in
                for await sentence in speech {
                    if Task.isCancelled { return nil }
                    do { try await speaker.speak(sentence) }
                    catch {
                        return (error as? VoiceModeFailure)?.message
                            ?? error.localizedDescription
                    }
                }
                return nil
            }
            defer { speechFeed.finish(); speakTask.cancel() }

            // 3. Wait for the answer to settle — or for one of the ways a send
            // ends without an answer to appear. Every branch here either
            // breaks with something to read or re-arms the mic; none of them
            // can hang, because the poll is bounded by `runTimeout`.
            let deadline = ContinuousClock.now + runTimeout
            var outcome: Outcome = .answer
            var questionTurnID: String?
            var timedOut = false
            wait: while true {
                if Task.isCancelled { break cycle }
                // The ownership detection sits at the TOP of each iteration,
                // outside the `.ready` gate below: when a queued send drains
                // into its own run, the conversation is busy the whole time
                // the loop's own assistant turn streams, so a flip gated on
                // `.ready` would never fire — `settled()` breaks out first
                // and `stop()` would then skip `conversation.stop()` on the
                // loop's own run, leaving voice mode dark over an answer
                // that keeps streaming.
                //
                // Residual accepted edge: if the user has ALSO queued a
                // message, that one drains first and its assistant turn is
                // claimed here — voice mode may then stop a run that is not
                // its own. The same false claim happens when the user's
                // in-flight run is stop-discarded (#34) while the voice send
                // is queued: turns.last reverts to an older assistant turn
                // with id != before. Both usually self-correct when the queue
                // drains the voice message moments later. The fully correct
                // claim needs the assistant message id of the loop's own send,
                // which is not knowable at queue time.
                if let last = conversation.turns.last, last.id != before,
                   last.isAssistant {
                    loopOwnsCurrentRun = true
                }
                // Feed the growing answer. Only the loop's own run is ever
                // fed — text from a run the loop does not own must not be
                // read aloud by it.
                if loopOwnsCurrentRun, let live = conversation.turns.last,
                   live.id != before, live.isAssistant, live.error == nil {
                    for sentence in reader.feed(live.text) {
                        speechFeed.yield(sentence)
                        streamedAny = true
                        if phase != .speaking { phase = .speaking }
                    }
                }
                if settled(before: before) { break }
                if conversation.phase == .ready {
                    let freshAssistant = conversation.turns.last
                        .map { $0.id != before && $0.isAssistant } ?? false
                    // A parked question: the run is waiting for a voice answer,
                    // and the question is the thing worth hearing. `settled`
                    // deliberately refuses parked turns so that this branch —
                    // with the settle beat the question's refetch needs — is
                    // the one that reads them.
                    if let last = conversation.turns.last, last.id != before,
                       last.isAssistant, last.awaitingCall != nil || last.awaitsTool {
                        outcome = .question
                        questionTurnID = last.id
                        break
                    }
                    // The answer itself failed — say what the model said, not
                    // a generic complaint, and re-arm.
                    if let last = conversation.turns.last, last.id != before,
                       last.isAssistant, last.error != nil {
                        error = last.error
                        continue cycle
                    }
                    // The send evaporated: #34's stop-discard (a composer Stop
                    // pressed on this very run) removes both turns and sets no
                    // error, and without this arm the loop would sit in
                    // `.thinking` until the run timeout. Only a send that went
                    // out directly can evaporate this way — a queued send has
                    // not produced its turns yet, and the chat sitting
                    // `.ready` between the user's run and the queue drain
                    // looks exactly like this.
                    if !queuedSend, conversation.turns.last?.id == before,
                       conversation.error == nil,
                       conversation.pendingOutbox.count == outboxBefore {
                        error = "The answer was stopped."
                        phase = .off
                        return
                    }
                    // The send was parked (outbox) or rolled back (#9): the
                    // user's words never left the phone. Re-arm rather than
                    // stop — connectivity may come back before the next
                    // sentence is spoken. `conversation.error` counts here
                    // only when the loop's own send produced no fresh
                    // assistant turn: unrelated failures (a failed rating
                    // POST, an upload watchdog, "Live streaming is
                    // unavailable", a failed stop POST) stamp it during a
                    // perfectly healthy run, and a thumb-tap on an older
                    // reply must not kill the read-aloud.
                    if conversation.turns.last?.isUser == true
                        || conversation.pendingOutbox.count > outboxBefore
                        || (conversation.error != nil && !freshAssistant) {
                        error = conversation.error ?? "The message could not be sent."
                        continue cycle
                    }
                }
                if ContinuousClock.now > deadline { timedOut = true; break }
                try? await Task.sleep(for: poll)
            }
            if timedOut {
                error = "The answer timed out."
                phase = .off
                return
            }
            lastOutcome = outcome

            // 4. Read it. A parked question gets its settle beat first so the
            // refetch has landed the full question text.
            if outcome == .question {
                try? await Task.sleep(for: Self.settleBeat)
                if Task.isCancelled { break }
            }
            // The parked turn is re-read BY id, not as `turns.last`: the
            // settle beat is half a second in which the user may well have
            // answered through the tool UI, and then `turns.last` is the
            // user's own answer (or the run it started) — reading that back
            // would speak the user's words at them. If the turn is gone
            // entirely (a stop-discard), this cycle has nothing left to read.
            let turn: Turn
            if let id = questionTurnID {
                guard let parked = conversation.turns.first(where: { $0.id == id })
                else { continue cycle }
                turn = parked
            } else {
                guard let last = conversation.turns.last else { continue cycle }
                turn = last
            }
            var speakText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prompt = AskUserPrompt(arguments: turn.awaitingCall?.arguments) {
                let question = prompt.questions.map(\.text).joined(separator: " ")
                speakText = [speakText, question].filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            // An answer with nothing speakable re-arms in silence rather than
            // hearing the TTS engine complain. The chunk check rather than
            // `speakText.isEmpty` is the point: a code-only answer is not
            // empty, but everything in it is stripped before speaking, and
            // `SpeechPlayer.read` would answer "nothing to read" every cycle.
            if outcome == .question {
                // A parked question keeps the whole-text read: it is short,
                // and the settle beat's refetch can rewrite the text the
                // streaming reader already saw. Whatever the streamer got
                // out first is part of the question — repeating a phrase
                // beats reading a half-arrived question.
                speechFeed.finish()
                speakTask.cancel()
                if !SpeechText.chunks(speakText).isEmpty {
                    phase = .speaking
                    do {
                        try await speaker.speak(speakText)
                    } catch {
                        if Task.isCancelled { break }
                        self.error = (error as? VoiceModeFailure)?.message
                            ?? error.localizedDescription
                        continue cycle
                    }
                }
            } else {
                // The tail: the last sentence had no successor to prove it
                // complete while streaming, and anything that landed after
                // the wait loop's final poll lives here too.
                var speakable = streamedAny
                for sentence in reader.flush(speakText) {
                    speechFeed.yield(sentence)
                    speakable = true
                }
                speechFeed.finish()
                if speakable { phase = .speaking }
                // The child drains in order. A failure it returns is a TTS
                // round trip dying — the first one, or (since each sentence
                // is now its own request) one that died mid-answer. Both
                // surface, because a reading that silently stops halfway
                // is worse than one that says it is gone.
                if let failure = await speakTask.value {
                    if Task.isCancelled { break }
                    self.error = failure
                    continue cycle
                }
            }
            // A full cycle worked; an older complaint has expired.
            error = nil
        }
    }

    enum Outcome { case answer, question }

    /// The answer is in. The turn has to be a *new* non-streaming assistant
    /// turn with nothing wrong about it — a user turn still last means the
    /// send is parked or rolled back (handled as a terminal elsewhere, but
    /// never as "settled"), and a streaming one means the deltas are still
    /// arriving. A turn parked on an `ask_user` question is not a settled
    /// answer either: it has its own branch in the wait loop, with the settle
    /// beat the question's refetch needs — settling here would read the
    /// question before its full text has landed. `conversation.error` is
    /// deliberately *not* consulted: unrelated failures (a failed rating
    /// POST, an upload watchdog, a failed stop POST) stamp it during a
    /// healthy run, and the run's own failure is carried by the turn's
    /// `error`.
    func settled(before: String?) -> Bool {
        guard conversation.phase == .ready else { return false }
        guard let last = conversation.turns.last, last.id != before else { return false }
        if last.isUser { return false }
        return !last.streaming && last.error == nil
            && last.awaitingCall == nil && !last.awaitsTool
    }
}

#if os(iOS)
/// Drives the composer's `VoiceRecorder` in hold-open mode.
///
/// Shared instance, deliberately: two `AVAudioRecorder`s cannot hold the mic
/// at once, so voice mode and dictation must be the *same* recorder or one of
/// them silently records nothing.
///
/// The phase reads happen immediately after `start()`/`stop()` return, on the
/// main actor with no await between: `VoiceRecorder` fades a note back to
/// `.idle` after a few seconds, and by the time a polling caller looked, a
/// `.failed` worth reporting would have quietly become `.idle`.
final class VoiceRecorderCapture: VoiceModeRecorder {
    private let recorder: VoiceRecorder
    private var finishRequested = false

    init(recorder: VoiceRecorder) { self.recorder = recorder }

    func recordUntilStopped(client: OWUIClient) async throws -> String? {
        finishRequested = false
        // Dictation may still be holding this very recorder: a short tap on
        // the composer's mic starts a hands-free recording that nobody has
        // stopped yet, and the voice-mode toggle stays live next to the bar.
        // Starting a second recording would orphan the first
        // `AVAudioRecorder` — the mic stays lit with nothing transcribing
        // it — so voice mode takes the mic: the dictation in progress is
        // cancelled, the same call the composer's own cancel path makes. A
        // dictation that was never finished had no text to lose.
        if recorder.isRecording { recorder.cancel() }
        // The generation is the composer's concern; the capture stops the
        // recording through its own single call site, so it needs none.
        _ = await recorder.start()
        switch recorder.phase {
        case .recording: break
        case .failed(let message):
            // The permission refusal names itself in `VoiceRecorder.begin`;
            // everything else ("the microphone is in use") is transient.
            if message.contains("Microphone access") {
                throw VoiceModeFailure.permission(message)
            }
            throw VoiceModeFailure.message(message)
        default:
            throw VoiceModeFailure.message("The microphone could not be started.")
        }

        // Hold until the tap. Polling rather than a continuation because the
        // other ways out — `cancel()`, a failure note fading the phase out of
        // `.recording` — are already observable there, and a cancellable
        // sleep is what makes `stop()` land mid-hold. If the phase leaves
        // `.recording` on its own there is nothing left to transcribe, so the
        // honest answer is nil: silent re-arm, no error.
        //
        // The recorder's own 120 s cap needs its own watch: the ticker's
        // limit stop tears the hardware down but leaves the phase at
        // `.recording`, so the phase escape never fires and the bar would
        // say "Listening" over a dead mic forever. `elapsed` is the truth —
        // at the limit, or frozen (the mic died under us and the ticker
        // stopped advancing it), finish the recording so the audio that does
        // exist is transcribed now instead of sitting there unfetched.
        var lastElapsed = recorder.elapsed
        /// Wall time of the last observed advance of `elapsed`.
        var lastAdvance = ContinuousClock.now
        while !finishRequested {
            try await Task.sleep(for: .milliseconds(50))
            if recorder.phase != .recording { return nil }
            if recorder.elapsed > lastElapsed {
                lastElapsed = recorder.elapsed
                lastAdvance = ContinuousClock.now
            }
            if recorder.elapsed >= VoiceRecorder.limit {
                finishRequested = true
                break
            }
            // The freeze trip is gated on wall-clock drift, not on a count
            // of silent polls. A poll count measured this task's patience,
            // not the ticker's: `Task.sleep` continuations run during scroll
            // tracking, so ~600 ms of scrolling mid-recording read as a dead
            // ticker and auto-finished a healthy recording. (The ticker is
            // now added in `.common` run-loop modes, which fixes the
            // starvation itself; this gate is the belt.) A ticker that
            // really died leaves `elapsed` frozen for a full second of wall
            // time — a scroll or a slow poll loop does not. Residual: a main-
            // thread hang over a second can still trip this on recovery if the
            // poll continuation runs before the coalesced ticker fire; the
            // consequence is benign (the recording is finished and transcribed,
            // not lost), so it is accepted rather than raced around.
            if ContinuousClock.now - lastAdvance > .seconds(1) {
                finishRequested = true
                break
            }
        }

        var text: String?
        await recorder.stop(client: client) { text = $0 }
        switch recorder.phase {
        case .failed(let message): throw VoiceModeFailure.message(message)
        case .empty: return nil
        default: return text
        }
    }

    func finish() { finishRequested = true }
    func cancel() { recorder.cancel() }
}

/// Reads answers through the conversation's shared `SpeechPlayer`, so voice
/// mode and the read-aloud button obey one voice setting and one audio queue.
final class SpeechPlayerSpeaker: VoiceModeSpeaker {
    private let player: SpeechPlayer
    private let poll: Duration

    init(player: SpeechPlayer, poll: Duration = .milliseconds(100)) {
        self.player = player
        self.poll = poll
    }

    func speak(_ text: String) async throws {
        player.read(text)
        // `read()` sets `isPlaying` synchronously, so there is no race with
        // the first poll. Text with nothing to read never starts playing and
        // only sets `error` — the check below is what turns that into a
        // failure the loop can show instead of a silent nothing.
        while player.isPlaying {
            try await Task.sleep(for: poll)
        }
        if let failure = player.error {
            player.dismissError()
            throw VoiceModeFailure.message(failure)
        }
    }

    func stop() { player.stop() }
}
#endif
