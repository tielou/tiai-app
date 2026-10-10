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
        self.createdAt = createdAt
    }

    public var isUser: Bool { role == "user" }
    public var isAssistant: Bool { role == "assistant" }

    /// The call the user still has to answer, if any.
    public var awaitingCall: ToolCall? { calls.first(where: \ .isAwaitingUser) }

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
        calls = message.toolCalls
        sources = message.citedSources
        createdAt = message.timestamp ?? .now
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

        for line in source.components(separatedBy: "\n") {
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
            } else { prose.append(line) }
        }
        if inFence { flushCode(terminated: false) } else { flushProse() }
        return blocks
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
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return .bullet(text: String(trimmed.dropFirst(2)))
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
