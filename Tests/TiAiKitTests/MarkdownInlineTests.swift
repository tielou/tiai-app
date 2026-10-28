import Foundation
import Testing
@testable import TiAiKit

// Helpers local to this file.

/// The plain Apple parse, without the flanking repair — the no-op baseline.
private func bare(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}

/// The repair must be a byte-identical no-op: same string, same attributes.
private func expectNoOp(_ s: String) {
    #expect(MarkdownInline.parse(s) == bare(s), "expected byte-identical no-op for \(s.debugDescription)")
}

private func plain(_ parsed: AttributedString) -> String {
    String(parsed.characters)
}

/// Intent of the first run whose text contains `substring`.
private func intent(_ parsed: AttributedString, _ substring: String) -> InlinePresentationIntent? {
    for run in parsed.runs where String(parsed.characters[run.range]).contains(substring) {
        return run.inlinePresentationIntent
    }
    return nil
}

// MARK: - #23 core repairs

@Test("punctuation-bracketed emphasis is repaired (#23)")
func starPunctuationContent() {
    let p = MarkdownInline.parse("*~ fin ~*")
    #expect(plain(p) == "~ fin ~")
    #expect(intent(p, "fin")?.contains(.emphasized) == true)
}

@Test("double delimiters repair to strong (#23)")
func doubleDelimiters() {
    let p = MarkdownInline.parse("**~ fin ~**")
    #expect(plain(p) == "~ fin ~")
    #expect(intent(p, "fin")?.contains(.stronglyEmphasized) == true)
}

@Test("boundary pins: prose-glued strong, 4-star runs, grapheme adjacency")
func boundaryPins() {
    // Glued-delimiter guard in prose context (the guard rejects `**~ a ~*`
    // for ambiguous run lengths; a well-formed pair inside prose must still
    // repair).
    let p = MarkdownInline.parse("x **~ a ~** y")
    #expect(plain(p) == "x ~ a ~ y")
    #expect(intent(p, "a")?.contains(.stronglyEmphasized) == true)
    // A 4-star run is never an opener ({1,3} + the not-followed-by guard):
    // stays literal, byte-identical to the bare parse.
    expectNoOp("****~ x ~****")
    // Grapheme-cluster adjacency exercises the String(characters) offset ->
    // offsetByCharacters mapping with multi-scalar clusters (family emoji is
    // one grapheme, many scalars; a utf16 shortcut would misalign here).
    let e = MarkdownInline.parse("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} *~ fin ~*")
    #expect(plain(e).hasSuffix("~ fin ~"))
    #expect(intent(e, "fin")?.contains(.emphasized) == true)
}

@Test("underscore delimiters repair too (#23)")
func underscoreDelimiters() {
    // Measurement note: the issue's `_~ fin _` cannot match — its content
    // `~ fin ` ends with a space, not punctuation (the repair requires
    // punctuation-edged content). The true underscore mirror of `*~ fin ~*`
    // is `_~ fin ~_`; `_~ fin _` is pinned as an accepted no-op below.
    let p = MarkdownInline.parse("_~ fin ~_")
    #expect(plain(p) == "~ fin ~")
    #expect(intent(p, "fin")?.contains(.emphasized) == true)
}

@Test("triple delimiters carry both intents (#23)")
func tripleDelimiters() {
    // Apple parses `***~x~***` correctly (delimiters consumed), so the repair
    // must leave it byte-identical — and the result carries both intents.
    expectNoOp("***~x~***")
    let p = MarkdownInline.parse("***~x~***")
    #expect(plain(p) == "x")
    #expect(intent(p, "x")?.contains(.emphasized) == true)
    #expect(intent(p, "x")?.contains(.stronglyEmphasized) == true)
}

@Test("nested emphasis unions onto the inner run (#23)")
func nestedEmphasis() {
    let p = MarkdownInline.parse("*~ **bold** ~*")
    #expect(plain(p) == "~ bold ~")
    let i = intent(p, "bold")
    #expect(i?.contains(.stronglyEmphasized) == true)
    #expect(i?.contains(.emphasized) == true)
}

@Test("only the content is emphasized, surrounding prose stays upright")
func onlyTheContentIsEmphasized() {
    let p = MarkdownInline.parse("x *~ fin ~* more")
    #expect(plain(p) == "x ~ fin ~ more")
    #expect(intent(p, "fin")?.contains(.emphasized) == true)
    #expect(intent(p, "x ")?.contains(.emphasized) != true)
    #expect(intent(p, " more")?.contains(.emphasized) != true)
}

