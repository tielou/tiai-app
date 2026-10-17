import Foundation

/// One bubble in the transcript.
///
/// `id` is the server's message id when there is one — including the id the app
/// minted before sending, which the server then stores verbatim. That identity
/// is what makes regenerate and edit possible without a reload: the app already
/// knows which node in the chat's message tree it is talking about.
/// A source a reply cites.
///
/// The server already sends these and the app already stored them; they were
/// simply never shown, so a web-search answer arrived with a `[1]` in the text
/// and nothing to click.
public struct MessageSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: String?
}

public struct Turn: Identifiable, Equatable, Sendable {
    public let id: String
    public var role: String
    public var text: String
    /// Thinking, kept apart from the answer because it is rendered in a
    /// disclosure and is not part of what was said. It also arrives first, so
    /// merging the two would make "first token" meaningless.
    public var reasoning: String
    public var streaming: Bool
    public var error: String?
    public var model: String?
    public var usage: TokenUsage?
    /// Tool calls and `ask_user` questions attached to this message. A turn with
    /// one that is still awaiting the user is a run that is parked, not a run
    /// that finished, and the UI has to say so.
    public var calls: [ToolCall]
    /// What the answer cites, in the order the server listed them.
    public var sources: [MessageSource]
    /// Files the user attached. Images are drawn inline; anything else is a chip.
    public var attachments: [MessageAttachment]
    /// Files the model produced in its terminal sandbox and offered with
    /// `display_file`. Fetched by path, not by file id — see `TerminalFile`.
    public var terminalFiles: [TerminalFile] = []
    public var createdAt: Date

    public init(
        id: String,
        role: String,
        text: String = "",
        reasoning: String = "",
        streaming: Bool = false,
        error: String? = nil,
        model: String? = nil,
        usage: TokenUsage? = nil,
        calls: [ToolCall] = [],
        sources: [MessageSource] = [],
        attachments: [MessageAttachment] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.streaming = streaming
        self.error = error
        self.model = model
        self.usage = usage
        self.calls = calls
        self.sources = sources
        self.attachments = attachments
        self.createdAt = createdAt
    }

    public var isUser: Bool { role == "user" }
    public var isAssistant: Bool { role == "assistant" }

    /// The call the user still has to answer, if any.
    public var awaitingCall: ToolCall? { calls.first(where: \ .isAwaitingUser) }

    /// True while the client is still waiting for a parked question's arguments
    /// to arrive. The view shows a spinner only for as long as this is set, so
    /// the wait has an end and a stuck question falls through to the free-text
    /// box rather than spinning at the user forever.
    public var questionIncoming = false

    /// Nothing to show yet, but something is happening.
    public var isWaitingForFirstToken: Bool {
        isAssistant && streaming && text.isEmpty && error == nil
    }

    /// A tool call is open, so the turn is not over however many finish frames
    /// arrive. The answer the user actually wants comes after the tool returns.
    public var awaitsTool: Bool { calls.contains { !$0.isSettled } }

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        text = message.content.text
        reasoning = ""
        streaming = false
        error = message.error
        model = message.model
        usage = message.usage
        calls = Turn.reconciling(message.toolCalls, done: message.done)
        sources = message.citedSources
        attachments = message.messageAttachments
        terminalFiles = message.terminalFiles
        createdAt = message.timestamp ?? .now
    }

    /// A finished message is not waiting on anyone.
    ///
    /// A stored message can keep a `function_call` item in `pending` after the
    /// run has moved past it — the server appends the output rather than
    /// rewriting the call, and when the two do not fold together the leftover
    /// reads as a question still on screen. The result was a card that said "The
    /// model is asking a question" with no question, an empty field and a Send
    /// button that could not be pressed: a dead end the user cannot leave, on a
    /// message that had already finished and printed its answer underneath.
    ///
    /// `done` is the authority. If the message is finished, nothing is parked.
    static func reconciling(_ calls: [ToolCall], done: Bool) -> [ToolCall] {
        guard done else { return calls }
        return calls.map { call in
            guard call.isAwaitingUser else { return call }
            var settled = call
            settled.status = call.failureText == nil ? .completed : .failed
            return settled
        }
    }
}

/// A slice of an answer that renders as one unit.
///
/// SwiftUI's `Text(.init(markdown:))` handles inline markdown — emphasis, links,
/// inline code — but not fenced blocks, tables or lists, and a chat answer is
/// mostly fenced blocks. So the split happens here: prose goes to AttributedString,
/// code goes to a monospace block with a copy button.
///
/// The parser is deliberately small and total: it never fails and never drops
/// input, because it runs on text that is still arriving. An unterminated fence
/// is treated as code, which is what you want mid-stream — a block appears as
/// code the moment the opening fence lands and stays code until the closing one
/// does, rather than flickering between prose and code as tokens arrive.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(index: Int, text: String)
    case quote(text: String)
    case code(language: String?, code: String)
    /// `---`, `***`, `___` alone on a line.
    case rule
    /// A `- [ ]` / `- [x]` row.
    case task(done: Bool, text: String)
    /// A pipe table, cells already split. Apple's inline parser has no tables at
    /// all, and a table left as prose keeps its pipes and reads like a broken
    /// sentence on every line — so the shape is kept and drawn as a grid.
    case table(headers: [String], rows: [[String]])
}

