import SwiftUI


/// One bubble.
///
/// User messages are bubbles; answers are full width, because answers contain
/// code blocks and tables and a bubble's inset is stolen from the code.
struct MessageRow: View {
    let turn: Turn
    /// Answers a parked tool call. Nil on previews and on turns with nothing to
    /// answer, which is most of them.
    var onResolve: ((ToolCall, ToolCallAction, JSONValue?) -> Void)?
    /// Re-sends this user message with new text.
    var onEdit: ((String) -> Void)? = nil
    /// Thumbs this answer up or down.
    var onRate: ((Int) -> Void)? = nil
    /// Runs the question again. Only the last answer can be re-run — anything
    /// earlier would silently orphan everything below it — so this is nil on most
    /// rows. It lives here rather than in the top bar because it belongs to the
    /// answer it replaces, and a bar button that only works on the newest reply
    /// is a coin flip.
    var onRegenerate: (() -> Void)? = nil
    var rating: Int? = nil
    /// Which sibling answer this branch is on, when there is more than one.
    var sibling: (index: Int, total: Int)? = nil
    var onSibling: ((Int) -> Void)? = nil
    /// Loads the bytes of an attached file. The file route needs the bearer
    /// token, so this cannot be an `AsyncImage` with a URL.
    var fileLoader: ((String) async -> Data?)? = nil
    /// Read-aloud, shared by the screen so only one answer speaks at a time.
    @ObservedObject var speech: SpeechPlayer

    @State private var editing = false
    @State private var draft = ""
    /// A picture the reader tapped open. Nil most of the time.
    @State private var zoom: ZoomImage?

