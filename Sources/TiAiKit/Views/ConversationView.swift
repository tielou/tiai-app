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
    @State private var conversation: ConversationModel
    @State private var atBottom = true
    @Environment(\.scenePhase) private var scenePhase

    public init(session: SessionStore, chatID: String?, title: String = "New Chat", models: [ChatModel] = []) {
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
            ComposerView(conversation: conversation)
        }
        .inlineTitle(conversation.title)
        .toolbar { toolbar }
        .task {
            await conversation.connect()
            await conversation.load()
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
                        MessageRow(turn: turn)
                            .id(turn.id)
                    }
                    // Reserves room so the last line is not hidden behind the
                    // composer, and gives the scroll anchor something to hit.
                    Color.clear.frame(height: 8).id(BottomAnchor.id)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let edge = geometry.contentOffset.y + geometry.containerSize.height
                return geometry.contentSize.height - edge < 120
            } action: { _, value in
                atBottom = value
            }
            .onChange(of: conversation.turns.last?.text) { _, _ in
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
            }
            .onChange(of: conversation.turns.count) { _, _ in
                atBottom = true
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
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
                ForEach(Array(Markdown.blocks(turn.text).enumerated()), id: \.offset) { _, block in
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
            Text(turn.reasoning)
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
