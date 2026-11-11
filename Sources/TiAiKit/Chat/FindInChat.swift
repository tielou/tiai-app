import Foundation

/// Find-in-chat (issue #50): the matcher, with no view code in it.
///
/// Foundation-only on purpose — `swift test` runs on macOS, where the iOS
/// answer views do not even compile, and the thing that can actually be wrong
/// here is the folding and the offset mapping, not the highlight colour.
///
/// Two design decisions are load-bearing:
///
/// - **Folding maps back to the original string.** Case- and
///   diacritic-insensitive folding can change length (a decomposed `e\u{301}`
///   is two UTF-16 units and folds to one), so searching the folded text and
///   returning folded offsets would highlight the wrong characters. The fold
///   therefore carries a per-UTF-16-unit map back to the ORIGINAL string, and
///   `occurrences` returns ranges that slice the original correctly.
/// - **One engine for counting and for highlighting.** The bar counts with
///   `fold` + `occurrences`; `SelectableAnswer` highlights with the same two
///   functions over the attributed string it is about to draw. If they ever
///   disagree, the count lies, so there is deliberately no second matcher.
enum FindInChat {
    /// A UTF-16 range into the ORIGINAL text (UTF-16 because that is what
    /// `NSAttributedString` and `NSString` address with).
    struct Range16: Equatable, Sendable {
        let location: Int
        let length: Int
    }

    /// One hit, addressed by turn and by segment within the turn, in the order
    /// the reader would encounter them: turn order, then segment, then offset.
    struct Occurrence: Equatable, Sendable {
        let turnID: String
        let segment: Int
        let offset: Int
    }

    /// Case- AND diacritic-insensitive fold, per Character.
    ///
    /// Per Character rather than per scalar so decomposed input works: `é` as
    /// `e\u{301}` is one Character and folds to `e` whole, where folding the
    /// scalars separately would leave the combining mark behind as junk.
    static func fold(_ text: String) -> String {
        foldMap(text).folded
    }

    /// The folded string plus, for every UTF-16 unit of the folded string, the
    /// UTF-16 range in the original that produced it.
    private struct Folded {
        let folded: String
        let starts: [Int]
        let ends: [Int]
    }

    private static func foldMap(_ text: String) -> Folded {
        var folded = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var offset = 0
        for character in text {
            let f = String(character).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let units = f.utf16.count
            if units > 0 {
                folded.append(f)
                for _ in 0..<units {
                    starts.append(offset)
                    ends.append(offset + character.utf16.count)
                }
            }
            offset += character.utf16.count
        }
        return Folded(folded: folded, starts: starts, ends: ends)
    }

    /// Non-overlapping occurrences of `foldedQuery` (already folded) in `text`,
    /// in ascending UTF-16 offsets of the ORIGINAL text. An empty or
    /// whitespace-only query matches nothing.
    ///
    /// The fold can change length in BOTH directions — a decomposed `e\u{301}`
    /// (two units) folds to one, and ICU's case fold turns `ß` into "ss" —
    /// which is exactly why the map carries a range per folded unit rather
    /// than a scalar delta. Pinned by FindInChatTests.
    static func occurrences(ofFolded foldedQuery: String, in text: String) -> [Range16] {
        let needle = foldedQuery
        guard !needle.isEmpty,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let hay = foldMap(text)
        guard !hay.folded.isEmpty else { return [] }

        var out: [Range16] = []
        let haystack = hay.folded as NSString
        var from = 0
        while from < haystack.length {
            let found = haystack.range(
                of: needle, options: [],
                range: NSRange(location: from, length: haystack.length - from))
            guard found.location != NSNotFound else { break }
            // Map the folded match back: the first folded unit gives the start,
            // the last folded unit's original end gives the end.
            let lo = hay.starts[found.location]
            let hi = hay.ends[found.location + found.length - 1]
            out.append(Range16(location: lo, length: hi - lo))
            from = found.location + max(found.length, 1)
        }
        return out
    }

    /// The searchable text of one turn, one string per segment.
    ///
    /// - User turns are their raw text — the bubble renders `Text(turn.text)`
    ///   verbatim, so raw is what the reader sees.
    /// - Assistant turns are the PROSE segments only. Code blocks and tables
    ///   are EXCLUDED (v1 policy, pinned by tests): they render outside
    ///   `SelectableAnswer` in `ScrollableCodeBlock`/`ScrollableTableView`,
    ///   which have no way to paint a highlight, so counting a hit the reader
    ///   cannot be shown would make the count lie.
    ///
    /// Prose is folded down to what the reader actually sees by stripping
    /// inline markdown with the SAME engine the renderer uses —
    /// `MarkdownInline.parse(...).string`, the parser behind
    /// `AnswerText.line(_:font:color:)` in SelectableAnswer.swift and the
    /// blocks built in AnswerRender/CodeBlockView (see the cross-references
    /// there). Consequence: "bold" finds `**bold**`, but "**bold**" itself
    /// does not, because the asterisks never reach the screen.
    ///
    /// Non-prose segments map to the empty string rather than being dropped, so
    /// `segment` indexes the same `AnswerSegment` array the row's `ForEach`
    /// enumerates — see MessageRowView, which matches on that index.
    ///
    /// Goes through `AnswerRender.parse` so a find pass and a render pass share
    /// one parse per streaming delta; `cacheable: !turn.streaming` for the same
    /// reason the renderer gives it.
    @MainActor
    static func displayText(turn: Turn) -> [String] {
        if turn.isUser { return [turn.text] }
        return AnswerRender.parse(turn.text, cacheable: !turn.streaming).segments.map { segment in
            guard case .prose(let text) = segment else { return "" }
            // Best effort, like the highlight itself: AnswerText re-splits
            // the prose into blocks and joins them with one newline where
            // the segment joins with two, so a needle spanning a paragraph
            // break can count differently between bar and text. A needle
            // that spans a paragraph break is not a find anyone types.
            // `String(...characters)` rather than `.string`: the CLT SDK this
            // package builds against will not resolve `AttributedString.string`
            // — the same reason FlankingRepair spells it out.
            return String(MarkdownInline.parse(text).characters)
        }
    }

    /// All hits for `query` across `turns`, in document order. Folds the query
    /// once; an empty/whitespace query returns nothing without touching turns.
    @MainActor
    static func find(query: String, turns: [Turn]) -> [Occurrence] {
        let foldedQuery = fold(query)
        guard !foldedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        var out: [Occurrence] = []
        for turn in turns {
            let segments = displayText(turn: turn)
            for (segment, text) in segments.enumerated() {
                for hit in occurrences(ofFolded: foldedQuery, in: text) {
                    out.append(Occurrence(turnID: turn.id, segment: segment, offset: hit.location))
                }
            }
        }
        return out
    }
}
