import Foundation

/// Turns a raw SSE byte stream into normalized `ChatEvent`s.
///
/// This is the only place that knows what an Open WebUI completion frame looks
/// like. Everything downstream renders events and never parses JSON, which is
/// what lets the same UI be driven by the SSE stream today, by the websocket
/// side channel later, and by a recorded fixture in tests.
public struct ChatEventStream: AsyncSequence, Sendable {
    public typealias Element = ChatEvent

    private let bytes: ByteStream

    init(bytes: ByteStream) {
        self.bytes = bytes
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(bytes.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var source: ByteStream.AsyncIterator
        private var parser = SSEParser()
        private var queued: [ChatEvent] = []
        private var finished = false

        init(_ source: ByteStream.AsyncIterator) {
            self.source = source
        }

        public mutating func next() async throws -> ChatEvent? {
            while queued.isEmpty && !finished {
                do {
                    guard let chunk = try await source.next() else {
                        finished = true
                        queued += parser.finish().flatMap { Self.events(from: $0) }
                        break
                    }
                    queued += parser.feed(chunk).flatMap { Self.events(from: $0) }
                } catch is CancellationError {
                    finished = true
                    return nil
                } catch {
                    finished = true
                    return .failed(error.localizedDescription)
                }

                // A stream that ends without `[DONE]` — connection dropped,
                // proxy restarted, pod evicted. Ending the sequence here is
                // what stops the UI sitting on a half-finished message with a
                // spinner forever; the caller sees the stream end and can mark
                // the message incomplete.
                if finished && queued.isEmpty {
                    return nil
                }
            }
            guard !queued.isEmpty else { return nil }
            let next = queued[0]
            queued.removeFirst()
            return next
        }

        /// One frame in, zero or more events out.
        static func events(from frame: SSEEvent) -> [ChatEvent] {
            let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty { return [] }
            if payload == "[DONE]" { return [.done] }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
            else {
                // Not JSON and not [DONE]. Ignore rather than fail: keep-alive
                // frames and future non-JSON additions should not end a
                // generation that is going fine.
                return []
            }

            var events: [ChatEvent] = []

            if let error = chunk.error {
                let message =
                    error.objectValue?["message"]?.stringValue
                    ?? error.stringValue
                    ?? "The model returned an error."
                return [.failed(message)]
            }

            for choice in chunk.choices ?? [] {
                let delta = choice.delta ?? choice.message
                if let reasoning = delta?.reasoning, !reasoning.isEmpty {
                    events.append(.reasoning(reasoning))
                }
                if let content = delta?.content, !content.isEmpty {
                    events.append(.delta(content))
                }
            }

            if let usage = chunk.usage { events.append(.usage(usage)) }
            if let selected = chunk.selectedModelID { events.append(.modelSelected(selected)) }
            return events
        }
    }
}

extension ChatEventStream {
    /// Reads the stream to the end and discards what it yields.
    ///
    /// This is not a no-op. When a completion carries a message id the server
    /// awaits the whole generation inside the request and answers with an empty
    /// body at the end, so the content arrives over the socket and the REST body
    /// is just a lifecycle signal: it closing means the run is over, and the
    /// errors in it are real (`401`, `429`) even though the text is not. A
    /// client that never reads it also never learns the request failed.
    public func drain() async throws {
        for try await _ in self {}
    }
}
