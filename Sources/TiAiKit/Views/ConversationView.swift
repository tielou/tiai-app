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
    /// MCP servers offered by the instance. Loaded lazily and ignored if the
    /// deployment has none, so the `+` sheet simply has no Servers section.
    @State private var toolServers: [ToolServer] = []
    @State private var toolServersError: String?
    /// Workspace tools, which are a different thing from MCP servers and go on
    /// the wire in a different field. Sonos or Notion can live in either place.
    @State private var workspaceTools: [ToolServer] = []
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
            ComposerView(
                conversation: conversation, models: models,
                toolServers: toolServers, toolServersError: toolServersError,
                workspaceTools: workspaceTools)
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
            do { toolServers = try await session.client.toolServers() }
            // Kept rather than swallowed: an absent Servers section is otherwise
            // indistinguishable from an instance that has no servers, and the
            // second one is normal while the first is a bug.
            catch { toolServersError = error.localizedDescription }
            workspaceTools = (try? await session.client.workspaceTools()) ?? []
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
                // The question and the answer the user gave come *before* the
                // answer they unlocked. That is the order it happened in, it is
                // how the Claude client reads, and it keeps the question visible
                // without scrolling past the reply to remember what was asked.
                ForEach(turn.calls) { call in
                    ToolCallCard(call: call) { action, answers in
                        onResolve?(call, action, answers)
                    }
                }
                ForEach(Array(Markdown.blocks(TextSanitizer.clean(turn.text)).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, streaming: turn.streaming)
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

    /// Selections are stored **per question**. The single shared set this used to
    /// have meant a second question's choice overwrote the first, so a two-part
    /// ask came back with one answer and the model silently got the wrong one.
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]
    @State private var index = 0

    private var prompt: AskUserPrompt? { AskUserPrompt(arguments: call.arguments) }

    private var question: AskUserPrompt.Question? {
        guard let prompt else { return nil }
        guard prompt.questions.indices.contains(index) else { return prompt.questions.first }
        return prompt.questions[index]
    }

    /// Used when the arguments did not parse into a recognisable question.
    private var questionFallback: String {
        call.arguments.flatMap { $0["question"] }?.stringValue
            ?? "The model is asking a question."
    }

    var body: some View {
        Group {
            if call.isAwaitingUser { waiting } else { settled }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
    }

    @ViewBuilder private var waiting: some View {
        if call.isAskUser, let prompt, let question {
            VStack(alignment: .leading, spacing: 14) {
                pager(prompt)
                if let header = question.header {
                    Text(header).font(.caption).foregroundStyle(.secondary)
                }
                Text(question.text).font(.title3.weight(.semibold))

                if question.options.isEmpty {
                    field(question)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { position, option in
                            if position > 0 { Divider() }
                            optionRow(option, question: question)
                        }
                        if prompt.allowsOther {
                            Divider()
                            field(question)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        advance(prompt, question)
                    } label: {
                        HStack(spacing: 5) {
                            Text(isLast(prompt) ? "Submit answers" : "Next")
                            if !isLast(prompt) { Image(systemName: "arrow.right") }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!answered(question))
                }
            }
        } else if call.isAskUser {
            // The schema was not recognised. Showing the raw question beats
            // showing nothing: the user can still answer by typing.
            VStack(alignment: .leading, spacing: 8) {
                Text(questionFallback)
                TextField("Type your answer", text: typed0, axis: .vertical).textFieldStyle(.plain)
                Button("Send") { onResolve(.answer, .object(["answer": .string(typed0.wrappedValue)])) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed0.wrappedValue.isEmpty)
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

    /// "‹ 2 of 3 ›" — the count is the point. A stack of questions with no
    /// indication of how many are left reads as one question that keeps
    /// repeating itself.
    @ViewBuilder private func pager(_ prompt: AskUserPrompt) -> some View {
        HStack(spacing: 4) {
            if prompt.questions.count > 1 {
                Button {
                    if index > 0 { index -= 1 }
                } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1) of \(prompt.questions.count)")
                    .font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    if prompt.questions.indices.contains(index + 1) { index += 1 }
                } label: { Image(systemName: "chevron.right") }
                    .disabled(!prompt.questions.indices.contains(index + 1))
            } else if let title = prompt.title {
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { onResolve(.reject, nil) } label: {
                Image(systemName: "xmark").font(.body)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Skip the question")
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    private func optionRow(_ option: AskUserPrompt.Option, question: AskUserPrompt.Question) -> some View {
        Button {
            toggle(option.value, question: question)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(option.label)
                    Spacer(minLength: 0)
                    // The model's own hint, kept as a badge rather than folded
                    // into the text: a tie-breaker the reader should notice, not
                    // more prose.
                    if option.recommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                    if picked[question.value]?.contains(option.value) == true {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                if let detail = option.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func field(_ question: AskUserPrompt.Question) -> some View {
        TextField("Type your answer…", text: typedBinding(question), axis: .vertical)
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
    }

    private var typed0: Binding<String> {
        Binding(get: { typed[""] ?? "" }, set: { typed[""] = $0 })
    }

    private func typedBinding(_ question: AskUserPrompt.Question) -> Binding<String> {
        Binding(
            get: { typed[question.value] ?? "" },
            set: { value in
                typed[question.value] = value
                // Typing your own answer replaces a tapped one; both at once is
                // an answer the tool has no way to read.
                if !value.isEmpty { picked[question.value] = [] }
            })
    }

    private func toggle(_ value: String, question: AskUserPrompt.Question) {
        var current = picked[question.value] ?? []
        if question.multiSelect {
            if current.contains(value) { current.remove(value) } else { current.insert(value) }
        } else {
            current = [value]
        }
        picked[question.value] = current
        typed[question.value] = ""
    }

    private func answered(_ question: AskUserPrompt.Question) -> Bool {
        !(picked[question.value] ?? []).isEmpty
            || !(typed[question.value] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func isLast(_ prompt: AskUserPrompt) -> Bool {
        index >= prompt.questions.count - 1
    }

    private func advance(_ prompt: AskUserPrompt, _ question: AskUserPrompt.Question) {
        guard isLast(prompt) else { index += 1; return }
        submit(prompt)
    }

    private func submit(_ prompt: AskUserPrompt) {
        // Keyed by question id, valued by option id: the tool minted both, so
        // matching on human-readable text would break the moment the model
        // rephrases a label.
        var selections: [String: [String]] = [:]
        for question in prompt.questions {
            let values = Array(picked[question.value] ?? [])
            let free = (typed[question.value] ?? "").trimmingCharacters(in: .whitespaces)
            if !values.isEmpty { selections[question.value] = values }
            else if !free.isEmpty { selections[question.value] = [free] }
        }
        onResolve(.answer, prompt.answers(for: selections))
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
            guard let answer = call.answerSummary else { return "Answered" }
            return answer.count > 120 ? String(answer.prefix(120)) + "…" : answer
        }
        return call.status == .rejected ? "\(call.name) rejected" : call.name
    }
}
