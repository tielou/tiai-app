import Foundation
import Testing

@testable import TiAiKit

/// Find in chat (issue #50). The matcher and the navigation model, tested
/// without any view code — `FindInChat` is Foundation-only precisely so these
/// run under `swift test` on macOS, where the iOS answer views do not compile.

private func makeTurn(
    _ id: String, _ role: String = "assistant", _ text: String, streaming: Bool = false
) -> Turn {
    var turn = Turn(id: id, role: role, text: text)
    turn.streaming = streaming
    return turn
}

/// The same path the bar takes: fold the raw query once, then search.
private func hits(_ query: String, in text: String) -> [FindInChat.Range16] {
    FindInChat.occurrences(ofFolded: FindInChat.fold(query), in: text)
}

private func hitCount(_ query: String, in text: String) -> Int {
    hits(query, in: text).count
}

@Test func findIsCaseInsensitive() {
    #expect(hitCount("hello", in: "Hello, HELLO, hello.") == 3)
    #expect(hitCount("HELLO", in: "hello") == 1)
}

@Test func findIsDiacriticInsensitiveBothDirections() {
    // ASCII query finds the accented text...
    #expect(hitCount("cafe", in: "un café") == 1)
    // ...and the accented query finds the ASCII text, via the other turn of
    // the same fold (both sides fold to the same needle).
    #expect(hitCount("ECOLE", in: "l'école") == 1)
    // Decomposed input is the case that breaks scalar-wise folding: `e\u{301}`
    // is two UTF-16 units and must still fold to one `e`.
    #expect(hitCount("cafe\u{301}", in: "un cafe") == 1)
    #expect(hitCount("cafe", in: "un cafe\u{301}") == 1)
}

@Test func rangesAddressTheOriginalStringNotTheFoldedOne() {
    // The fold here is SHORTER than the original (two decomposed e-accents,
    // two units each, fold to one), so folded offsets would land early. The
    // returned range must slice the ORIGINAL string to exactly the match.
    let text = "re\u{301}sume\u{301} needle"
    let found = hits("needle", in: text)
    #expect(found.count == 1)
    let hit = found[0]
    let slice = (text as NSString).substring(
        with: NSRange(location: hit.location, length: hit.length))
    #expect(slice == "needle")
    // And the accented word itself is found with the right original range:
    // 7 characters, 9 UTF-16 units in the original.
    let accented = hits("resume", in: text)
    #expect(accented.count == 1)
    let accentSlice = (text as NSString).substring(
        with: NSRange(location: accented[0].location, length: accented[0].length))
    #expect(accentSlice == "re\u{301}sume\u{301}")
}

@Test func emptyAndWhitespaceQueriesMatchNothing() {
    for query in ["", " ", "   ", "\t\n"] {
        #expect(hits(query, in: "some text with spaces").isEmpty,
                "a whitespace query would match every gap in the transcript")
    }
}

@Test func matchesAreNonOverlappingAndOrdered() {
    let found = hits("aa", in: "aaaa")
    #expect(found.count == 2)
    #expect(found.map(\.location) == [0, 2])
}

@Test @MainActor func occurrencesAreInReadingOrderAcrossTurns() {
    let turns = [
        makeTurn("t0", "user", "alpha"),
        makeTurn("t1", "user", "beta"),
        makeTurn("t2", "user", "alpha and alpha"),
        makeTurn("t3", "user", "nothing"),
        makeTurn("t4", "user", "alpha"),
    ]
    let found = FindInChat.find(query: "alpha", turns: turns)
    #expect(found.map(\.turnID) == ["t0", "t2", "t2", "t4"])
    // Within a turn, ascending offset.
    #expect(found[1].offset < found[2].offset)
}

@Test @MainActor func codeBlocksAreExcludedFromFind() {
    // Documented v1 policy: fenced code renders in ScrollableCodeBlock, which
    // cannot paint a highlight, so counting a hit there would make the bar's
    // count un-jumpable. Pinned here so the decision is at least on record.
    let turn = makeTurn("a", "assistant", """
    intro paragraph
    ```swift
    let needle = 1
    ```
    outro paragraph
    """)
    #expect(FindInChat.find(query: "needle", turns: [turn]).isEmpty)
    // The prose around the fence is still searched, and the segment index skips
    // past the code segment rather than collapsing onto it.
    let proseHits = FindInChat.find(query: "outro", turns: [turn])
    #expect(proseHits.count == 1)
    #expect(proseHits[0].segment == 2)  // prose, code, prose
}

@Test @MainActor func tableCellsAreExcludedFromFind() {
    // Same policy one surface over: tables render in ScrollableTableView.
    let turn = makeTurn("a", "assistant", """
    before text

    | name | note |
    |------|------|
    | needle | x |

    after text
    """)
    #expect(FindInChat.find(query: "needle", turns: [turn]).isEmpty)
    #expect(FindInChat.find(query: "after", turns: [turn]).count == 1)
}

