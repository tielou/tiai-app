import SwiftUI

/// Prose through `AttributedString`'s markdown, code through a monospace block.
///
/// `Text(markdown:)` handles inline markdown only, and answers are mostly fenced
/// blocks — so the split happens in `Markdown.blocks`, including the case that
/// matters most here: a fence that has not been closed yet.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var streaming = false

    var body: some View {
        switch block {
        case let .prose(text):
            Text(Self.attributed(text))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .heading(level, text):
            Text(Self.attributed(text))
                .font(level <= 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, level <= 2 ? 8 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        // Every block gets `textSelection`. The bullets and numbered items did not
        // have it, which meant the most copy-worthy part of a typical answer — the
        // list — could not be selected at all.
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.attributed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .numbered(index, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.attributed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle().frame(width: 3).foregroundStyle(.quaternary)
                Text(Self.attributed(text))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .code(language, code):
            CodeBlockView(language: language, code: code, streaming: streaming)
        case .rule:
            // A rule, not a blank line: without it `---` shows as three dashes
            // and the reader has no idea a divider was meant.
            Divider()
                .padding(.vertical, 4)
        case let .task(done, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.caption)
                    .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(Self.attributed(text))
                    .strikethrough(done, color: .secondary)
            }
        case let .table(headers, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                            Text(Self.attributed(cell))
                                .font(.callout.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            // A short row must not shift the whole grid sideways,
                            // so the header's column count wins.
                            ForEach(0..<max(headers.count, row.count), id: \.self) { column in
                                Text(Self.attributed(column < row.count ? row[column] : ""))
                                    .font(.callout)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// `.inlineOnlyPreservingWhitespace` because the block splitter already owns
    /// paragraph structure; letting the markdown parser also rewrite newlines
    /// collapses the line breaks in a pasted stack trace.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = code
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code + (streaming && Markdown.hasOpenFence(code) ? "▌" : ""))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

/// A tool call the run is waiting on, or the record of one that was answered.
///
/// Two very different things share this card: `ask_user`, where the model is
/// asking a question and the answer is free-form, and every other tool, where
/// the question is just "may I". They resolve through the same route with
/// different actions, and the server rejects the wrong pairing, so the card
/// decides which actions to offer from the call itself.
