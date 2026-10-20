import SwiftUI
#if os(iOS)
import UIKit

/// The whole answer in one selectable run of text.
///
/// SwiftUI's `.textSelection(.enabled)` scopes selection to a single `Text`, and
/// a markdown answer is a stack of them — so selecting a sentence that ran from a
/// paragraph into a list meant selecting one block, then the next, then pasting
/// them together. That is not how anyone copies text on an iPhone.
///
/// A non-editable `UITextView` is what the system's own selection UI is built
/// for: long-press, loupe, word/line/sentence handles, Select all, and a drag
/// that crosses headings, list items and code without noticing they were
/// rendered differently. So the markdown is turned into one attributed string
/// and handed over whole.
///
/// Layout is carried by paragraph styles rather than by nested views, which is
/// the trade: no per-block copy button any more, but the text behaves like text.
struct SelectableAnswer: UIViewRepresentable {
    let markdown: String
    var onLink: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        // Scrolling and self-sizing have to go, or the text view competes with the
        // transcript's scroll view and SwiftUI gets no intrinsic height.
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        // Link taps go through the app rather than opening MobileSafari, which has
        // no session and would answer a file link with a 401.
        view.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onLink = onLink
        let next = AnswerText.attributed(markdown)
        // Setting `attributedText` restarts the text view's layout and drops any
        // selection the reader has in flight. While streaming, this runs on every
        // coalesced delta, so only write when it actually changed.
        if view.attributedText != next { view.attributedText = next }
        context.coordinator.invalidateIntrinsic()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView view: UITextView, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        guard width > 0 else { return nil }
        let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLink: ((URL) -> Void)?
        private weak var view: UITextView?

        init(onLink: ((URL) -> Void)?) { self.onLink = onLink }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in range: NSRange) -> Bool {
            guard let onLink else { return true }
            onLink(URL)
            return false
        }

        func invalidateIntrinsic() { view?.invalidateIntrinsicContentSize() }
        func textViewDidChangeSelection(_ textView: UITextView) {}
    }
}

/// Markdown to one `NSAttributedString`, with the block structure expressed as
/// fonts, indents and spacing instead of as view nesting.
enum AnswerText {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let blocks = Markdown.blocks(TextSanitizer.clean(markdown))
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(render(block))
        }
        return out
    }

    private static func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case let .prose(text):
            return line(text, font: .body, color: .label)
        case let .heading(level, text):
            let font: UIFont
            switch level {
            case 1: font = UIFont.preferredFont(forTextStyle: .title2).bolded
            case 2: font = UIFont.preferredFont(forTextStyle: .title3).bolded
            default: font = UIFont.preferredFont(forTextStyle: .headline)
            }
            let result = line(text, font: font, color: .label)
            // A heading with no air above it reads as a very loud sentence.
            result.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: 10), range: whole(result))
            return result
        case .bullet(let text):
            return marker("•  ", text, color: .secondaryLabel)
        case let .numbered(index, text):
            return marker("\(index).  ", text, color: .secondaryLabel)
        case .quote(let text):
            // A quote rule is not available on a text view's paragraph style, so
            // the indent does the work and the dimmer colour says the rest.
            let result = line(text, font: .body, color: .secondaryLabel)
            result.addAttribute(
                .paragraphStyle, value: paragraph(indent: 14, firstLineIndent: -14),
                range: whole(result))
            return result
        case .rule:
            return line("―――――――", font: .body, color: .tertiaryLabel)
        case let .task(done, text):
            return marker(done ? "☑  " : "☐  ", text, color: .label)
        case let .table(headers, rows):
            // A text view has no grid, so the table keeps its shape as aligned
            // columns rather than collapsing into a sentence with pipes in it.
            var lines: [String] = []
            if !headers.isEmpty { lines.append(headers.joined(separator: "  ·  ")) }
            for row in rows { lines.append(row.joined(separator: "  ·  ")) }
            let result = line(lines.joined(separator: "\n"), font: .body, color: .label)
            result.addAttribute(
                .paragraphStyle, value: paragraph(indent: 10, firstLineIndent: 0), range: whole(result))
            return result
        case let .code(_, code):
            let result = NSMutableAttributedString(
                string: code,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.quaternarySystemFill,
                    .paragraphStyle: paragraph(spacingBefore: 6, spacingAfter: 6),
                ])
            return result
        }
    }

    /// A bullet or number hanging in the left margin, with the text wrapping back
    /// to the marker rather than under it.
    private static func marker(_ mark: String, _ text: String, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: mark, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: color])
        out.append(line(text, font: .body, color: .label))
        out.addAttribute(.paragraphStyle, value: paragraph(indent: 18, firstLineIndent: -18), range: whole(out))
        return out
    }

    /// One block's text, with inline markdown (`**bold**`, `_italic_`, links)
    /// actually applied. Handing the raw string over left the asterisks on screen
    /// — the block structure was rendered but the inline layer was not.
    private static func line(_ text: String, font: UIFont, color: UIColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let out = NSMutableAttributedString(parsed)
        let full = whole(out)
        out.addAttribute(.foregroundColor, value: color, range: full)
        out.addAttribute(.font, value: font, range: full)
        out.addAttribute(.paragraphStyle, value: paragraph(), range: full)
        // Apple's parser records emphasis as a presentation intent, not a font,
        // so the fonts have to be rebuilt from it against the block's own base.
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent
            guard intent != nil else { continue }
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
            if intent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
            guard !traits.isEmpty,
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { continue }
            let range = NSRange(run.range, in: parsed)
            out.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
        }
        return out
    }

    private static func whole(_ string: NSAttributedString) -> NSRange {
        NSRange(location: 0, length: string.length)
    }

    private static func paragraph(
        indent: CGFloat = 0, firstLineIndent: CGFloat = 0,
        spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 6
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        return style
    }
}

private extension UIFont {
    var bolded: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold)
            else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    static var body: UIFont { UIFont.preferredFont(forTextStyle: .body) }
}

#endif
