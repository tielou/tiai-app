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
    /// Find-in-chat (issue #50): the FOLDED needle (folded by `FindInChat.fold`
    /// upstream, so the highlight and the bar's count provably share one fold
    /// engine), and the UTF-16 offset of the current hit within this segment's
    /// rendered text, if the current hit is in this segment.
    var findQuery: String = ""
    var findCurrent: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeUIView(context: Context) -> AnswerTextView {
        let view = AnswerTextView()
        // Set here rather than from the SwiftUI wrapper: the identifier has to
        // land on the element the accessibility tree actually exposes, and that
        // is the text view, not the representable around it.
        view.accessibilityIdentifier = "answerText"
        view.isEditable = false
        view.isSelectable = true
        // Scrolling and self-sizing have to go, or the text view competes with the
        // transcript's scroll view and SwiftUI gets no intrinsic height.
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        // Link taps go through the app rather than opening MobileSafari, which has
        // no session and would answer a file link with a 401.
        view.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: AnswerTextView, context: Context) {
        context.coordinator.onLink = onLink
        // Guard on the string, not the attributed value. Streaming re-renders on
        // every coalesced delta, and building the attributed string means parsing
        // the whole answer again — comparing the *input* is free by comparison, and
        // writing `attributedText` restarts layout and drops any selection the
        // reader has in flight.
        //
        // The find fields are in the guard because stepping next/previous changes
        // ONLY them: without this the highlight would never move. Rewriting
        // `attributedText` for a highlight-only change drops an in-flight
        // selection — accepted: while find is active, the find is what the
        // reader is doing, not selecting.
        guard context.coordinator.lastMarkdown != markdown
            || context.coordinator.lastFindQuery != findQuery
            || context.coordinator.lastFindCurrent != findCurrent
        else { return }
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastFindQuery = findQuery
        context.coordinator.lastFindCurrent = findCurrent
        let attr = NSMutableAttributedString(attributedString: AnswerText.attributed(markdown))
        if !findQuery.isEmpty {
            SelectableAnswer.applyFindHighlight(attr, query: findQuery, current: findCurrent)
        }
        view.attributedText = attr
        context.coordinator.invalidateIntrinsic()
    }

    /// Paint the hits. Same `FindInChat.occurrences` the count uses, run over
    /// the attributed string's own text, so the offsets address what is drawn.
    /// Best effort on `current`: its offset was computed on the segment's
    /// display text, which can drift a newline apart from this string on
    /// multi-block segments — a current that fails to match falls back to
    /// the plain yellow, which is a colour difference, not a wrong location.
    static func applyFindHighlight(
        _ attr: NSMutableAttributedString, query: String, current: Int?
    ) {
        attr.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: attr.length))
        for hit in FindInChat.occurrences(ofFolded: query, in: attr.string) {
            let isCurrent = current != nil && hit.location == current
            attr.addAttribute(
                .backgroundColor,
                value: isCurrent ? UIColor.systemOrange
                                 : UIColor.systemYellow.withAlphaComponent(0.35),
                range: NSRange(location: hit.location, length: hit.length))
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView view: AnswerTextView, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        guard width > 0 else { return nil }
        let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLink: ((URL) -> Void)?
        var lastMarkdown: String?
        var lastFindQuery: String?
        var lastFindCurrent: Int?
        private weak var view: UITextView?

        init(onLink: ((URL) -> Void)?) { self.onLink = onLink }

        /// Our own long-press, because the built-in one never fires here.
        ///
        /// A `UITextView` inside a SwiftUI `ScrollView` loses the press to the
        /// scroll view's gesture: the text view is selectable, the handles and
        /// the loupe exist, and nothing on screen ever offered them — a long press
        /// did nothing at all, which reads as "copy is broken". An explicit
        /// recogniser on the text view itself wins, selects the word under the
        /// finger, and the system callout follows on its own.
        func attach(to view: UITextView) {
            self.view = view
            let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            press.minimumPressDuration = 0.3
            press.cancelsTouchesInView = false
            press.delegate = self
            view.addGestureRecognizer(press)
        }

        @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            view.becomeFirstResponder()
            // Word under the finger, the way a long press works everywhere else
            // on iOS. Falling back to a caret is better than selecting nothing.
            view.selectedTextRange = word(at: position, in: view)
                ?? view.textRange(from: position, to: position)
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in range: NSRange) -> Bool {
            guard let onLink else { return true }
            onLink(URL)
            return false
        }

        /// The word under a long press, grown out from the caret position one
        /// character at a time. The tokenizer APIs that do this have changed twice
        /// and every spelling of them is either deprecated or awkward from Swift;
        /// walking the string is short, obvious and cannot break on an OS bump.
        private func word(at position: UITextPosition, in view: UITextView) -> UITextRange? {
            guard let text = view.text as NSString?, text.length > 0 else { return nil }
            let start = view.offset(from: view.beginningOfDocument, to: position)
            guard start >= 0, start < text.length else { return nil }
            func isWord(_ c: unichar) -> Bool {
                guard let scalar = UnicodeScalar(c) else { return false }
                return Character(scalar).isLetter || Character(scalar).isNumber
            }
            var from = start
            while from > 0, isWord(text.character(at: from - 1)) { from -= 1 }
            var to = start
            while to < text.length, isWord(text.character(at: to)) { to += 1 }
            guard let lo = view.position(from: view.beginningOfDocument, offset: from),
                  let hi = view.position(from: view.beginningOfDocument, offset: to),
                  to > from
            else { return nil }
            return view.textRange(from: lo, to: hi)
        }

        func invalidateIntrinsic() { view?.invalidateIntrinsicContentSize() }
        func textViewDidChangeSelection(_ textView: UITextView) {}
    }
}

extension SelectableAnswer.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// A text view that does not let the surrounding scroll view veto its gestures.
final class AnswerTextView: UITextView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The transcript's pan is for scrolling; it must not be a precondition for
        // selecting a word.
        otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// Markdown to one `NSAttributedString`, with the block structure expressed as
/// fonts, indents and spacing instead of as view nesting.
///
/// Cross-reference: `FindInChat.displayText` mirrors this pipeline (same
/// `Markdown.blocks` + `MarkdownInline` chain) so the find count matches what
/// is drawn here; change one, check the other (issue #50).
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
        let parsed = MarkdownInline.parse(text)
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
