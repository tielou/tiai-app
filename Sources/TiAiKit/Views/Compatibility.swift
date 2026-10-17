import SwiftUI

/// The handful of modifiers that exist on one platform only.
///
/// The kit compiles for macOS as well as iOS so it can be built and tested
/// without Xcode (and so a Mac build stays one target away); these are the
/// places where iOS genuinely has a better answer — a URL keyboard, an inline
/// nav bar — and macOS simply does not. Everything else stays unguarded on
/// purpose: if a modifier is available on both, use it on both.
extension View {
    /// An opaque background that follows the appearance on both platforms.
    ///
    /// Needed by the chat drawer, which floats over the conversation and must not
    /// let it show through. `.background` and `.regularMaterial` are both
    /// translucent, which looked like a rendering fault rather than a panel.
    func opaqueBackground() -> some View {
        #if os(iOS)
        background(Color(uiColor: .systemBackground))
        #else
        background(Color(nsColor: .windowBackgroundColor))
        #endif
    }

    /// A cover that fills the screen. iOS only, so the kit still builds on macOS.
    func fullScreenCoverIOS<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        self
        #endif
    }

    /// A background one step off the page colour, for cards sitting on a chat.
    var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

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
        // `.plain`, not `.insetGrouped`. The chat list lives in a drawer that is
        // already a floating panel; putting a second rounded card inside it made
        // the panel look like a rendering artefact rather than a menu, and the
        // inset left a dead band down the right edge.
        #if os(iOS)
        listStyle(.plain)
        #else
        listStyle(.inset)
        #endif
    }
}
