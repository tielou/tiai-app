import Foundation

/// The single source of truth for how a block becomes the text the reader sees.
///
/// `AnswerText.attributed` (iOS, SelectableAnswer.swift) draws an answer by
/// running `TextSanitizer.clean` -> `Markdown.blocks` -> per-block rendering
/// with RENDERED markers ("•  ", "3.  ", "☑  ") joined by ONE newline. Find
/// needs the exact same string: if the bar counts and offsets against one
/// text while the text view highlights another, the current-hit marker drifts
/// or lands on the wrong hit (issue #50 review). So the string decisions —
/// which marker a block renders with, how tables and rules become text, how
/// inline markdown is stripped — live here, in one Foundation-only place, and
/// BOTH the attributed renderer and `FindInChat.displayText` consume them.
/// The renderer keeps only the styling decisions (fonts, colours, indents).
///
/// Identity, by construction:
/// `AnswerText.attributed(md).string == AnswerPlainText.plainText(md)`.
enum AnswerPlainText {
    /// What a rule renders as. A text view has no rule, so the glyph row is
    /// the visible text.
    static let ruleText = "―――――――"

    /// The rendered marker that precedes a block's text ("•  ", "3.  ", "☑  "),
    /// or "" for blocks that render without one. NOT the source markers
    /// ("## ", "- ", "1. ") — those are stripped, they never reach the screen.
    static func marker(for block: MarkdownBlock) -> String {
        switch block {
        case .bullet: return "•  "
        case .numbered(index: let index, _): return "\(index).  "
        case .task(done: let done, _): return done ? "☑  " : "☐  "
        default: return ""
        }
    }

    /// The string the inline layer (emphasis, links) parses for a block: the
    /// block's own text for prose-ish blocks, the joined cell rows for a
    /// table, the literal glyphs for a rule. `nil` for code, which is shown
    /// verbatim without an inline pass.
    static func inlineSource(for block: MarkdownBlock) -> String? {
        switch block {
        case let .prose(text), let .heading(_, text), let .quote(text),
             let .bullet(text), let .numbered(_, text), let .task(_, text):
            return text
        case .rule:
            return ruleText
        case let .table(headers, rows):
            // A text view has no grid, so the table keeps its shape as
            // separator-joined rows rather than collapsing into a sentence
            // with pipes in it.
            var lines: [String] = []
            if !headers.isEmpty { lines.append(headers.joined(separator: "  ·  ")) }
            for row in rows { lines.append(row.joined(separator: "  ·  ")) }
            return lines.joined(separator: "\n")
        case .code:
            return nil
        }
    }

    /// Inline markdown stripped down to the characters that reach the screen.
    ///
    /// `String(...characters)` rather than `.string`: the CLT SDK this package
    /// builds against will not resolve `AttributedString.string` — the same
    /// reason FlankingRepair spells it out.
    static func inline(_ text: String) -> String {
        String(MarkdownInline.parse(text).characters)
    }

    /// The full visible text of one block: rendered marker + inline-stripped
    /// text (or the code body, verbatim).
    static func string(for block: MarkdownBlock) -> String {
        if case let .code(_, code) = block { return code }
        return marker(for: block) + inline(inlineSource(for: block) ?? "")
    }

    /// The plain text of an answer exactly as `AnswerText.attributed` renders
    /// it: clean -> blocks -> per-block visible string -> joined by ONE
    /// newline (paragraph spacing is a paragraph style, not blank lines).
    static func plainText(_ markdown: String) -> String {
        Markdown.blocks(TextSanitizer.clean(markdown))
            .map { string(for: $0) }
            .joined(separator: "\n")
    }
}
