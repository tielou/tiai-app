import SwiftUI

/// An answer split into the parts that can share one text view and the parts
/// that cannot.
///
/// Prose, headings, lists and quotes all want to wrap, reflow and be selected
/// across — that is what `SelectableAnswer` is for. A fenced block does not: an
/// ASCII architecture diagram is *layout*, and wrapping it at the edge of an
/// iPhone turns the box drawing into confetti. Same for a table: the web UI
/// gives both a horizontal scrollbar, and so must this.
enum AnswerSegment: Identifiable {
    case prose(String)
    case code(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case rule

    var id: String {
        switch self {
        case .prose(let text): return "prose-\(text.hashValue)"
        case .code(_, let code): return "code-\(code.hashValue)"
        case .table(let headers, let rows): return "table-\(headers.hashValue)-\(rows.hashValue)"
        case .rule: return "rule"
        }
    }

    /// Consecutive prose blocks stay in one run so selection still crosses from a
    /// paragraph into a list; only code and tables break the run.
    static func segments(_ blocks: [MarkdownBlock]) -> [AnswerSegment] {
        var out: [AnswerSegment] = []
        var prose: [String] = []

        func flush() {
            guard !prose.isEmpty else { return }
            out.append(.prose(prose.joined(separator: "\n\n")))
            prose = []
        }

        for block in blocks {
            switch block {
            case let .code(language, code):
                flush()
                out.append(.code(language: language, code: code))
            case let .table(headers, rows):
                flush()
                out.append(.table(headers: headers, rows: rows))
            case .rule:
                // A rule is a drawn line, not a run of dash characters. In an
                // attributed string there is nothing better to do than print
                // glyphs, and "―――――――" at body size reads as a typo.
                flush()
                out.append(.rule)
            default:
                prose.append(MarkdownBlockView.source(block))
            }
        }
        flush()
        return out
    }
}

/// A fenced block that scrolls sideways instead of wrapping.
///
/// The width is the *content's*, not the screen's: `fixedSize` lets the text
/// take the width it needs and the scroll view hands the reader the rest.
struct ScrollableCodeBlock: View {
    let code: String
    var language: String? = nil
    var onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                }
                Spacer(minLength: 6)
                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.codeBlockBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.separator, lineWidth: 0.5)
        )
    }
}

/// A markdown table with its columns aligned and the whole grid scrollable.
///
/// A text view has no grid, so the previous rendering joined cells with a
/// separator and the table collapsed into a sentence with pipes in it. Monospace
/// plus padded columns keeps the shape, and horizontal scroll keeps the last
/// column readable instead of crushed.
struct ScrollableTableView: View {
    let headers: [String]
    let rows: [[String]]

    /// Column widths measured on the *rendered* text.
    ///
    /// Measuring the raw markdown makes a bold cell look 4 characters wider than
    /// it prints, and the columns drift out of alignment by exactly the number of
    /// asterisks in the row.
    private var widths: [Int] {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        return (0..<columns).map { column in
            var longest = inline(cell(headers, column)).characters.count
            for row in rows {
                longest = max(longest, inline(cell(row, column)).characters.count)
            }
            return min(max(longest, 6), 48)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                if !headers.isEmpty { line(headers, bold: true) }
                if !headers.isEmpty && !rows.isEmpty {
                    Divider().overlay(Color.separator)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    line(row)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(10)
        }
        .background(Color.codeBlockBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }

    private func line(_ row: [String], bold: Bool = false) -> Text {
        var out = Text("")
        for (column, width) in widths.enumerated() {
            // Padded to the column width so the rows line up in a monospace face.
            let text = cell(row, column)
            let pad = String(repeating: " ", count: max(0, width - inline(text).characters.count))
            out = out + Text(inline(text + pad + "  ", bold: bold))
        }
        return out
    }

    /// Inline markdown inside a cell, with the emphasis actually applied.
    ///
    /// Cells hold markdown, not text — `**1. Fundament**` came straight out of the
    /// model — and the grid renderer passed strings through untouched, so the
    /// asterisks landed on screen. The parser records emphasis as a presentation
    /// intent rather than a font, so the fonts are rebuilt from it against the
    /// cell's own monospaced base.
    private func inline(_ string: String, bold: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: string, options: options))
            ?? AttributedString(string)
        var out = parsed
        let base = Font.system(size: 12, design: .monospaced)
        for run in parsed.runs {
            var font = bold ? base.bold() : base
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                font = font.bold()
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                font = font.italic()
            }
            out[run.range].font = font
        }
        return out
    }
}
