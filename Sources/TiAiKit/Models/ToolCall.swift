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

    init?(_ value: JSONValue) {
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
        public var label: String
        public var detail: String?
        public var id: String { label }
    }

    public struct Question: Equatable, Sendable, Identifiable {
        public var text: String
        public var options: [Option]
        public var multiSelect: Bool
        public var id: String { text }
    }

    public var questions: [Question]

    init?(arguments: JSONValue?) {
        guard let arguments else { return nil }
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
                if let label = option.stringValue, !label.isEmpty { return Option(label: label, detail: nil) }
                guard let label = option["label"]?.stringValue ?? option["title"]?.stringValue
                    ?? option["value"]?.stringValue else { return nil }
                return Option(
                    label: label, detail: option["description"]?.stringValue ?? option["detail"]?.stringValue)
            }
            return Question(
                text: text,
                options: options,
                multiSelect: object["multi_select"]?.boolValue ?? object["multiSelect"]?.boolValue ?? false)
        }
        guard !parsed.isEmpty else { return nil }
        questions = parsed
    }

    /// What to send back.
    ///
    /// The server wraps this verbatim as `{"status": "answered", "answers": …}`
    /// and hands it to the tool, so the shape is whatever *that* tool expects —
    /// it is not fixed by the HTTP contract. Keyed by question text, which is
    /// both readable in the stored transcript and the convention the tool has
    /// used. Confirmed against a live call, not guessed at.
    public func answers(for selections: [String: [String]]) -> JSONValue {
        var dictionary: [String: JSONValue] = [:]
        for (question, values) in selections {
            dictionary[question] = values.count == 1 ? .string(values[0]) : .array(values.map { .string($0) })
        }
        return .object(dictionary)
    }
}
