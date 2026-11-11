import SwiftUI

/// Find-in-chat (issue #50): the search state and the bar that drives it.
///
/// The state lives in its own `@Observable` rather than in `ConversationModel`
/// because it is pure view state — nothing about a find survives leaving the
/// screen, and nothing the server knows affects it. The view side is the strip
/// under the transcript; the scrolling and the per-row highlight are wired up
/// in ConversationView/MessageRow, which is where the scroll proxy and the
/// turn rows actually live.
@MainActor
@Observable
final class FindModel {
    /// The raw query as typed. Folding happens once per recompute, not per turn.
    var query = "" {
        // Typing while closed (or a reset writing "" back) must not schedule a
        // pass over the transcript.
        didSet { guard query != oldValue, isActive else { return }; scheduleRecompute() }
    }
    /// Closing through any path resets everything, so a reopen starts clean and
    /// no stale highlight can outlive the bar.
    var isActive = false {
        didSet { if !isActive, oldValue { reset() } }
    }

    private(set) var occurrences: [FindInChat.Occurrence] = []
    /// Index into `occurrences`. Never set automatically — opening find and
    /// having the app jump somewhere you did not ask for is worse than an
    /// unmarked list of hits.
    var current: Int?
    /// The turn the transcript should scroll to. The nonce is the point: two
    /// nexts inside one turn must re-fire the `onChange` in ConversationView,
    /// and a bare turnID would compare equal and do nothing.
    private(set) var scrollTarget: (turnID: String, nonce: Int)?

    /// The folded needle, kept so `mark(for:)` does not refold per row per
    /// render and so the highlight and the count provably use one fold.
    private(set) var foldedNeedle = ""

    /// Never read by any view — they are scheduling bookkeeping, so observing
    /// them would only add invalidation churn at streaming delta rates.
    @ObservationIgnored private var lastTurns: [Turn] = []
    private var recomputeTask: Task<Void, Never>?
    /// Wall-clock time of the last actual pass, for the max-wait below.
    /// Also never observed — see `lastTurns`.
    @ObservationIgnored private var lastRecompute = Date.distantPast
    /// The debounce alone starves during fast streaming: deltas faster than
    /// the debounce each cancel the pending task, so the count only refreshes
    /// at a pause. Past this age the next call fires immediately instead of
    /// scheduling — a leading-edge throttle, so the count is never more than
    /// this stale while tokens are pouring in.
    private static let maxRecomputeWait = TimeInterval(0.25)
    /// Turn IDs that hold at least one hit. `mark(for:)` is called per row per
    /// body pass; scanning `occurrences` there would be O(rows x hits) per
    /// streaming delta, so the set is rebuilt once per recompute instead.
    private var turnIDsWithHits: Set<String> = []

