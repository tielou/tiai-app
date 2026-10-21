import Foundation

/// A parsed answer, memoised.
///
/// Turning raw markdown into renderable pieces costs three full passes over the
/// text: `TextSanitizer.clean`, the `Markdown.blocks` split, and the segment
/// split that pulls code and tables out into their own scrollable surfaces. All
/// three were being done inside `MessageRowView.body`, and the transcript is a
/// deliberately non-lazy `VStack` — so every coalesced streaming delta (~16 a
/// second) re-parsed *every turn in the chat*, not just the one that changed.
/// Cost grew with chat length instead of staying flat, which is what "not smooth"
/// turns out to have been.
///
/// Two things this has to get right, and the first draft got the first one wrong:
///
/// - **Eviction must be least-*recently*-used.** The transcript is non-lazy, so
///   the working set is every turn in the chat rather than the handful on screen.
///   Insertion-order eviction meant that once a chat grew past the capacity, every
///   render walked the keys in the same order it inserted them and missed on all
///   of them — strictly worse than not caching, because you pay the parse *and*
///   the bookkeeping. A hit now refreshes recency.
/// - **A streaming answer must not be cached.** Each delta is a brand new string,
///   so caching them fills the cache with states that are never read again while
///   evicting the stable answers that are. Streaming rows read but never write.
///
/// MainActor because every caller is a view body, which makes the bookkeeping
/// safe without a lock and without pretending the cache is thread-safe.
@MainActor
enum AnswerRender {
    /// A class, not a struct, so callers share one parsed answer and so a test
    /// can prove the cache actually hit by comparing identity.
    final class Parsed {
        /// File links pulled out of the answer, and the answer without them.
        let links: [FileLink]
        let text: String
        /// Prose runs plus code/tables/rule blocks that need their own surface.
        let segments: [AnswerSegment]
        /// Fenced blocks in order, for the copy menu.
        let codeBlocks: [String]

        /// Characters retained, for the byte budget below. The key itself is
        /// shared with `turn.text` and costs nothing; everything here is a copy.
        let weight: Int

        init(links: [FileLink], text: String, segments: [AnswerSegment],
             codeBlocks: [String]) {
            self.links = links
            self.text = text
            self.segments = segments
            self.codeBlocks = codeBlocks
            weight = text.count + codeBlocks.reduce(0) { $0 + $1.count }
        }
    }

    private struct Entry {
        let parsed: Parsed
        /// Monotonic tick of last use. Cheaper than relinking a list on every
        /// hit, and eviction only runs when the cache is already full.
        var used: Int
    }

    private static var entries: [String: Entry] = [:]
    private static var clock = 0
    private static var weight = 0

    /// Generous, because the working set is a whole conversation and a miss is a
    /// full re-parse. The byte budget, not this, is what actually bounds memory.
    private static let capacity = 256
    /// Cached derived text is roughly three times the answers themselves; two
    /// million characters keeps that in the single-digit megabytes for any chat
    /// this app will realistically hold on screen.
    private static let weightBudget = 2_000_000

    /// Number of entries currently held. Test seam.
    static var count: Int { entries.count }

    /// Parse `raw`, reusing a previous parse of the same text if there is one.
    ///
    /// - Parameter cacheable: false for a streaming answer, whose text changes on
    ///   every delta and so would only push useful entries out.
    static func parse(_ raw: String, cacheable: Bool = true) -> Parsed {
        clock += 1
        if let hit = entries[raw] {
            entries[raw] = Entry(parsed: hit.parsed, used: clock)
            return hit.parsed
        }

        // `TextSanitizer.clean` only ever removes scalars from a fixed set, so a
        // second pass over its own output is a provable no-op — the old inline
        // code ran it twice on one path and again on another. Once is enough.
        //
        // `codeBlocks` is derived from the cleaned text while `segments` is
        // derived from the link-extracted text, as before. Whether that
        // distinction is right is a separate question with a real answer (see
        // FileLink.extract's blank-line strip) and not one to settle inside a
        // performance change.
        let cleaned = TextSanitizer.clean(raw)
        let lifted = FileLink.extract(cleaned)
        let codeBlocks = Markdown.blocks(cleaned).compactMap { block -> String? in
            if case .code(_, let code) = block { return code } else { return nil }
        }
        let parsed = Parsed(
            links: lifted.links,
            text: lifted.text,
            segments: AnswerSegment.segments(Markdown.blocks(lifted.text)),
            codeBlocks: codeBlocks)

        guard cacheable else { return parsed }

        entries[raw] = Entry(parsed: parsed, used: clock)
        weight += parsed.weight
        while entries.count > capacity || weight > weightBudget {
            guard let victim = entries.min(by: { $0.value.used < $1.value.used })?.key
            else { break }
            weight -= entries[victim]?.parsed.weight ?? 0
            entries.removeValue(forKey: victim)
        }
        return parsed
    }

    /// Drop everything. Only worth calling when nothing is showing a chat, since
    /// the next render has to re-parse the lot.
    static func clear() {
        entries.removeAll()
        weight = 0
    }
}