@Test @MainActor func inlineMarkdownIsStrippedForMatching() {
    // The reader sees "bo bold end"; the search searches that, so "bold" hits
    // and the raw markers — which never reach the screen — do not. Pinned as
    // a trade, not an oversight: searching `**bold**` is searching source the
    // app deliberately does not show.
    let turn = makeTurn("a", "assistant", "bo **bold** end")
    #expect(FindInChat.find(query: "bold", turns: [turn]).count == 1)
    #expect(FindInChat.find(query: "**bold**", turns: [turn]).isEmpty)
}

@Test @MainActor func streamingGrowthIsCountedLive() {
    // The prefix that has not reached the word yet counts zero, the completed
    // word counts one — the bar's count tracks the answer as it arrives.
    #expect(FindInChat.find(
        query: "world",
        turns: [makeTurn("a", "assistant", "Hello wor", streaming: true)]).isEmpty)
    #expect(FindInChat.find(
        query: "world",
        turns: [makeTurn("a", "assistant", "Hello world", streaming: true)]).count == 1)
    // A fence OPENING mid-stream restructures the segments (prose, then an
    // unterminated code block) without crashing and without losing the prose
    // hit — the mid-stream fence case Markdown.blocks is built for.
    let midFence = FindInChat.find(
        query: "world",
        turns: [makeTurn("a", "assistant", "Hello world\n```", streaming: true)])
    #expect(midFence.count == 1)
}

// MARK: - FindModel navigation

@Test @MainActor func navigationWrapsAndNonceBumps() {
    let turns = [makeTurn("t0", "user", "x x"), makeTurn("t1", "user", "x")]
    let find = FindModel()
    find.isActive = true
    find.query = "x"
    find.next(turns: turns)
    #expect(find.current == 0)
    find.next(turns: turns)
    #expect(find.current == 1)
    find.next(turns: turns)
    #expect(find.current == 2)
    // Next from the last wraps to the first.
    find.next(turns: turns)
    #expect(find.current == 0)
    #expect(find.scrollTarget?.turnID == "t0")
    // Previous from the first wraps to the last.
    find.previous(turns: turns)
    #expect(find.current == 2)
    #expect(find.scrollTarget?.turnID == "t1")
    // Two hits inside the SAME turn must still re-fire the scroll: the nonce
    // is what makes `onChange(of: scrollTarget?.nonce)` see a repeat.
    find.next(turns: turns)  // -> t0, first hit
    let nonceAfterT0 = find.scrollTarget?.nonce
    #expect(find.scrollTarget?.turnID == "t0")
    find.next(turns: turns)  // -> t0, second hit
    #expect(find.scrollTarget?.turnID == "t0")
    #expect(find.scrollTarget?.nonce != nonceAfterT0)
}

@Test @MainActor func recomputeClampsCurrentAndLeavesScrollTargetAlone() async throws {
    let full = [makeTurn("t0", "user", "x x x")]
    let find = FindModel()
    find.isActive = true
    find.query = "x"
    find.next(turns: full)
    find.next(turns: full)
    find.next(turns: full)  // current == 2
    let target = find.scrollTarget
    #expect(find.current == 2)

    find.recompute(turns: [makeTurn("t0", "user", "x")])
    // Debounced: nothing has moved yet, and the scroll target must not move
    // now or ever — the reader is looking at their match. (Field-wise compare:
    // a named tuple is not `Equatable`, so `==` on the tuple itself won't type.)
    #expect(find.scrollTarget?.turnID == target?.turnID)
    #expect(find.scrollTarget?.nonce == target?.nonce)
    try await Task.sleep(for: .milliseconds(300))
    #expect(find.occurrences.count == 1)
    #expect(find.current == 0, "current clamps into the shrunk list")
    #expect(find.scrollTarget?.turnID == target?.turnID,
            "a re-count must never move the scroll")
    #expect(find.scrollTarget?.nonce == target?.nonce,
            "a re-count must never move the scroll")
}

@Test @MainActor func closingResetsEverything() {
    let turns = [makeTurn("t0", "user", "x x")]
    let find = FindModel()
    find.isActive = true
    find.query = "x"
    find.next(turns: turns)
    #expect(find.mark(for: turns[0]) != nil)
    find.close()
    #expect(!find.isActive)
    #expect(find.query.isEmpty)
    #expect(find.occurrences.isEmpty)
    #expect(find.current == nil)
    #expect(find.scrollTarget == nil)
    #expect(find.mark(for: turns[0]) == nil)
}

@Test func diacriticFoldingLimitsArePinned() {
    // "cafe" DOES match "café" — that is the feature (pinned again here so a
    // folding-library change cannot quietly regress it)...
    #expect(hitCount("cafe", in: "café") == 1)
    // ...and ICU's case-insensitive fold goes one step further than the name
    // suggests: `ß` case-folds to "ss", so "strasse" finds "straße". Pinned
    // because it is a happy accident of the fold options, not something the
    // per-Character design promises — and because it proves the fold map
    // handles a Character folding to MORE units than it occupies (the
    // starts/ends arrays must stay aligned with the folded string).
    #expect(hitCount("strasse", in: "straße") == 1)
    let slice = ("straße" as NSString).substring(with: {
        let hit = hits("STRASSE", in: "straße")[0]
        return NSRange(location: hit.location, length: hit.length)
    }())
    #expect(slice == "straße")
}
