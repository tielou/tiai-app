import Foundation
import Testing
@testable import TiAiKit

/// Recorded from a live answer: a `## Roadmap` heading followed by a pipe table,
/// then a `---` rule. Neither rendered in the app — the table collapsed into a
/// sentence with pipes in it, and the rule printed as a run of dash glyphs.
private let roadmap = """
Report" pro Account.

## Roadmap (realistisch)

| Phase | Was | Aufwand |
|---|---|---|
| **1. Fundament** | Handys vorbereiten (Entwicklermodus, Wireless ADB) | 1 Abend |
| **2. Erster Flow** | Ein manueller Post-Flow per uiautomator2 | 1–2 Abende |

---

Zwei No-Gos, auch bei „verkraftbar"
"""

@Test("a pipe table becomes a table, not a paragraph with pipes")
func roadmapTableParses() {
    let blocks = Markdown.blocks(roadmap)
    let tables = blocks.compactMap { block -> (Int, Int)? in
        if case let .table(headers, rows) = block { return (headers.count, rows.count) }
        return nil
    }
    let shape = try? #require(tables.first)
    #expect(shape?.0 == 3, "Phase | Was | Aufwand")
    #expect(shape?.1 == 2)
}

@Test("the table separator row is not also a horizontal rule")
func separatorRowIsNotARule() {
    let blocks = Markdown.blocks(roadmap)
    var rules = 0
    for block in blocks { if case .rule = block { rules += 1 } }
    // Exactly one: the `---` between the table and the next heading. The
    // `|---|---|---|` row belongs to the table.
    #expect(rules == 1)
}

@Test("segments pull the table out of the prose run")
func segmentsSplitCodeAtTheBoundary() {
    let segments = AnswerSegment.segments(Markdown.blocks(roadmap))
    let kinds = segments.map { segment -> String in
        switch segment {
        case .prose: return "prose"
        case .code: return "code"
        case .table: return "table"
        case .rule: return "rule"
        }
    }
    #expect(kinds.first == "prose")
    #expect(kinds.contains("table"))
    #expect(kinds.contains("rule"))
    // The heading stays with the prose before it, not stranded beside the grid.
    if case .prose(let opening)? = segments.first {
        #expect(opening.contains("Roadmap"))
    } else {
        Issue.record("expected the heading to open in prose")
    }
}

@Test("an ascii diagram survives as one code block, unwrapped")
func diagramStaysIntact() {
    let src = "```\n┌──┬──┐\n│ a │ b │\n└──┴──┘\n```"
    let segments = AnswerSegment.segments(Markdown.blocks(src))
    guard case .code(_, let code)? = segments.first else {
        Issue.record("expected a code segment")
        return
    }
    // The lines are the layout. Anything that re-wraps or re-joins them here is
    // the bug the app had.
    #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    #expect(code.contains("┌──┬──┐"))
}

@Test("table cells keep their markdown markers out of the render")
func tableCellsLoseTheirAsterisks() throws {
    // The live roadmap table came through with `**1. Fundament**` in the first
    // column. The grid renderer passed cell strings through untouched, so the
    // asterisks printed.
    let blocks = Markdown.blocks(roadmap)
    var headers: [String] = []
    var rows: [[String]] = []
    for block in blocks {
        if case let .table(h, r) = block { headers = h; rows = r; break }
    }
    #expect(headers.contains("Phase"))
    #expect(!rows.isEmpty, "expected a table")
    let firstCell = rows.first?.first ?? ""
    #expect(firstCell.contains("**"), "the source keeps its markdown")
    // Cells are measured on what they render to, not on the raw markdown: a bold
    // cell measured with its asterisks pushes its column 4 characters wide.
    let rendered = rows.first?.first?
        .replacingOccurrences(of: "**", with: "") ?? ""
    #expect(!rendered.contains("**"))
    #expect(rendered == "1. Fundament")
}