    /// Recompute is debounced: every keystroke reparses nothing on its own, and
    /// a streaming delta re-fires it at the delta rate otherwise.
    func recompute(turns: [Turn]) {
        // With find closed there is nothing to count, and without this guard
        // every streaming delta would spawn a Task and retain a transcript
        // copy for a bar nobody is looking at. The `onAppear` seed in `FindBar`
        // covers activation: the bar only exists while active.
        guard isActive else { return }
        lastTurns = turns
        recomputeTask?.cancel()
        if Date().timeIntervalSince(lastRecompute) >= Self.maxRecomputeWait {
            // Claim the slot before hopping, so a second call inside the same
            // update pass takes the debounce path instead of double-firing.
            lastRecompute = Date()
            // The streaming path calls this from `onChange(of: turns)`, i.e.
            // during a SwiftUI update pass, and `performRecompute` publishes
            // @Observable state. One hop to the next main-actor turn gets the
            // writes out of the pass; the leading-edge freshness promise
            // ("never more than maxRecomputeWait stale") survives it, and
            // navigation stays synchronous in `step` because a button press
            // is not an update pass.
            Task { @MainActor [weak self] in self?.performRecompute() }
            return
        }
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.performRecompute()
        }
    }

    /// Navigation refreshes synchronously instead: pressing next one beat
    /// after typing must not navigate a stale list, and the parse behind it is
    /// memoised by `AnswerRender` anyway.
    func next(turns: [Turn]) { step(by: 1, turns: turns) }
    func previous(turns: [Turn]) { step(by: -1, turns: turns) }

    func close() { isActive = false }

    /// The highlight instruction for one row: nil unless find is on and this
    /// turn has a hit. Read from `MessageRow`'s construction site, which makes
    /// the row observe `occurrences`/`current` through the screen's body.
    func mark(for turn: Turn) -> FindMark? {
        // One set lookup per row, not a scan of every hit; the set is rebuilt
        // once per recompute.
        guard isActive, turnIDsWithHits.contains(turn.id) else { return nil }
        let hit = current.flatMap { index -> FindInChat.Occurrence? in
            guard occurrences.indices.contains(index), occurrences[index].turnID == turn.id
            else { return nil }
            return occurrences[index]
        }
        return FindMark(
            query: foldedNeedle,
            currentSegment: hit?.segment,
            currentOffset: hit?.offset,
            isCurrentTurn: hit != nil)
    }

    private func step(by delta: Int, turns: [Turn]) {
        recomputeTask?.cancel()
        lastTurns = turns
        performRecompute()
        let count = occurrences.count
        guard count > 0 else { current = nil; return }
        // Wrap around: find bars that stop at the end make people think there
        // are more matches below.
        let index = current.map { ($0 + delta + count) % count }
            ?? (delta > 0 ? 0 : count - 1)
        current = index
        scrollTarget = (occurrences[index].turnID, (scrollTarget?.nonce ?? 0) + 1)
    }

    private func scheduleRecompute() { recompute(turns: lastTurns) }

    /// Recompute deliberately does NOT touch `scrollTarget`: the reader is
    /// looking at their match, and a streaming delta re-counting must not
    /// yank the view. `current` is clamped so it cannot dangle past the end of
    /// a shrunk list, and goes nil only when there is nothing left to point at.
    private func performRecompute() {
        lastRecompute = Date()
        foldedNeedle = FindInChat.fold(query)
        occurrences = FindInChat.find(query: query, turns: lastTurns)
        turnIDsWithHits = Set(occurrences.map(\.turnID))
        if let index = current {
            current = occurrences.isEmpty ? nil : min(index, occurrences.count - 1)
        }
    }

    private func reset() {
        recomputeTask?.cancel()
        // A reopen within the max-wait window must count immediately: the
        // `onAppear` seed should take the leading edge, not schedule 120ms
        // behind a timer left running by the previous find.
        lastRecompute = .distantPast
        query = ""
        occurrences = []
        turnIDsWithHits = []
        current = nil
        scrollTarget = nil
        foldedNeedle = ""
    }
}

/// What one row needs to know about the find: the folded needle (so the row's
/// highlight uses the same fold as the count), where the *current* hit is
/// inside the row, and whether this row holds it at all.
struct FindMark: Equatable {
    let query: String
    let currentSegment: Int?
    let currentOffset: Int?
    let isCurrentTurn: Bool
}

/// The search strip. Styled like the outbox banner it sits beside: same
/// padding, same quiet `.quaternary` fill, so the area under the transcript
/// reads as one family of strips rather than a new chrome each time.
struct FindBar: View {
    @Bindable var find: FindModel
    /// The bar cannot reach the transcript's turns itself (the scroll proxy and
    /// the model live up in ConversationView), so the screen hands them over
    /// for next/previous.
    let turns: [Turn]

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                TextField("Find in chat", text: $find.query)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    // Return steps forward, shift-Return back — the same deal
                    // every find bar on every platform makes.
                    .onSubmit { find.next(turns: turns) }
                    .accessibilityIdentifier("findField")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

            Text(countText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("findCount")

            Spacer(minLength: 4)

            Button { find.previous(turns: turns) } label: {
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(find.occurrences.isEmpty ? Color.secondary : Color.primary)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("findPrevious")

            Button { find.next(turns: turns) } label: {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(find.occurrences.isEmpty ? Color.secondary : Color.primary)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("findNext")

            Button { find.close() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("findClose")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
        .accessibilityIdentifier("findBar")
        // Opening find puts the caret in the field: the tap that opened it was
        // the intent to type, and making a second tap to focus is busywork.
        .onAppear {
            focused = true
            // Seed the turn snapshot now — `onChange(of: turns)` only fires on
            // a change, and a find opened on a static chat would otherwise
            // search an empty transcript until the next delta.
            find.recompute(turns: turns)
        }
    }

    private var countText: String {
        let total = find.occurrences.count
        if total == 0 {
            // Silence on an empty field is not "No results" — nothing was asked.
            return find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : "No results"
        }
        if let current = find.current { return "\(current + 1) of \(total)" }
        return "\(total) matches"
    }
}