    var body: some View {
        if turn.isUser {
            VStack(alignment: .trailing, spacing: 5) {
                if !turn.attachments.isEmpty {
                    ForEach(turn.attachments) { attachment in
                        if attachment.isImage, let dataURL = attachment.dataURL {
                            // The bytes came with the message, so there is nothing
                            // to fetch.
                            InlineImageView(dataURL: dataURL) { bytes in
                                zoom = ZoomImage(id: attachment.id, data: bytes)
                            }
                        } else if attachment.isImage, let fileLoader {
                            RemoteImageView(id: attachment.id, load: fileLoader) { bytes in
                                zoom = ZoomImage(id: attachment.id, data: bytes)
                            }
                        } else {
                            Label(attachment.name, systemImage: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.quaternary.opacity(0.5), in: .capsule)
                        }
                    }
                }
                if editing {
                    editBox
                } else {
                    HStack(alignment: .bottom, spacing: 4) {
                        // On the inner side: out there it ran into the screen
                        // edge and came back looking like a clipped glyph.
                        if onEdit != nil, !turn.text.isEmpty {
                            // A visible button rather than a long-press menu:
                            // `.textSelection(.enabled)` owns the long-press on
                            // this text, so a context menu here mostly did not
                            // open — which is why "edit doesn't work".
                            Button {
                                draft = turn.text
                                editing = true
                            } label: {
                                // `pencil.line` rather than `pencil` reads better, but it came
                            // out as a clipped corner in the simulator — same
                            // missing-glyph class as the emoji tofu. The old
                            // symbol is in every runtime.
                            Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit message")
                        }
                        // A message can be nothing but a picture, and an empty
                        // bubble with a pencil floating next to it looks like a
                        // rendering bug rather than an attachment.
                        if !turn.text.isEmpty {
                            Text(turn.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.tint.opacity(0.18), in: .rect(cornerRadius: 14))
                        }
                    }
                }
                if let sibling { siblingPager(sibling) }
            }
            // The transcript is a leading-aligned stack, so a bubble that only
            // takes its text's width would sit on the left — which is exactly
            // where a message you wrote should not be. Short messages showed
            // this first; a long one filled the row and hid the bug.
            .frame(maxWidth: .infinity, alignment: .trailing)
            .zoomCover(item: $zoom) { item in
                FullScreenImageView(data: item.data) { zoom = nil }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !turn.reasoning.isEmpty { reasoning }
                if turn.isWaitingForFirstToken {
                    // A cat, not a spinner: the wait for a local model is long
                    // enough to doubt anything started, and this one changes
                    // between runs so it stays a signal rather than wallpaper.
                    ThinkingAnimation(runID: turn.id)
                }
                // The question and the answer the user gave come *before* the
                // answer they unlocked. That is the order it happened in, it is
                // how the Claude client reads, and it keeps the question visible
                // without scrolling past the reply to remember what was asked.
                CallGroups(calls: turn.callsBeforeText, questionIncoming: turn.questionIncoming,
                           onResolve: onResolve)
                #if os(iOS)
                // Prose goes into one text view, so selection crosses headings and
                // list items the way it does anywhere else on the phone. Code and
                // tables are pulled out and given horizontal scroll: an ASCII
                // diagram is layout, and wrapping it at the edge of the screen
                // turns the box drawing into confetti.
                ForEach(segments) { segment in
                    switch segment {
                    case .prose(let text):
                        SelectableAnswer(markdown: text)
                            .accessibilityIdentifier("answerText")
                    case let .code(language, code):
                        ScrollableCodeBlock(code: code, language: language) {
                            UIPasteboard.general.string = code
                        }
                    case let .table(headers, rows):
                        ScrollableTableView(headers: headers, rows: rows)
                    case .rule:
                        Rectangle()
                            .fill(Color.separator)
                            .frame(height: 0.5)
                            .padding(.vertical, 4)
                            .accessibilityHidden(true)
                    }
                }
                #else
                ForEach(Array(Markdown.blocks(TextSanitizer.clean(renderedText)).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, streaming: turn.streaming)
                }
                .accessibilityIdentifier("answerText")
                #endif
                // A question the model asked after answering sits under the
                // answer it follows. Above it, a 4000-character reply pushes the
                // question off the top of the screen and the app looks like it
                // lost the thing the user is waiting for.
                CallGroups(calls: turn.callsAfterText, questionIncoming: turn.questionIncoming,
                           onResolve: onResolve)
                ForEach(parsed.links) { link in
                    FileLinkCard(link: link, busy: fileBusy == link.id,
                                 failed: fileFailed == link.id)
                    { onOpenLink?(link) }
                }
                if !turn.terminalFiles.isEmpty {
                    ForEach(turn.terminalFiles) { file in
                        TerminalFileCard(file: file, busy: fileBusy == file.id,
                                         failed: fileFailed == file.id)
                        { onOpenFile?(file) }
                    }
                }
                if let error = turn.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if !turn.sources.isEmpty { sources }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    /// Called when the reader taps a file the model produced in its terminal
    /// sandbox. The row cannot fetch it itself: the sandbox is found by chat, and
    /// the row does not know which chat it is in.
    var onOpenFile: ((TerminalFile) -> Void)? = nil
    /// Called for a link the answer gave to a file it made. Same reason as
    /// `onOpenFile`: the fetch needs the app's token, so the system browser
    /// cannot open these links itself.
    var onOpenLink: ((FileLink) -> Void)? = nil

    /// The parsed answer: links lifted out, prose runs, code/tables that need
    /// their own scrollable space, and the fenced blocks for the copy menu.
    ///
    /// Memoised by source text. These used to be three separate computed
    /// properties, each re-parsing the whole answer on every render, and the
    /// transcript re-renders every row on every streaming delta — see
    /// `AnswerRender`.
    private var parsed: AnswerRender.Parsed {
        AnswerRender.parse(turn.text, cacheable: !turn.streaming)
    }

    private var renderedText: String { parsed.text }

    private var segments: [AnswerSegment] { parsed.segments }

    private var codeBlocks: [String] { parsed.codeBlocks }
    /// Which sandbox file is downloading, and which failed. Owned by the screen,
    /// because the screen is the one doing the fetching.
    var fileBusy: String? = nil
    var fileFailed: String? = nil

    /// Thinking is collapsed by default and clearly marked as not-the-answer.
    /// It is also the only sign that a slow model is working rather than stuck.
    @ViewBuilder private var reasoning: some View {
        DisclosureGroup {
            Text(TextSanitizer.clean(turn.reasoning))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thoughts", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    private var editBox: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Edit your message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
            HStack(spacing: 16) {
                Button("Cancel") { editing = false }.foregroundStyle(.secondary)
                Button("Send again") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editing = false
                    if !text.isEmpty { onEdit?(text) }
                }
                .fontWeight(.semibold)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// "2 of 3 ‹ ›" — the server keeps every regenerate as a sibling, and
    /// without a way to step through them the app silently shows one branch of a
    /// tree it created itself.
    private func siblingPager(_ page: (index: Int, total: Int)) -> some View {
        HStack(spacing: 4) {
            Button { onSibling?(-1) } label: {
                Image(systemName: "chevron.left")
                    .accessibilityLabel("Previous answer")
                    .foregroundStyle(page.index > 1 ? Color.primary : Color.secondary)
                    // A bare chevron glyph is a ~12pt target, which is a coin
                    // flip on a phone. Padding plus a shape makes the whole
                    // square tappable without changing how it looks.
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .disabled(page.index <= 1)
            Text("\(page.index) of \(page.total)")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
            Button { onSibling?(1) } label: {
                Image(systemName: "chevron.right")
                    .accessibilityLabel("Next answer")
                    .foregroundStyle(page.index < page.total ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .disabled(page.index >= page.total)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
    }

    /// What the answer cites, numbered to match the `[1]` markers in the text.
    ///
    /// The stacked favicon bubbles, expanding into what was actually cited.
    ///
    /// Collapsed by default: a search that returned twelve pages produces a list
    /// longer than the answer, and the people who want it are the ones looking
    /// for it. Without this the citation markers point at nothing.
    private var sources: some View {
        SourcesRow(sources: turn.sources)
    }

    /// Thumbs up and down. Quiet by design: the answer is the point, and a
    /// permanent row of buttons competes with it.
    private var ratingRow: some View {
        HStack(spacing: 16) {
            Button { onRate?(1) } label: {
                Image(systemName: rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button { onRate?(-1) } label: {
                Image(systemName: rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Rate this answer")
    }

    @ViewBuilder private var footer: some View {
        // Bound once: `codeBlocks` is a dictionary lookup keyed by the whole
        // answer, and reading it four times hashes the answer four times.
        let blocks = codeBlocks
        if !turn.streaming, turn.isUser == false {
            HStack(spacing: 8) {
                if let model = turn.model {
                    Text(model).font(.caption2).foregroundStyle(.tertiary)
                }
                if let usage = turn.usage, let total = usage.totalTokens {
                    Text("\(total) tokens").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if onRate != nil, !turn.text.isEmpty { ratingRow }
                if let onRegenerate {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Try again")
                }
                // Spoken, not copied: an answer you are cooking or driving past
                // is still an answer. Only offered once the message has finished,
                // because reading a half-written sentence and then the rest of it
                // is worse than waiting.
                if turn.isAssistant && !turn.streaming && !turn.text.isEmpty {
                    ReadAloudButton(speech: speech, text: turn.text)
                }
                // Two flavours, because they are used for different things. Pasting
                // an answer into Mail wants the sentence, not the `##` that was
                // formatting it; pasting back into a chat or a README wants the
                // markdown. The old single button could only do the second.
                Menu {
                    Button("Copy text") { copy(TextSanitizer.plain(turn.text)) }
                    Button("Copy as Markdown") { copy(turn.text) }
                    // Selection can reach code now, but reaching it means aiming:
                    // a fenced block in the middle of a long answer is a drag and
                    // two handles. One tap to take the whole block is what people
                    // actually want when they say "copy the code".
                    if blocks.count == 1 {
                        Button("Copy code") { copy(blocks[0]) }
                    } else if !blocks.isEmpty {
                        Divider()
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, code in
                            Button("Copy code \(index + 1)") { copy(code) }
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Copy answer")
            }
        }
    }
}

/// Prose through `AttributedString`'s markdown, code through a monospace block.
///
/// `Text(markdown:)` handles inline markdown only, and answers are mostly fenced
/// blocks — so the split happens in `Markdown.blocks`, including the case that
/// matters most here: a fence that has not been closed yet.

/// The read-aloud control, kept apart because it observes the player.
///
/// `MessageRow` is `Equatable` so unchanged rows skip their body, which means the
/// row must not read anything that moves on its own. This view subscribes to
/// `SpeechPlayer` directly, so the icon still flips when playback starts or stops
/// even when the row around it was skipped.
private struct ReadAloudButton: View {
    @ObservedObject var speech: SpeechPlayer
    let text: String

    var body: some View {
        Button {
            if speech.isPlaying {
                speech.stop()
            } else {
                speech.read(text)
            }
        } label: {
            Image(systemName: speech.isPlaying ? "stop.circle.fill" : "speaker.wave.2")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(speech.isPlaying ? .primary : .tertiary)
        .accessibilityLabel(speech.isPlaying ? "Stop reading" : "Read aloud")
    }
}

/// Rows that have not changed do not need their body evaluated.
///
/// The transcript is a non-lazy stack, so one streaming delta re-renders every
/// turn in the chat. Parsing is memoised now, but not parsing beats looking a
/// parse up, and this is what keeps a very long chat cheap: only the row whose
/// text actually changed runs `body`, so the cache's capacity stops mattering.
///
/// The closures are ignored on purpose. They are rebuilt on every parent render,
/// so they can never compare equal, and each one closes over the model rather
/// than over anything that moves independently of the values compared here — a
/// skipped body cannot show a stale action. Anything observable is either a plain
/// value compared below or lives in a child view that subscribes for itself.
extension MessageRow: @MainActor Equatable {
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.turn == rhs.turn
            && lhs.rating == rhs.rating
            && lhs.fileBusy == rhs.fileBusy
            && lhs.fileFailed == rhs.fileFailed
            && lhs.sibling?.index == rhs.sibling?.index
            && lhs.sibling?.total == rhs.sibling?.total
    }
}
