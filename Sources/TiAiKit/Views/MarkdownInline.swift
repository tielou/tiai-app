import Foundation

/// The single inline-markdown entry point for the render sites (iOS chat,
/// macOS/Notes, code-block tables).
///
/// `.inlineOnlyPreservingWhitespace` because the block splitter owns
/// paragraph structure; letting the markdown parser rewrite newlines
/// collapses the line breaks in a pasted stack trace.
enum MarkdownInline {
    static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        FlankingRepair.run(into: &out)
        return out
    }
}

/// Repairs Apple's inline-markdown flanking bug (#23, #31 — the repair lost
/// with aa07070, reimplemented; #32 restored the file).
///
/// Apple's parser refuses emphasis whose content starts or ends with
/// punctuation and contains a space: `*~ fin ~*` comes back as ONE literal
/// run — the surviving asterisks in the parse output are the bug's
/// fingerprint, because a correct parse consumes its delimiters. This
/// self-gating post-pass scans the parse OUTPUT for such surviving delimiter
/// pairs, applies the intent Apple dropped, then deletes the dead
/// delimiters. It fires only on literal delimiters Apple left in ITS output,
/// so when nothing matches the pass is a byte-identical no-op by
/// construction.
///
/// Guards: #31a — the flanking blocker is `[\p{L}\p{N}\p{M}\p{C}&&[^\n]]`;
/// \n lives in \p{C}, so the ICU set-difference excludes it and a
/// soft-broken line edge (`foo\n*~ fin ~*`) still repairs. #31b — the guards
/// test DELIMITER overlap: delimiters may not touch link/emphasis/code runs,
/// but content may (nested `*~ **bold** ~*`; code `*~ `c` ~*` gains emphasis
/// by union and keeps .code, as CommonMark renders it). Only link runs
/// protect content. Escaped delimiters need no input-side scan: a parsed
/// `\*` sits inside an emphasis run, which the delimiter guard catches.
private enum FlankingRepair {
    /// Opener/closer of length 1–3 (paired by backreference), content must
    /// start AND end with punctuation/symbols — no unescaped delimiter (an
    /// escaped one may appear via `\.`; benign: the match end still pins the
    /// closer) —
    /// and span no newline.
    private static let regexes: [(NSRegularExpression, Character)] = [
        ("(?<![\\p{L}\\p{N}\\p{M}\\p{C}&&[^\\n]])(\\*{1,3})(?!\\*)"
         + "([\\p{P}\\p{S}&&[^*]](?:(?:\\\\.|[^\\n*])*[\\p{P}\\p{S}&&[^*]])?)"
         + "\\1(?!\\*)(?![\\p{L}\\p{N}\\p{M}\\p{C}&&[^\\n]])", "*"),
        ("(?<![\\p{L}\\p{N}\\p{M}\\p{C}&&[^\\n]])(_{1,3})(?!_)"
         + "([\\p{P}\\p{S}&&[^_]](?:(?:\\\\.|[^\\n_])*[\\p{P}\\p{S}&&[^_]])?)"
         + "\\1(?!_)(?![\\p{L}\\p{N}\\p{M}\\p{C}&&[^\\n]])", "_"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// A match in grapheme offsets into the parse output.
    private struct Match {
        var opener: Range<Int>
        var content: Range<Int>
        var closer: Range<Int>
        var delim: Character
        var start: Int { opener.lowerBound }
        var end: Int { closer.upperBound }
    }

    static func run(into attr: inout AttributedString) {
        let chars = Array(attr.characters)
        // Cheap gate: no delimiter survived into the output — nothing to repair.
        guard chars.contains("*") || chars.contains("_") else { return }
        let s = String(attr.characters)

        var matches: [Match] = []
        for (regex, delim) in regexes {
            for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let full = Range(m.range, in: s),
                      let open = Range(m.range(at: 1), in: s),
                      let body = Range(m.range(at: 2), in: s) else { continue }
                let hi = s.distance(from: s.startIndex, to: full.upperBound)
                let oLo = s.distance(from: s.startIndex, to: open.lowerBound)
                let oHi = s.distance(from: s.startIndex, to: open.upperBound)
                let cLo = s.distance(from: s.startIndex, to: body.lowerBound)
                let cHi = s.distance(from: s.startIndex, to: body.upperBound)
                matches.append(Match(
                    opener: oLo..<oHi,
                    content: cLo..<cHi,
                    closer: (hi - (oHi - oLo))..<hi,
                    delim: delim))
            }
        }
        guard !matches.isEmpty else { return }

        // Merge both pattern streams sorted by start; first wins on overlap.
        matches.sort { $0.start < $1.start }
        var candidates: [Match] = []
        var lastEnd = -1
        for m in matches where m.start >= lastEnd {
            // A same-char delimiter glued to the pair means the run lengths
            // disagreed (`**~ a ~*`); pairing is ambiguous — accepted false
            // negative, stay literal.
            if m.opener.lowerBound > 0, chars[m.opener.lowerBound - 1] == m.delim { continue }
            if m.end < chars.count, chars[m.end] == m.delim { continue }
            candidates.append(m)
            lastEnd = m.end
        }

        // Protection ranges (grapheme offsets) from the parse output's runs.
        var delimProtected: [Range<Int>] = []
        var contentProtected: [Range<Int>] = []
        for run in attr.runs {
            let lo = offset(of: run.range.lowerBound, in: attr)
            let hi = offset(of: run.range.upperBound, in: attr)
            guard lo < hi else { continue }
            let intent = run.inlinePresentationIntent
            if run.link != nil {
                delimProtected.append(lo..<hi)
                contentProtected.append(lo..<hi)
            } else if let intent, intent.contains(.emphasized)
                        || intent.contains(.stronglyEmphasized)
                        || intent.contains(.code) {
                delimProtected.append(lo..<hi)
            }
        }

        let intersects: (Range<Int>, [Range<Int>]) -> Bool = { r, ranges in
            ranges.contains { max($0.lowerBound, r.lowerBound) < min($0.upperBound, r.upperBound) }
        }

        var accepted: [Match] = []
        for m in candidates {
            if intersects(m.opener, delimProtected) || intersects(m.closer, delimProtected) { continue }
            if intersects(m.content, contentProtected) { continue }
            accepted.append(m)
        }

        // Apply the intent as a UNION to run∩content subranges BEFORE any
        // deletion (length-preserving, offsets stable). Snapshot the runs per
        // match because setting attributes splits them.
        for m in accepted {
            let intents: InlinePresentationIntent = m.opener.count >= 3
                ? [.emphasized, .stronglyEmphasized]
                : (m.opener.count == 2 ? .stronglyEmphasized : .emphasized)
            let snapshot = attr.runs.map {
                (offset(of: $0.range.lowerBound, in: attr),
                 offset(of: $0.range.upperBound, in: attr),
                 $0.inlinePresentationIntent)
            }
            for (lo, hi, existing) in snapshot {
                let a = max(lo, m.content.lowerBound)
                let b = min(hi, m.content.upperBound)
                guard a < b else { continue }
                let sub = attr.index(attr.startIndex, offsetByCharacters: a)
                    ..< attr.index(attr.startIndex, offsetByCharacters: b)
                attr[sub].inlinePresentationIntent = (existing ?? []).union(intents)
            }
        }

        // Delete delimiters back-to-front so earlier offsets stay valid.
        // (`removeSubrange` — AttributedString is a RangeReplaceableCollection;
        // `removeCharacters(in:)` only exists on AttributedSubstring here.)
        for m in accepted.sorted(by: { $0.start > $1.start }) {
            for r in [m.closer, m.opener] {
                attr.removeSubrange(
                    attr.index(attr.startIndex, offsetByCharacters: r.lowerBound)
                        ..< attr.index(attr.startIndex, offsetByCharacters: r.upperBound))
            }
        }
    }

    /// Grapheme offset of an index — `String(attr.characters)` is
    /// grapheme-for-grapheme identical to the attribute character view.
    private static func offset(of index: AttributedString.Index, in attr: AttributedString) -> Int {
        attr.characters.distance(from: attr.characters.startIndex, to: index)
    }
}
