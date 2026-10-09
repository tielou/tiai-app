import SwiftUI
import TiAiKit

// The app target is a shell. Everything with logic in it lives in TiAiKit, so
// `swift build` and `swift test` cover the app on a machine with no simulator,
// and so the same code is one target away from a Mac build.
@main
struct TiAiApp: App {
    @State private var session = SessionStore()
    @State private var appearance = AppearanceStore.shared

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                // `nil` for "follow the system", which is the default and the
                // right answer for almost everyone; the picker exists for the
                // person whose phone is dark at night and who still wants the
                // chat light, or who picked dark in the web UI.
                .preferredColorScheme(appearance.mode.colorScheme)
        }
    }
}
