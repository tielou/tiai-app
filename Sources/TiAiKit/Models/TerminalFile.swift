import Foundation

/// A file the model produced inside its terminal sandbox and offered with
/// `display_file`.
///
/// These are not uploads and not `chat.files`. The model writes a file into the
/// terminal container — `/home/user/something.pdf` — and calls `display_file`,
/// whose output is metadata only: a path, a mime type, which terminal it lives
/// in, and the chat that owns it. There is no file id and no URL anywhere in the
/// record, so nothing in the message can be fetched the way an uploaded file can.
///
/// The bytes come from a different route entirely, one the web UI reaches at
/// `{api}/terminals/{selector}/files/view?path=…` with the chat id in an
/// `X-Session-Id` header. That is why this is its own type rather than another
/// `MessageAttachment`: the id it needs is a path plus a session, not a file id.
///
/// Worth knowing: the model will happily say "I've attached the PDF" when all it
/// did was call `display_file` successfully. The card is real; the file only
/// exists if the sandbox still has it.
public struct TerminalFile: Identifiable, Equatable, Sendable {
    /// Which terminal server holds it — usually `sandbox`.
    public var selector: String
    /// Path inside that terminal, e.g. `/home/user/Berlin_Daytime_Plan.pdf`.
    public var path: String
    public var name: String
    public var mimeType: String

    public var id: String { "\(selector)|\(path)" }

    public init(selector: String, path: String, name: String, mimeType: String) {
        self.selector = selector
        self.path = path
        self.name = name
        self.mimeType = mimeType
    }

    /// The extension, for the icon and the share sheet's file name.
    public var `extension`: String {
        (name as NSString).pathExtension.lowercased()
    }
}

extension ChatMessage {
    /// Files the model offered from the terminal, in the order it offered them.
    ///
    /// A `display_file` call and its result are two separate items in `output`,
    /// joined by `call_id`. The result is a JSON string wrapped in an
    /// `input_text` part, which is why this reads like peeling an onion.
    public var terminalFiles: [TerminalFile] {
        var ordered: [(callID: String, path: String)] = []
        for item in output {
            guard item["type"]?.stringValue == "function_call",
                  item["name"]?.stringValue == "display_file" else { continue }
            let callID = (item["call_id"] ?? item["id"])?.stringValue ?? ""
            guard let path = Self.displayFilePath(item["arguments"]) else { continue }
            ordered.append((callID, path))
        }
        guard !ordered.isEmpty else { return [] }

        var results: [String: JSONValue] = [:]
        for item in output where item["type"]?.stringValue == "function_call_output" {
            guard let callID = item["call_id"]?.stringValue else { continue }
            results[callID] = item["output"]
        }

        return ordered.compactMap { callID, path in
            guard let payload = results[callID],
                  let meta = Self.displayFileOutput(payload) else { return nil }
            // `exists: false` means the model claimed a file it never wrote.
            if meta["exists"]?.boolValue == false { return nil }
            let full = (meta["full_path"] ?? meta["path"])?.stringValue ?? path
            let name = (meta["name"])?.stringValue
                ?? (full as NSString).lastPathComponent
            let mime = (meta["mime_type"] ?? meta["content_type"])?.stringValue
                ?? "application/octet-stream"
            let selector = (meta["terminal_selector"] ?? meta["terminal_id"])?.stringValue
                ?? "sandbox"
            return TerminalFile(selector: selector, path: full, name: name, mimeType: mime)
        }
    }

    /// The `path` from a `display_file` call's arguments, which arrive as a JSON
    /// string rather than an object.
    private static func displayFilePath(_ arguments: JSONValue?) -> String? {
        guard let arguments else { return nil }
        if let direct = arguments["path"]?.stringValue { return direct }
        guard let raw = arguments.stringValue,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return parsed["path"]?.stringValue
    }

    /// The metadata a successful `display_file` came back with.
    private static func displayFileOutput(_ value: JSONValue?) -> [String: JSONValue]? {
        // Either `[{type: input_text, text: "{json}"}]` or `{text: "{json}"}`.
        let parts: [JSONValue]
        if let array = value?.arrayValue { parts = array }
        else if let value { parts = [value] }
        else { return nil }

        for part in parts {
            guard let text = (part["text"] ?? part["content"])?.stringValue,
                  let data = text.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let object = parsed.objectValue
            else { continue }
            if object["path"] != nil { return object }
        }
        return nil
    }
}