public enum Markdown {
    /// True when the text ends inside an unterminated fence. The renderer shows a
    /// caret in that case, so the block reads as "still being written" rather
    /// than "finished, and empty".
    public static func hasOpenFence(_ source: String) -> Bool {
        var open = false
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { open.toggle() }
        }
        return open
    }

    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            prose = []
        }

        func flushCode(terminated: Bool) {
            let body = code.joined(separator: "\n")
            // An empty fence while streaming is a block the model has only just
            // opened; showing it is better than showing nothing.
            if terminated || !body.isEmpty || language != nil {
                blocks.append(.code(language: language, code: body))
            }
            code = []
        }

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            // A table swallows the lines it spans, so it is recognised here
            // rather than in `classify`, which only ever sees one line.
            if let table = Self.table(startingAt: index, in: lines) {
                flushProse()
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }
            // Advanced once, here, so no branch below can forget it and spin. The
            // table branch above sets it itself, to the line past the table.
            index += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    flushCode(terminated: true)
                    inFence = false
                    language = nil
                } else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces)
                        .dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inFence = true
                }
                continue
            }
            if inFence { code.append(line) }
            else if let block = classify(line) {
                flushProse()
                blocks.append(block)
            } else {
                // Collapse runs of blank lines to one. Upstream models emit
                // long flights of newlines — between tool calls, after a
                // reasoning block, sometimes just because — and rendering them
                // literally turns the message into a tall empty column that you
                // scroll through and mistake for the end of the chat. The web
                // renderer has the same habit, which is why it happens there
                // too. Markdown itself treats any run of blank lines as a single
                // paragraph break, so this is conformance rather than a fudge.
                // Inside a code fence the lines still go through untouched:
                // source code keeps its spacing.
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if blank, prose.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true {
                    continue
                }
                prose.append(line)
            }
        }
        if inFence { flushCode(terminated: false) } else { flushProse() }
        return blocks
    }

    /// A pipe table at `index`, and the index just past it.
    ///
    /// GFM needs a header row, a separator row of dashes, and body rows. The
    /// separator is what tells a table from a line that happens to contain a
    /// pipe, so it is required rather than assumed.
    static func table(startingAt index: Int, in lines: [String]) -> (block: MarkdownBlock, nextIndex: Int)? {
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"), index + 1 < lines.count else { return nil }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard isTableSeparator(separator) else { return nil }

        var next = index + 2
        var rows: [[String]] = []
        while next < lines.count {
            let row = lines[next].trimmingCharacters(in: .whitespaces)
            guard row.contains("|"), !row.isEmpty else { break }
            rows.append(Self.cells(row))
            next += 1
        }
        return (.table(headers: Self.cells(header), rows: rows), next)
    }

    /// `|---|:--:|---|`, `|--|--|`, with the colons that carry alignment.
    static func isTableSeparator(_ line: String) -> Bool {
        let body = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !body.isEmpty else { return false }
        return body.allSatisfy { $0 == "-" || $0 == ":" } && body.contains("-")
    }

    static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A line that starts a block of its own, or nil when it is prose.
    ///
    /// The inline-only markdown parser Apple provides cannot do headings or
    /// lists, and switching to the full parser reflows newlines — which shreds a
    /// pasted stack trace. So block structure is recognised here, one line at a
    /// time, and the inline parser still owns bold, italic and code within a line.
    /// Before this, `## Key Facts` arrived on screen as `## Key Facts`.
    public static func classify(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        // The space is required: `#hashtag` is a hashtag, not a title.
        if hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
            return .heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1)))
        }
        // `---`, `***`, `- - -` on their own line. Checked before the bullet, and
        // spaces are ignored, because `* * *` is the form models emit most often
        // and it otherwise arrived on screen as a bullet reading "* *".
        // Three minimum, and nothing but dashes, asterisks or underscores, so a
        // stray `--` in a sentence stays prose.
        let squashed = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }
        if squashed.count >= 3, squashed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
            return .rule
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let body = String(trimmed.dropFirst(2))
            // Checked before the plain bullet, which would otherwise swallow it.
            if body.hasPrefix("[ ] ") { return .task(done: false, text: String(body.dropFirst(4))) }
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                return .task(done: true, text: String(body.dropFirst(4)))
            }
            return .bullet(text: body)
        }
        if trimmed.hasPrefix("> ") { return .quote(text: String(trimmed.dropFirst(2))) }
        // `12. deal with it` — digits, a dot, a space.
        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return .numbered(
                index: Int(digits) ?? 1, text: String(trimmed.dropFirst(digits.count + 2)))
        }
        return nil
    }
}