// MARK: - #31a newline adjacency

@Test("newline-adjacent delimiters repair (#31a)", arguments: [
    ("foo\n*~ fin ~*", "~ fin ~"),
    ("*~ fin ~*\nbar", "~ fin ~"),
    ("a\n*~ x ~*\nb", "~ x ~"),
])
func newlineAdjacent(input: String, content: String) {
    let p = MarkdownInline.parse(input)
    #expect(!plain(p).contains("*"))
    #expect(plain(p).contains(content))
    #expect(intent(p, content)?.contains(.emphasized) == true)
}

// MARK: - #31b code inside repaired emphasis

@Test("code inside repaired emphasis keeps .code and gains emphasis (#31b)")
func codeInsideEmphasis() {
    let p = MarkdownInline.parse("*~ `c` ~*")
    #expect(plain(p) == "~ c ~")
    let i = intent(p, "c")
    #expect(i?.contains(.code) == true)
    #expect(i?.contains(.emphasized) == true)
}

// MARK: - no-op battery (byte-identical to the bare Apple parse)

@Test("correct parses and non-emphasis stay byte-identical", arguments: [
    "*attention*",
    "**bold**",
    "***c***",
    "foo *bar* baz",
    "*~fin~*",           // punctuation-edged but no inner space: Apple parses it
    "*escaped \\* star*", // the escaped star survives into the output, inside an em run
    "snake_case_word",
    "3 * 4 * 5",
    "[*link*](https://x.com)",
    "`*x*`",             // inside a code span
    "*",
    "**",
    "*~ fin",            // unclosed
    "",
    "* ~ fin ~ *",       // CommonMark-correct literal (space after opener)
    "a * b * c",
])
func noOpBattery(input: String) {
    expectNoOp(input)
}

// MARK: - accepted false negatives (degrade to the literal text, by design)

@Test("accepted false negatives stay literal", arguments: [
    // Apple consumes the inner `~ ~` as strikethrough, leaving its output
    // `*~ a * z * b ~*` — the asterisk candidates are no longer punctuation-
    // edged, so the regex never pairs them at all. Measured on this SDK; if
    // Apple's output shifts this pin may flip (to a clean repair, not a
    // misrender).
    "*~ a ~* z *~ b ~*",
    "**~ a ~*",          // unbalanced delimiter run: glued extra delimiter char
    "_~ fin _",          // content ends with a space, not punctuation
    "[click *~ here ~*](https://x.com)", // delimiters inside the link run
    "[a *~ b ~* c](https://x.com)",      // delimiters inside the link run
])
func acceptedFalseNegatives(input: String) {
    expectNoOp(input)
}

// MARK: - guard boundaries

@Test("a link adjacent to the delimiters does not block the repair")
func autolinkAdjacent() {
    let p = MarkdownInline.parse("https://x.com *~ fin ~*")
    #expect(plain(p) == "https://x.com ~ fin ~")
    #expect(intent(p, "fin")?.contains(.emphasized) == true)
    var linkTexts: [String] = []
    for run in p.runs where run.link != nil {
        linkTexts.append(String(p.characters[run.range]))
    }
    #expect(linkTexts == ["https://x.com"])
}

// MARK: - idempotence and purity

@Test("the repaired string re-parses as a no-op (idempotence)", arguments: [
    "*~ fin ~*",
    "**~ fin ~**",
    "_~ fin ~_",
    "*~ **bold** ~*",
    "foo\n*~ fin ~*",
    "*~ `c` ~*",
])
func repairedStringIsStable(input: String) {
    let once = MarkdownInline.parse(input)
    // No dead delimiters left behind...
    #expect(!plain(once).contains("*"))
    #expect(!plain(once).contains("_"))
    // ...and re-parsing the repaired string changes nothing (self-gating).
    #expect(MarkdownInline.parse(plain(once)) == bare(plain(once)))
}

@Test("parse is pure: same input, same output, no shared state")
func purity() {
    for input in ["*~ fin ~*", "foo\n*~ fin ~*", "*attention*", "*~ `c` ~*"] {
        #expect(MarkdownInline.parse(input) == MarkdownInline.parse(input))
    }
}
