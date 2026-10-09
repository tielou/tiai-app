import Foundation

/// One frame of a Server-Sent Events stream.
public struct SSEEvent: Equatable, Sendable {
    /// The joined payload of every `data:` line in the frame.
    public var data: String
    /// The `event:` field, if the server set one. Open WebUI does not on the
    /// completion stream — it sends `data:` only — but the framing allows it
    /// and the parser must not lose it if that changes.
    public var event: String?
    public var id: String?

    public init(data: String, event: String? = nil, id: String? = nil) {
        self.data = data
        self.event = event
        self.id = id
    }
}

/// Incremental SSE framing.
///
/// Feed it whatever bytes arrive, get whole events out. It is deliberately not
/// "split the buffer on blank lines": the SSE spec (and therefore FastAPI's
/// `StreamingResponse`) says a line may end in CRLF, LF or CR, that exactly one
/// leading space after the colon is part of the framing and not the value, that
/// a line starting with `:` is a comment to ignore (keep-alives), and that
/// several `data:` lines in one frame join with a newline. Getting any of those
/// wrong produces an app that works on wifi and drops tokens on a lossy
/// connection, because that is when chunks arrive split mid-line.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastID: String?

    public init() {}

    /// Consume a chunk and return every event that became complete.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        buffer.append(contentsOf: bytes)
        var events: [SSEEvent] = []
        while let line = takeLine() {
            if let event = consume(line) { events.append(event) }
        }
        return events
    }

    /// Flush a trailing line at end of stream. A final frame with no blank line
    /// after it is legal at the transport level and would otherwise be dropped.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: false)
            if let event = consume(line) { events.append(event) }
        }
        if !dataLines.isEmpty {
            events.append(makeEvent())
        }
        return events
    }

    // MARK: - framing

    /// Extracts one complete line, honouring CRLF / LF / CR.
    ///
    /// A bare CR at the very end of the buffer is *not* treated as a line end:
    /// it may be the first half of a CRLF that is split across two network
    /// reads, and guessing wrong there corrupts the next field.
    private mutating func takeLine() -> String? {
        for index in buffer.startIndex..<buffer.endIndex {
            let byte = buffer[index]
            if byte == 0x0A {  // LF
                let line = decode(upTo: index)
                buffer.removeSubrange(buffer.startIndex...index)
                return line
            }
            if byte == 0x0D {  // CR
                let next = buffer.index(after: index)
                if next == buffer.endIndex { return nil }  // might be CRLF, wait
                let line = decode(upTo: index)
                if buffer[next] == 0x0A {
                    buffer.removeSubrange(buffer.startIndex...next)
                } else {
                    buffer.removeSubrange(buffer.startIndex...index)
                }
                return line
            }
        }
        return nil
    }

    /// The bytes before `index`, without the line terminator itself.
    private func decode(upTo index: Data.Index) -> String {
        String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
    }

    /// Feed one line. Returns an event when the line was the blank line that
    /// closes a frame.
    private mutating func consume(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            return dataLines.isEmpty ? nil : makeEvent()
        }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line  // a field with no colon is a field name with ""
            value = ""
        }

        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        case "id": lastID = value
        case "retry": break  // reconnection backoff; the client owns reconnection
        default: break  // unknown field, ignored per spec
        }
        return nil
    }

    private mutating func makeEvent() -> SSEEvent {
        defer {
            dataLines = []
            eventName = nil
        }
        return SSEEvent(data: dataLines.joined(separator: "\n"), event: eventName, id: lastID)
    }
}
