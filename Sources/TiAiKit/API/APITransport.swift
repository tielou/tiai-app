import Foundation

/// The seam between the client and the network.
///
/// Tests substitute a fake here rather than a URLProtocol subclass, which
/// keeps them readable and lets them assert on the request that went out.
///
/// Two methods, because a chat completion is not a request/response call: the
/// JSON endpoints want `Data` and the streaming one wants bytes as they
/// arrive. Collapsing them into one would mean buffering a stream to make it
/// testable, which is the exact thing the app must not do.
public protocol APITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)

    /// Starts a response that will be consumed incrementally. Returns the
    /// status/header pair first so the caller can turn a 401 into a login
    /// prompt *before* it starts parsing a body that is an error page.
    func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse)
}

/// Type-erased chunk stream, so `APITransport` can be used existentially.
///
/// Elements are `Data` chunks rather than single bytes: an SSE transcript is
/// tens of kilobytes, and awaiting a handoff per byte would cost more than the
/// network did. The default transport flushes on every newline, so a chunk
/// almost always contains at least one complete frame.
public struct ByteStream: AsyncSequence, Sendable {
    public typealias Element = Data

    private let make: @Sendable () -> AsyncThrowingStream<Data, any Error>

    public init(_ make: @escaping @Sendable () -> AsyncThrowingStream<Data, any Error>) {
        self.make = make
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<Data, any Error>.Iterator {
        make().makeAsyncIterator()
    }
}

public struct URLSessionTransport: APITransport {
    private let session: URLSession

    /// A session with no cache and a long timeout.
    ///
    /// No cache: chat history is revalidated from the server on every list
    /// load, and a cached 304 buys nothing while risking a stale transcript.
    /// Long timeout: halogen's cold prefill is measured in tens of seconds at
    /// long context (30k tokens ≈ 22 s, 245k ≈ 170 s), and a stream that dies
    /// at 60 s with no explanation is the failure mode this avoids. Cancelling
    /// is the user's job — Stop exists — not the transport's.
    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unreachable("response was not HTTP")
        }
        let stream = ByteStream {
            AsyncThrowingStream { continuation in
                let task = Task {
                    var buffer = Data()
                    buffer.reserveCapacity(8192)
                    do {
                        for try await byte in bytes {
                            buffer.append(byte)
                            // Flush on a line end (the common case: one frame
                            // per chunk) or when the buffer is big enough that
                            // waiting for a newline would add latency.
                            if byte == 0x0A || buffer.count >= 8192 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return (stream, http)
    }
}
