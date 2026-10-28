import Foundation

/// The single inline-markdown entry point for the render sites (iOS chat,
/// macOS/Notes, code-block tables).
///
/// **History, so nobody is fooled:** `fixes #23` (aa07070) wired these three
/// call sites to `MarkdownInline.parse` but never committed this file — main
/// did not compile until it was restored (issue #32). The flanking-bug repair
/// that commit describes (repairing Apple's refusal to italicize
/// punctuation-bracketed content like `*~ fin ~*`) was lost with the file and
/// is NOT reimplemented here; #23 is reopened for it. Until then this is the
/// plain Apple parse — byte-identical to the pre-#23 behavior of all three
/// call sites, which is the honest floor, not a regression.
///
/// `.inlineOnlyPreservingWhitespace` because the block splitter owns
/// paragraph structure; letting the markdown parser rewrite newlines
/// collapses the line breaks in a pasted stack trace.
enum MarkdownInline {
    static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
