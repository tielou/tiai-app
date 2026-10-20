import Foundation
import Testing
@testable import TiAiKit

@MainActor
@Test("defaults are stored per server, not globally")
func defaultsAreScopedToTheServer() throws {
    let store = SettingsStore.shared
    store.point(at: URL(string: "https://one.test"))
    store.defaults = AppDefaults(systemPrompt: "One", temperature: 0.2)

    store.point(at: URL(string: "https://two.test"))
    #expect(store.defaults.systemPrompt.isEmpty)
    #expect(store.defaults.temperature == nil)

    // Coming back must find what was written, or switching instances would
    // silently drop a prompt someone spent time on.
    store.point(at: URL(string: "https://one.test"))
    #expect(store.defaults.systemPrompt == "One")
    #expect(store.defaults.temperature == 0.2)

    // Clean up: these tests write to the real defaults of a throwaway host, and
    // a later run should not inherit them.
    store.defaults = AppDefaults()
}

@MainActor
@Test("an empty default is removed rather than stored as noise")
func emptyDefaultsDoNotPersist() {
    let store = SettingsStore.shared
    store.point(at: URL(string: "https://three.test"))
    store.defaults = AppDefaults(systemPrompt: "   ", temperature: nil)
    store.point(at: URL(string: "https://three.test"))
    #expect(store.defaults.isEmpty)
}
