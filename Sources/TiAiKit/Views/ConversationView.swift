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
    /// How far past the end of the content the reader has dragged, as a negative
    /// number. Zero whenever there is still content below the fold.
    @State private var overscroll: CGFloat = 0
    /// True while a finger is on the scroll view.
    @State private var interacting = false
    /// Height of the transcript's container, watched so a keyboard coming or
    /// going can be reacted to.
    @State private var containerHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Tools offered by the instance — MCP servers and workspace tools. Loaded
    /// lazily and the section hidden if there are none, so an instance with no
    /// tools simply has no Tools row.
    @State private var chatTools: [ChatTool] = []
    @State private var chatToolsError: String?

    /// Cache keys are per server, so two instances on one phone never trade data.
    private var host: String { session.client.server.baseURL.host ?? "local" }
    /// A tool waiting on a sign-in. The browser lives here because the tool list
    /// does, and the list has to be read again the moment the browser closes.
    @State private var authorizing: AuthorizeRequest?
    /// What to run when the sign-in browser closes, set when it opens. The tool
    /// that asked to be signed into is the one that should end up selected, and
    /// the composer is the only place that knows which one it was.
    @State private var authFinished: ((Bool) -> Void)?

    struct AuthorizeRequest: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
    }
    /// Kept for the composer and the model sheet: the conversation only needs the
    /// id to seed itself, but the UI needs the whole record to show what each
    /// model can do. Dropping this is how the model sheet renders empty.
    @State private var models: [ChatModel]

    /// Starts another chat. Set when this view is the app's home rather than a
    /// pushed screen; the alternative was opening the chat list and finding the
    /// compose button in there, which is three taps to do the most common thing.
    var onNewChat: (() -> Void)? = nil

    public init(
        session: SessionStore, chatID: String?, title: String = "New Chat",
        models: [ChatModel] = [], onNewChat: (() -> Void)? = nil
    ) {
        self.session = session
        self.onNewChat = onNewChat
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
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    // The one retry that can be offered honestly: the last
                    // question is known, and re-running it is the same operation
                    // the toolbar's regenerate already does. Not offered while
                    // busy, because a second run would collide with the first.
                    if !conversation.phase.isBusy,
                        conversation.turns.contains(where: \.isUser) {
                        Button("Retry") { conversation.regenerate() }
                            .font(.footnote)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
            }
            ComposerView(
                conversation: conversation, models: models,
                chatTools: chatTools, chatToolsError: chatToolsError,
                onAuthorize: { url, done in
                    authFinished = done
                    authorizing = AuthorizeRequest(url: url)
                })
        }
        // A chat that is not being saved has to say so where you are looking,
        // not only in a sheet you set once at the start and never opened again.
        .inlineTitle(conversation.incognito ? "Incognito" : conversation.title)
        #if os(iOS)
        .sheet(item: $authorizing) { request in
            OAuthWebView(
                url: request.url, token: conversation.authToken,
                domain: conversation.serverHost
            ) { completed in
                // The point of signing in is that the row stops saying "not
                // signed in", so the list is read again immediately rather than
                // waiting for a foreground change that may never come.
                Task {
                    chatTools = (try? await session.client.chatTools()) ?? chatTools
                }
                authFinished?(completed)
                authFinished = nil
            }
        }
        #endif
        .toolbar { toolbar }
        .task {
            await conversation.connect()
            // Cached tools and models appear immediately; the network corrects
            // them a beat later. A chat with no model to name cannot send.
            if models.isEmpty,
               let cached = DiskCache.load([ChatModel].self, key: DiskCache.key("models", host: host)) {
                models = cached
            }
            if let cached = DiskCache.load([ChatTool].self, key: DiskCache.key("tools", host: host)) {
                chatTools = cached
            }
            await conversation.load()
            if models.isEmpty, let fresh = try? await session.client.models(), !fresh.isEmpty {
                models = fresh
                DiskCache.save(fresh, key: DiskCache.key("models", host: host))
            }
            conversation.setModels(models)
            do {
                let fresh = try await session.client.chatTools()
                chatTools = fresh
                DiskCache.save(fresh, key: DiskCache.key("tools", host: host))
            }
            // Kept rather than swallowed: an absent Tools section is otherwise
            // indistinguishable from an instance that has no tools, and the
            // second one is normal while the first is a bug.
            catch { chatToolsError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only act on coming back. `.inactive` is Control Centre, a pulled-down
            // notification, or a glance at the app switcher — none of which kill the
            // socket — and cancelling the run there is exactly what made the app
            // shout "the server sent nothing" about a run that was still being
            // written, leaving no option but to leave the chat and come back.
            //
            // `.background` is not handled either, on purpose. iOS may kill the
            // socket, but the server keeps writing regardless, and the run's own
            // reconciliation catches up on the record when the app returns.
            guard phase == .active else { return }
            Task {
                // The socket is gone after a background sojourn and nothing
                // else would notice until a send quietly streamed into the
                // void. Cheap when it is already up.
                await conversation.connect()
                // Coming back from a browser sign-in is the normal way this
                // changes: the tool said "not signed in", you signed in, and
                // the row should know that without a relaunch.
                if let tools = try? await session.client.chatTools() {
                    chatTools = tools
                    DiskCache.save(tools, key: DiskCache.key("tools", host: host))
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not `LazyVStack`. A lazy stack has to guess the height of rows
                // that are off-screen, and those guesses become the scroll
                // content's height. Combined with `defaultScrollAnchor(.bottom)`
                // the app lands at the bottom of a page that is mostly estimate and
                // no content — a black void, with a scrollbar saying there is a lot
                // more below, that only collapses back to reality as you scroll and
                // each row finally gets measured.
                //
                // It showed up after sending, which is exactly when the estimate is
                // worst: a new empty assistant row is appended, the app scrolls to
                // the bottom anchor, and that anchor is sitting in guessed space.
                // "Scroll up and it goes back to normal" is the tell — the same
                // tell as the void when opening a long chat. Reproduced side by side
                // by reverting this one line to `LazyVStack`.
                //
                // A transcript is tens of rows, not thousands, so laying them out
                // eagerly is the cheap side of that trade.
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.turns.isEmpty {
                        EmptyTranscript(greeting: Greeting.line(for: session.user?.name))
                    }
                    ForEach(conversation.turns) { turn in
                        MessageRow(
                            turn: turn,
                            onResolve: { call, action, answers in
                                conversation.resolve(
                                    messageID: turn.id, call: call, action: action, answers: answers)
                            },
                            onEdit: turn.isUser
                                ? { conversation.edit(messageID: turn.id, text: $0) } : nil,
                            onRate: turn.isAssistant && !turn.streaming
                                ? { conversation.rate(messageID: turn.id, rating: $0) } : nil,
                            rating: conversation.ratings[turn.id],
                            sibling: conversation.siblingPage(of: turn.id),
                            onSibling: { conversation.selectSibling(of: turn.id, direction: $0) },
                            fileLoader: { await conversation.fileData(id: $0) }
                        )
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
            // A brand new chat holds one short message. Without this the whole
            // thread can be dragged away from the top of the screen, which is
            // where the void comes from before there is enough content to fill
            // the page. Once content overflows, bouncing behaves normally.
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                // Positive: room still to scroll. Negative: dragged past the end.
                let edge = geometry.contentOffset.y + geometry.containerSize.height
                return ScrollFacts(shortfall: geometry.contentSize.height - edge)
            } action: { _, facts in
                // The old test was `shortfall < 120`, which is also true when the
                // shortfall is minus four hundred — so dragging past the end read
                // as "at the bottom" and every streamed token kept re-scrolling
                // into the empty space the finger had just revealed.
                atBottom = facts.shortfall < 120
                overscroll = min(facts.shortfall, 0)
            }
            // Two things this buys. Programmatic scrolls are suppressed while a
            // finger is down, so a token arriving mid-drag no longer fights the
            // drag. And a gesture that ends past the end of the content snaps
            // back to it, instead of leaving the reader in a black void with no
            // idea the last message is a flick above.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, new in
                containerHeight = new
            }
            // The keyboard leaving is a container that just grew by ~300 points.
            // Nothing re-anchors the transcript when that happens, so the bottom
            // of the conversation ends up sitting a keyboard-height above where
            // it can reach — which is the void, and why one scroll up made it go
            // away: the scroll forced the layout pass that should have happened
            // on its own.
            .onChange(of: containerHeight) { _, _ in
                guard atBottom, !interacting else { return }
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onScrollPhaseChange { _, phase in
                interacting = (phase == .interacting)
                guard phase == .idle, overscroll < -24 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                }
            }
            .onChange(of: conversation.turns.last?.text) { _, _ in
                guard atBottom, !interacting else { return }
                // After layout, not during it — see defaultScrollAnchor above.
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
            }
            .onChange(of: conversation.turns.count) { _, _ in
                guard !interacting else { return }
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
            .overlay(alignment: .bottom) {
                // Scrolled up to re-read something, there is no obvious way back:
                // the newest message can be a screen and a half below the fold and
                // nothing on screen says so. The dot only exists while it is true.
                if !atBottom && !conversation.turns.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                        }
                        atBottom = true
                    } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: .circle)
                        .overlay(Circle().stroke(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .accessibilityLabel("Scroll to the latest message")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.18), value: atBottom)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let onNewChat {
                Button(action: onNewChat) {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                // Already staring at an empty chat: the button would only clear a
                // draft nobody asked to lose.
                .disabled(conversation.turns.isEmpty && conversation.draft.isEmpty)
            }
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
    /// "Good afternoon, Thilo" — the user, not the model. The model is already
    /// on the composer chip; what an empty screen should answer is "who is this
    /// for", not "which engine is loaded".
    var greeting: String

    var body: some View {
        VStack(spacing: 18) {
            GreetingCat(size: 118)
            Text(greeting)
                .font(.title2.weight(.regular))
                .foregroundStyle(.primary)
        }
        // Not `containerRelativeFrame`: inside this ScrollView it filled the
        // viewport and the transcript came out blank. A generous fixed offset
        // puts the greeting where the eye lands and cannot fight the scroll view.
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
        .padding(.bottom, 60)
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
    /// Re-sends this user message with new text.
    var onEdit: ((String) -> Void)? = nil
    /// Thumbs this answer up or down.
    var onRate: ((Int) -> Void)? = nil
    var rating: Int? = nil
    /// Which sibling answer this branch is on, when there is more than one.
    var sibling: (index: Int, total: Int)? = nil
    var onSibling: ((Int) -> Void)? = nil
    /// Loads the bytes of an attached file. The file route needs the bearer
    /// token, so this cannot be an `AsyncImage` with a URL.
    var fileLoader: ((String) async -> Data?)? = nil

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
                ForEach(ToolCall.grouped(turn.calls)) { group in
                    switch group {
                    case .awaiting(let call):
                        ToolCallCard(call: call, questionIncoming: turn.questionIncoming) {
                            action, answers in
                            onResolve?(call, action, answers)
                        }
                    case .settled(let calls):
                        SettledCallsCard(calls: calls)
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
                if !turn.sources.isEmpty { sources }
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
        case let .heading(level, text):
            Text(Self.attributed(text))
                .font(level <= 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, level <= 2 ? 8 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.attributed(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .numbered(index, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.attributed(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle().frame(width: 3).foregroundStyle(.quaternary)
                Text(Self.attributed(text))
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
struct ToolCallCard: View {
    let call: ToolCall
    /// Whether the client is still expecting this question's arguments to turn
    /// up. When it is not, an unparseable question goes to the free-text box
    /// instead of a spinner with no end.
    var questionIncoming = false
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
        } else if call.isAskUser && !call.hasStructuredArguments && questionIncoming {
            // The arguments are still arriving. A question you cannot read yet
            // is not a question you can answer, and offering a text field for it
            // produced a box with an empty prompt and a Send button that could
            // not be pressed — while the real questions were one frame away.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the question…")
                    .font(.body)
                    .foregroundStyle(.secondary)
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
        SettledCallsCard(calls: [call])
    }
}

/// Settled tool calls, however many there were, in one card.
///
/// Three answered questions in three identical boxes reads like a form that is
/// still waiting to be filled in. One quiet list of what already happened reads
/// like a log, which is what it is.
private struct SettledCallsCard: View {
    let calls: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(calls) { call in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: call.settledIcon)
                        .font(.caption2)
                        .foregroundStyle(call.status == .completed ? Color.secondary : Color.red)
                    Text(call.settledSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.secondary.opacity(0.55), in: .rect(cornerRadius: 10))
    }
}

extension ToolCall {
    var settledIcon: String {
        switch status {
        case .rejected: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        default: "circle"
        }
    }

    var settledSummary: String {
        if isAskUser {
            if let failure = failureText { return failure }
            if status == .rejected { return "Skipped" }
            // "Answered" with nothing after it was a lie twice over: the call
            // may have been skipped, or the answer simply never came back, and
            // either way the tick next to it was already wrong.
            guard let answer = answerSummary else { return "No answer recorded" }
            return answer.count > 120 ? String(answer.prefix(120)) + "…" : answer
        }
        if status == .failed, let failure = failureText { return "\(name): \(failure)" }
        return status == .rejected ? "\(name) rejected" : name
    }
}

/// How a turn's tool calls are laid out: a question still waiting for an answer
/// gets a card to itself, everything already settled shares one.
enum ToolCallGroup: Identifiable {
    case awaiting(ToolCall)
    case settled([ToolCall])

    var id: String {
        switch self {
        case .awaiting(let call): "awaiting-\(call.id)"
        case .settled(let calls): "settled-" + calls.map(\.id).joined(separator: ",")
        }
    }
}

extension ToolCall {
    /// Groups consecutive settled calls, keeping an awaiting call on its own.
    ///
    /// Order is preserved, because the question and the answer it unlocked read
    /// in the order they happened.
    static func grouped(_ calls: [ToolCall]) -> [ToolCallGroup] {
        var out: [ToolCallGroup] = []
        var settled: [ToolCall] = []
        func flush() {
            if !settled.isEmpty { out.append(.settled(settled)); settled = [] }
        }
        for call in calls {
            if call.isAwaitingUser {
                flush()
                out.append(.awaiting(call))
            } else {
                settled.append(call)
            }
        }
        flush()
        return out
    }
}

/// A picture attached to a message, fetched with the app's own token.
///
/// `AsyncImage` is not an option: `/files/{id}/content` is behind the bearer
/// token, and handing it a bare URL produced a 401 and an empty gap — which is
/// how a photo attached in the web UI ended up invisible on the phone.
/// An image carried as a `data:` url inside the message itself.
struct InlineImageView: View {
    let dataURL: String
    /// Hands the decoded bytes up so the row can open the picture full screen.
    var onTap: ((Data) -> Void)? = nil

    #if os(iOS)
    @State private var image: UIImage?
    @State private var bytes: Data?
    #endif

    var body: some View {
        #if os(iOS)
        Group {
            if let image {
                // A button, not `.onTapGesture`: inside a scrollable row the bare
                // gesture loses to the scroll view and silently does nothing,
                // which is a confusing way for "tap to enlarge" to fail.
                Button {
                    if let bytes { onTap?(bytes) }
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open picture full screen")
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.4))
                    .frame(width: 160, height: 120)
            }
        }
        .onAppear { load() }
        #else
        Color.clear.frame(height: 0)
        #endif
    }

    #if os(iOS)
    private func load() {
        guard image == nil, let comma = dataURL.firstIndex(of: ",") else { return }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        if let data = Data(base64Encoded: base64) {
            bytes = data
            image = UIImage(data: data)
        }
    }
    #endif
}

struct RemoteImageView: View {
    let id: String
    let load: (String) async -> Data?
    var onTap: ((Data) -> Void)? = nil

    #if os(iOS)
    @State private var image: UIImage?
    @State private var bytes: Data?
    #endif
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        ZStack {
            if loading {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                ProgressView()
            } else if failed {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                #if os(iOS)
                if let image {
                    Button {
                        if let bytes { onTap?(bytes) }
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open picture full screen")
                }
                #endif
            }
        }
        .frame(maxWidth: 220, maxHeight: 260, alignment: .trailing)
        .task(id: id) {
            #if os(iOS)
            guard image == nil else { return }
            guard let data = await load(id), let loaded = UIImage(data: data) else {
                failed = true
                loading = false
                return
            }
            bytes = data
            image = loaded
            loading = false
            #else
            loading = false
            #endif
        }
    }
}

/// What the scroll geometry has to say about where the reader is.
///
/// A struct rather than a Bool because `onScrollGeometryChange` compares the
/// value it computed last time with the value now, and a Bool would only fire on
/// the at-bottom edge — the amount of overscroll changes constantly and the view
/// needs to see it change.
private struct ScrollFacts: Equatable {
    var shortfall: CGFloat
}

/// A picture opened from a message.
struct ZoomImage: Identifiable, Equatable {
    let id: String
    let data: Data
}

/// The picture at the size it was taken at.
///
/// Tap anywhere to put it back. Pinch to enlarge, drag to pan what the pinch
/// moved off screen, double-tap to reset. The scale is clamped rather than free:
/// past about 5x a phone photo is mush and the gesture starts fighting itself,
/// and below 1x the image floats away from the edges of the screen for no
/// reason.
struct FullScreenImageView: View {
    let data: Data
    var onClose: () -> Void

    #if os(iOS)
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .offset(x: offset.width + gestureOffset.width,
                            y: offset.height + gestureOffset.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { gestureScale = $0 }
                            .onEnded { _ in
                                scale = min(max(scale * gestureScale, 1), 5)
                                gestureScale = 1
                                if scale == 1 { offset = .zero }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { gestureOffset = $0.translation }
                            .onEnded { _ in
                                guard scale > 1 else { gestureOffset = .zero; return }
                                offset.width += gestureOffset.width
                                offset.height += gestureOffset.height
                                gestureOffset = .zero
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.25)) {
                            scale = 1
                            offset = .zero
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85), .black.opacity(0.35))
                            .padding(20)
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onAppear { image = UIImage(data: data) }
        #else
        Color.black.ignoresSafeArea().onTapGesture { onClose() }
        #endif
    }
}

extension View {
    /// Full screen on iOS, a sheet on macOS.
    ///
    /// `fullScreenCover` does not exist on macOS, and the kit has to build there
    /// or `swift build` and the test suite stop working — the iOS-only code has
    /// to be stepped around rather than removed.
    @ViewBuilder
    func zoomCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { content($0) }
        #else
        sheet(item: item) { content($0) }
        #endif
    }
}
