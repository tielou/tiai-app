import SwiftUI

/// The handful of modifiers that exist on one platform only.
///
/// The kit compiles for macOS as well as iOS so it can be built and tested
/// without Xcode (and so a Mac build stays one target away); these are the
/// places where iOS genuinely has a better answer — a URL keyboard, an inline
/// nav bar — and macOS simply does not. Everything else stays unguarded on
/// purpose: if a modifier is available on both, use it on both.
extension View {
    func inlineTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        navigationTitle(title)
        #endif
    }

    /// A field taking a URL: no autocapitalisation, and the keyboard with the
    /// slash and the dot on it.
    func urlInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        self
        #endif
    }

    /// An email field: no autocapitalisation, no autocorrect, no capitalised
    /// first letter. Getting this wrong is how someone's address becomes
    /// "Thilo@Example.Co" in a text field.
    func emailInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func chatListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}
