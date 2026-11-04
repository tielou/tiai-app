import Foundation
import Network

/// "Can this phone reach anything?" — as an observable, so a chat can wake up
/// when the answer changes from no to yes (issue #38).
///
/// `NWPathMonitor` watches the interface, not the server: it says "wi-fi is
/// up", not "your home box answered". That is not a reason to skip it — the
/// case it catches is the plane landing and wifi coming back while the app sits
/// open on the chat, which no foreground change and no chat-open will ever see.
/// It is a reason to treat it as a *hint*: every consumer of this type re-checks
/// by trying, and the outbox's dedup is what stops a hint that turned out wrong
/// from becoming a duplicate message.
///
/// Consumers watch `isConnected` and act on the transition to true. The first
/// status the monitor reports is deliberately not treated as a transition:
/// every app launch would otherwise look like a reconnect, and a cue that fires
/// on launch is not a cue that fires on reconnect. The initial callback still
/// seeds the value, so a phone that launches offline reads as offline — the
/// change a view sees is `true → false`, and the replay trigger only acts on
/// the other direction.
@MainActor
@Observable
public final class Reachability {
    /// True until the monitor says otherwise. An unknown network is not a
    /// disconnected one, and the cost of guessing wrong here is one send that
    /// goes into the outbox instead of failing outright.
    public private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            // The handler runs on the monitor's own queue; `isConnected` is
            // main-actor observable state, so the write hops.
            Task { @MainActor in self?.update(connected) }
        }
        monitor.start(queue: DispatchQueue(label: "tiai.reachability", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    private func update(_ connected: Bool) {
        // Assignment to an `@Observable` property only publishes on a real
        // change under Observation, so "the monitor keeps reporting the same
        // status" cannot masquerade as a transition. The one spurious edge is
        // the initial callback disagreeing with the optimistic default above —
        // a launch that turns out to be offline — and the replay trigger acts
        // on the other direction only.
        isConnected = connected
    }
}
