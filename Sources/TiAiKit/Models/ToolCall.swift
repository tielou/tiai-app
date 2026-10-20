import Foundation

/// What the user decided about a tool call. The server accepts exactly these
/// three strings and rejects the others per tool.
public enum ToolCallAction: String, Equatable, Sendable {
    case approve
    case reject
    case answer
}

/// One entry of an assistant message's `output` array that the app has to act
/// on: a tool the model wants to run, or a question it wants answered before it
/// continues.
///
/// The server keeps these on the message rather than in the text, and pauses the
/// run until one of them is resolved. Nothing else in the transcript changes
/// while it waits, so a client that does not look at `output` shows a half
/// finished answer and a spinner that never stops — which is what this client
/// did before this file existed.
///
/// `ask_user` is the interesting one: the model asks a question, the user picks,
/// and the same run continues. Approving or rejecting a normal tool call uses
/// the same route and the same three actions.
public struct ToolCall: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case pending
        case queued
        case requiresApproval = "requires_approval"
        case completed
        case rejected
        case failed
    }

    public var callID: String
    public var name: String
    public var status: Status
    /// The model's arguments, already parsed. The wire carries them as a JSON
    /// string inside a JSON object; parsing here once beats every view doing it.
    public var arguments: JSONValue?
    /// What the tool returned, once it has run.
    public var resultText: String?

    public var id: String { callID }
    public var isAskUser: Bool { name == "ask_user" }

    /// Whether the model asked this *after* writing its answer.
    ///
    /// The server keeps `output` in the order things happened, and a model that
    /// answers and then asks — "here is the plan, now which phone?" — puts the
    /// call after the message item. Rendering every call above the text hid that
    /// question a full screen above the answer it belonged to, which reads as the
    /// app having lost it.
    public var afterText = false

    /// Whether the arguments have arrived *complete*.
    ///
    /// A model streams tool arguments as text, so for a moment the stored
    /// `arguments` is a truncated JSON string. Parsing fails, the raw string is
    /// kept, and every attempt to read a question out of it fails too — which
    /// this client treated as "unrecognised question shape" and answered with a
    /// free-text box: "The model is asking a question." with nothing to answer,
    /// on a call that had three perfectly good questions on the way in.
    ///
    /// "Not yet" and "not recognisable" need different screens. Only one of them
    /// is a dead end.
    public var hasStructuredArguments: Bool { arguments?.objectValue != nil }

    /// Whether the run is waiting on *this* call. `ask_user` sits in `pending`
    /// while every other tool waits in `requires_approval` or `queued`, so the
    /// test has to cover both rather than guess which one a given version uses.
    public var isAwaitingUser: Bool {
        switch status {
        case .requiresApproval: return true
        case .pending, .queued: return isAskUser
        case .completed, .rejected, .failed: return false
        }
    }

    /// Whether this call has reached an end state.
    ///
    /// A `finish_reason` that arrives while a call is still open is a handoff to
    /// the tool, not the end of the turn — which is the difference between a
    /// composer that waits for the real answer and one that says "finished"
    /// while the tool is still running.
    public var isSettled: Bool {
        switch status {
        case .completed, .rejected, .failed: return true
        case .pending, .queued, .requiresApproval: return false
        }
    }

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        let type = object["type"]?.stringValue ?? ""
        guard type == "function_call" || type == "function_call_output" else { return nil }
        guard
            let callID =
                (object["call_id"]?.stringValue ?? object["id"]?.stringValue)?
                .replacingOccurrences(of: "fco_", with: "")
        else { return nil }

        self.callID = callID
        self.name = object["name"]?.stringValue ?? ""
        self.status = Status(rawValue: object["status"]?.stringValue ?? "") ?? .pending
        // `arguments` is a JSON string on the wire. Left a string, every consumer
        // would need its own parser and its own idea of what happens on failure.
        if let raw = object["arguments"]?.stringValue, let data = raw.data(using: .utf8) {
            self.arguments = try? JSONDecoder().decode(JSONValue.self, from: data)
        } else {
            self.arguments = object["arguments"]
        }
        self.resultText = Self.text(from: object["output"])
    }

    /// The tool's own failure, when it failed.
    ///
    /// A rejected `ask_user` does not arrive as an HTTP error and does not stop
    /// the run: the server validates the model's arguments, decides "Each
    /// question requires 2-3 options", and writes that back as the call's
    /// output. Reading it as a normal result rendered a green tick next to the
    /// sentence saying it had failed, which is worse than saying nothing.
    public var failureText: String? {
        guard let raw = resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("Error:") || raw.hasPrefix("error:") {
            return String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = json.objectValue
        else { return nil }
        if let message = object["error"]?.stringValue { return message }
        if object["status"]?.stringValue == "error",
           let message = object["message"]?.stringValue { return message }
        return nil
    }

    /// What the user actually chose, pulled out of the tool's own reply.
    ///
    /// The stored result is the JSON the tool was handed back —
    /// `{"status":"answered","answers":{"meal":"Pizza"}}` — and showing that
    /// verbatim, as the first builds did, puts a JSON blob where a sentence
    /// belongs. The user picked Pizza; the transcript should say Pizza.
    public var answerSummary: String? {
        // An error is not an answer, and putting the sentence under a tick is
        // how the transcript ends up claiming the user chose "Each question
        // requires 2-3 options".
        if failureText != nil { return nil }
        guard let raw = resultText else { return nil }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return raw }

        let values = (json["answers"]?.objectValue ?? [:]).values.compactMap { value -> String? in
            if let text = value.stringValue { return text }
            let list = value.arrayValue?.compactMap { $0.stringValue }
            return list?.isEmpty == false ? list!.joined(separator: ", ") : nil
        }
        return values.isEmpty ? raw : values.joined(separator: " · ")
    }

    /// Folds a message's `output` array into calls.
    ///
    /// The array holds a `function_call` and, once resolved, a separate
    /// `function_call_output` for the same `call_id`. Reading them as two calls
    /// renders the same question twice — which is what the first live answer
    /// showed, two identical "Answered" rows.
    static func calls(from items: [JSONValue]) -> [ToolCall] {
        var order: [String] = []
        var byID: [String: ToolCall] = [:]
        // Position in the run, not just membership in the list: a call that
        // arrives after the answer text belongs below it.
        var sawMessage = false
        for item in items {
            guard let type = item["type"]?.stringValue else { continue }
            if type == "message" { sawMessage = true; continue }
            guard var call = ToolCall(item) else { continue }
            call.afterText = sawMessage
            if type == "function_call_output", var existing = byID[call.callID] {
                existing.resultText = call.resultText ?? existing.resultText
                if existing.status != .rejected {
                    existing.status = existing.failureText == nil ? .completed : .failed
                }
                byID[call.callID] = existing
                continue
            }
            if byID[call.callID] == nil { order.append(call.callID) }
            byID[call.callID] = call
        }
        return order.compactMap { byID[$0] }
    }

    /// `output` on a result item is a list of `{type: input_text, text: …}`.
    private static func text(from value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        guard let items = value?.arrayValue else { return nil }
        let parts = items.compactMap { $0["text"]?.stringValue }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// The question an `ask_user` call is asking, as far as it can be understood
/// without knowing the tool's exact schema.
///
/// The schema lives in the server's `ask_user` tool definition, which is not
/// part of the API contract, and it has changed between releases. So this parses
/// the shapes that have been seen and ignores the rest rather than failing the
/// whole call: a question rendered as free text is usable, a question that
/// disappears is not.
public struct AskUserPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        /// The value that goes back to the tool. `id` when it has one, because
        /// that is what the tool will look for; the label otherwise.
        public var value: String
        public var label: String
        public var detail: String?
        /// The model's own hint. The web client shows it as a badge, and it is
        /// worth a tap when everything else is a tie.
        public var recommended: Bool
        public var id: String { value }
    }

    public struct Question: Equatable, Sendable, Identifiable {
        /// `id` from the tool, used as the answer key. Falls back to the text.
        public var value: String
        /// Small label above the question, e.g. "Meal choice".
        public var header: String?
        public var text: String
        public var options: [Option]
        public var multiSelect: Bool
        public var id: String { value }
    }

    /// Heading above the questions, e.g. "Test question".
    public var title: String?
    public var questions: [Question]
    /// Whether the tool accepts free text. The web client always shows the
    /// field; a tool that says no should not get an answer it will ignore.
    public var allowsOther: Bool

    public init?(arguments: JSONValue?) {
        guard let arguments else { return nil }
        title = arguments["title"]?.stringValue ?? arguments["header"]?.stringValue
        allowsOther = arguments["allow_other"]?.boolValue ?? true
        let raw: [JSONValue]
        if let list = arguments["questions"]?.arrayValue {
            raw = list
        } else if arguments["question"]?.stringValue != nil {
            raw = [arguments]
        } else {
            return nil
        }

        let parsed = raw.compactMap { item -> Question? in
            guard let object = item.objectValue else { return nil }
            guard let text = object["question"]?.stringValue ?? object["text"]?.stringValue,
                  !text.isEmpty
            else { return nil }
            let options = (object["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                if let label = option.stringValue, !label.isEmpty {
                    return Option(value: label, label: label, detail: nil, recommended: false)
                }
                guard let raw = option["label"]?.stringValue ?? option["title"]?.stringValue
                    ?? option["value"]?.stringValue else { return nil }
                let (label, marker) = Self.splitRecommendation(raw)
                return Option(
                    value: option["id"]?.stringValue ?? raw,
                    label: label,
                    detail: option["description"]?.stringValue ?? option["detail"]?.stringValue,
                    // A tool that says so structurally wins; otherwise the hint
                    // has to be read back out of the label.
                    recommended: option["recommended"]?.boolValue ?? marker)
            }
            return Question(
                value: object["id"]?.stringValue ?? text,
                header: object["header"]?.stringValue,
                text: text,
                options: options,
                multiSelect: object["multi_select"]?.boolValue ?? object["multiSelect"]?.boolValue ?? false)
        }
        guard !parsed.isEmpty else { return nil }
        questions = parsed
    }

    /// Pulls the model's "this one" hint out of the label.
    ///
    /// There is no `recommended` field in practice. The model writes the hint
    /// into the label itself — `"Slovenia (recommended)"` — which the web UI
    /// prints verbatim, so the hint arrives as a parenthetical in the middle of
    /// a place name. Reading it back out lets it render as a badge, and keeps
    /// the answer that goes back to the model free of it.
    ///
    /// Only a trailing marker is stripped. "Best (recommended) overall" is a
    /// label with a parenthetical in it, and cutting mid-phrase would be worse
    /// than leaving it alone.
    static func splitRecommendation(_ label: String) -> (String, Bool) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") else {
            // Also catch the em/en-dash and colon forms, which the model uses
            // when it feels like it.
            for sep in [" — recommended", " - recommended", ": recommended", " (recommended)"] {
                if let r = trimmed.range(of: sep, options: .backwards),
                   r.upperBound == trimmed.endIndex {
                    return (String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), true)
                }
            }
            return (trimmed, false)
        }
        let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard inner.lowercased() == "recommended" || inner.lowercased() == "best" else {
            return (trimmed, false)
        }
        return (String(trimmed[..<open]).trimmingCharacters(in: .whitespaces), true)
    }

    /// What to send back, keyed by question id with the option values, which is
    /// the shape the tool's own ids exist to make unambiguous.
    public func answers(for selections: [String: [String]]) -> JSONValue {
        var dictionary: [String: JSONValue] = [:]
        for (question, values) in selections {
            dictionary[question] = values.count == 1 ? .string(values[0]) : .array(values.map { .string($0) })
        }
        return .object(dictionary)
    }
}
