import SwiftUI
import TiAiKit

// The app target is a shell. Everything with logic in it lives in TiAiKit, so
// `swift build` and `swift test` cover the app on a machine with no simulator,
// and so the same code is one target away from a Mac build.
@main
struct TiAiApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
        }
    }
}
