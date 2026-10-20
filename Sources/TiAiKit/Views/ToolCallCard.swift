import SwiftUI

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
struct SettledCallsCard: View {
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
