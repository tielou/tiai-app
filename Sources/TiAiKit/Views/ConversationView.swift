import SwiftUI

/// The conversation screen.
///
/// Two behaviours are worth calling out because getting them wrong is the
/// difference between "feels native" and "feels like a website":
///
/// * It scrolls to follow the answer only while the reader is already at the
///   bottom. Auto-scroll that fights someone who scrolled up to re-read a
///   paragraph is the single most annoying thing a chat app can do.
/// * The composer stays usable while a run is in flight — the send button
///   becomes Stop, and the draft is not thrown away.
public struct ConversationView: View {
    private let session: SessionStore
    @State private var conversation: ConversationModel
    @State private var atBottom = true
    @Environment(\.scenePhase) private var scenePhase
    /// Kept for the composer and the model sheet: the conversation only needs the
    /// id to seed itself, but the UI needs the whole record to show what each
    /// model can do. Dropping this is how the model sheet renders empty.
    @State private var models: [ChatModel]

    public init(session: SessionStore, chatID: String?, title: String = "New Chat", models: [ChatModel] = []) {
        self.session = session
        self._models = State(initialValue: models)
        _conversation = State(
            initialValue: ConversationModel(
                chatID: chatID,
                title: title,
                models: models,
                client: session.client,
                hub: session.eventHub()))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            transcript
            if let error = conversation.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.08))
            }
            ComposerView(conversation: conversation, models: models)
        }
        .inlineTitle(conversation.title)
        .toolbar { toolbar }
        .task {
            await conversation.connect()
            await conversation.load()
            // The list may not have finished loading models before someone taps
            // a chat; a conversation with no model to name cannot send anything.
            if models.isEmpty { models = (try? await session.client.models()) ?? [] }
            conversation.setModels(models)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS kills the socket on background anyway; saying so locally beats
            // coming back to a spinner that has been dead for ten minutes.
            if phase != .active { conversation.abandon() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.turns.isEmpty { EmptyTranscript(model: conversation.model) }
                    ForEach(conversation.turns) { turn in
                        MessageRow(turn: turn) { call, action, answers in
                            conversation.resolve(
                                messageID: turn.id, call: call, action: action, answers: answers)
                        }
                            .id(turn.id)
                    }
                    // Reserves room so the last line is not hidden behind the
                    // composer, and gives the scroll anchor something to hit.
                    Color.clear.frame(height: 8).id(BottomAnchor.id)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            // The platform's own "stick to the bottom as content grows" behaviour.
            // Scrolling to the bottom by hand is always a frame late: the delta
            // arrives, the view scrolls to where the bottom *was*, and the line
            // that just rendered lands below the fold. On the last token of a
            // message that is permanent, which is how answers were ending up
            // hidden behind the composer.
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let edge = geometry.contentOffset.y + geometry.containerSize.height
                return geometry.contentSize.height - edge < 120
            } action: { _, value in
                atBottom = value
            }
            .onChange(of: conversation.turns.last?.text) { _, _ in
                guard atBottom else { return }
                // After layout, not during it — see defaultScrollAnchor above.
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
            }
            .onChange(of: conversation.turns.count) { _, _ in
                atBottom = true
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onChange(of: conversation.phase.isBusy) { _, busy in
                // The last token is also the one most likely to land below the
                // fold: there is no following delta to trigger the next scroll.
                // When the run ends, settle once more after layout has finished.
                // (Observed as a Bool: `onChange(of: conversation.phase)` inside
                // a ScrollView resolves to a scroll-phase overload and fails.)
                guard !busy, atBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if conversation.phase.isBusy {
                Button {
                    conversation.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            } else {
                Button {
                    conversation.regenerate()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(!conversation.turns.contains(where: \.isUser))
            }
        }
    }
}

private enum BottomAnchor { static let id = "transcript-bottom" }

private struct EmptyTranscript: View {
    var model: String
    var body: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "bubble.left")
        } description: {
            Text(model.isEmpty ? "Pick a model and ask." : "Ask \(model) something.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// One bubble.
///
/// User messages are bubbles; answers are full width, because answers contain
/// code blocks and tables and a bubble's inset is stolen from the code.
struct MessageRow: View {
    let turn: Turn
    /// Answers a parked tool call. Nil on previews and on turns with nothing to
    /// answer, which is most of them.
    var onResolve: ((ToolCall, ToolCallAction, JSONValue?) -> Void)?

    var body: some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.tint.opacity(0.18), in: .rect(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !turn.reasoning.isEmpty { reasoning }
                if turn.isWaitingForFirstToken {
                    Label("Thinking…", systemImage: "ellipsis")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(Array(Markdown.blocks(TextSanitizer.clean(turn.text)).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, streaming: turn.streaming)
                }
                ForEach(turn.calls) { call in
                    ToolCallCard(call: call) { action, answers in
                        onResolve?(call, action, answers)
                    }
                }
                if let error = turn.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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

    @ViewBuilder private var footer: some View {
        if !turn.streaming, turn.isUser == false {
            HStack(spacing: 8) {
                if let model = turn.model {
                    Text(model).font(.caption2).foregroundStyle(.tertiary)
                }
                if let usage = turn.usage, let total = usage.totalTokens {
                    Text("\(total) tokens").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = turn.text
                    #endif
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
        case let .code(language, code):
            CodeBlockView(language: language, code: code, streaming: streaming)
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
struct ToolCallCard: View {
    let call: ToolCall
    var onResolve: (ToolCallAction, JSONValue?) -> Void

    @State private var picked: Set<String> = []
    @State private var typed = ""

    private var prompt: AskUserPrompt? { AskUserPrompt(arguments: call.arguments) }

    /// Used when the arguments did not parse into a recognisable question.
    private var questionFallback: String {
        call.arguments.flatMap { $0["question"] }?.stringValue
            ?? "The model is asking a question."
    }

    var body: some View {
        Group {
            if call.isAwaitingUser { waiting } else { settled }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    @ViewBuilder private var waiting: some View {
        if call.isAskUser, let prompt {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(prompt.questions) { question in
                    Text(question.text).font(.body)
                    ForEach(question.options) { option in
                        Button {
                            toggle(option.label, multi: question.multiSelect)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(
                                    systemName: picked.contains(option.label)
                                        ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                        : (question.multiSelect ? "square" : "circle"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if let detail = option.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if prompt.questions.allSatisfy({ $0.options.isEmpty }) || !typed.isEmpty {
                    TextField("Type an answer", text: $typed, axis: .vertical)
                        .textFieldStyle(.plain)
                }
                HStack {
                    Button("Send") { send(prompt) }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked.isEmpty && typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Skip") { onResolve(.reject, nil) }
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            }
        } else if call.isAskUser {
            // The schema was not recognised. Showing the raw question beats
            // showing nothing: the user can still answer by typing.
            VStack(alignment: .leading, spacing: 8) {
                Text(questionFallback)
                TextField("Type an answer", text: $typed, axis: .vertical).textFieldStyle(.plain)
                Button("Send") { onResolve(.answer, .object(["answer": .string(typed)])) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.isEmpty)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Run \(call.name)?", systemImage: "wrench.and.screwdriver")
                    .font(.body.weight(.medium))
                if let arguments = call.arguments?.jsonText {
                    Text(arguments)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Approve") { onResolve(.approve, nil) }
                        .buttonStyle(.borderedProminent)
                    Button("Reject", role: .destructive) { onResolve(.reject, nil) }
                }
            }
        }
    }

    @ViewBuilder private var settled: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(call.status == .rejected || call.status == .failed ? .red : .secondary)
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch call.status {
        case .rejected: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        default: "circle"
        }
    }

    private var summary: String {
        if call.isAskUser {
            if call.status == .rejected { return "Skipped" }
            let answer = call.resultText ?? "Answered"
            return answer.count > 120 ? String(answer.prefix(120)) + "…" : answer
        }
        return call.status == .rejected ? "\(call.name) rejected" : call.name
    }

    private func toggle(_ label: String, multi: Bool) {
        if multi {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
            typed = ""
        }
    }

    private func send(_ prompt: AskUserPrompt) {
        var selections: [String: [String]] = [:]
        for question in prompt.questions {
            if !picked.isEmpty { selections[question.text] = Array(picked) }
            else { selections[question.text] = [typed] }
        }
        onResolve(.answer, prompt.answers(for: selections))
    }
}
