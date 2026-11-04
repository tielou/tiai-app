import Foundation
import Testing

@testable import TiAiKit

/// Issue #39: a transient failure on an idempotent read is retried with backoff,
/// while a 4xx (a real answer, not a blip) and a mutating POST are not. The
/// classification itself is pinned in `onlySomeFailuresAreWorthRetrying`; these
/// drive the retry *loop* end to end through a transport, with the backoff
/// ladder zeroed so the full ladder runs instantly instead of sleeping ~17 s.
struct RetryTests {
    /// A transport that fails the first `failFirst` requests, then succeeds.
    /// A `.status` failure comes back as an HTTP response (so `validate` turns
    /// it into the matching `APIError`); `.unreachable` throws at the transport,
    /// which is how a connection reset actually surfaces.
    private final class FlakyTransport: APITransport, @unchecked Sendable {
        enum Failure { case status(Int), unreachable }
        private(set) var calls = 0
        let failFirst: Int
        let failure: Failure
        init(failFirst: Int, failure: Failure) {
            self.failFirst = failFirst
            self.failure = failure
        }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            let url = request.url!
            if calls <= failFirst {
                switch failure {
                case .unreachable:
                    throw APIError.unreachable("connection reset")
                case .status(let code):
                    let r = HTTPURLResponse(url: url, statusCode: code,
                                            httpVersion: nil, headerFields: nil)!
                    return (Data("{}".utf8), r)
                }
            }
            let r = HTTPURLResponse(url: url, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[]}"#.utf8), r)
        }
        func bytes(_ request: URLRequest) async throws -> (ByteStream, HTTPURLResponse) {
            fatalError("models do not stream")
        }
    }

    private func client(_ transport: FlakyTransport) -> OWUIClient {
        var c = OWUIClient(
            server: Server(baseURL: URL(string: "https://test.invalid")!, token: "t"),
            transport: transport)
        c.retryLadder = [0, 0, 0, 0, 0]
        return c
    }

    @Test func aTransientGETFailureIsRetriedThenSucceeds() async throws {
        let t = FlakyTransport(failFirst: 2, failure: .status(503))
        let models = try await client(t).models()
        #expect(models.isEmpty)
        #expect(t.calls == 3, "two 503s then the success")
    }

    @Test func aConnectionErrorGETIsRetriedThenSucceeds() async throws {
        let t = FlakyTransport(failFirst: 1, failure: .unreachable)
        _ = try await client(t).models()
        #expect(t.calls == 2, "a dropped connection is retried like any blip")
    }

    @Test func aGETGivesUpAfterTheLadderRunsOut() async throws {
        let t = FlakyTransport(failFirst: 99, failure: .status(503))
        await #expect(throws: APIError.self) { try await client(t).models() }
        // GETs get the full six attempts (five sleeps + the first try); the
        // point of the bound is that a genuinely-down server still reports.
        #expect(t.calls == 6)
    }

    @Test func a401IsNotRetried() async throws {
        // A 401 is a real answer ("signed out"), not a blip; retrying it six
        // times would just delay the login prompt and hammer the server.
        let t = FlakyTransport(failFirst: 99, failure: .status(401))
        await #expect(throws: APIError.self) { try await client(t).models() }
        #expect(t.calls == 1)
    }
}
