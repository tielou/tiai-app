import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Favicons, fetched from the sites themselves.
///
/// Deliberately not `google.com/s2/favicons`: that hands every site the model
/// cited to Google, which is a strange thing for a self-hosted assistant to do
/// on the user's behalf. A site that has no `/favicon.ico` gets its initial
/// instead, which is uglier and keeps the traffic where it belongs.
@MainActor
final class FaviconCache: ObservableObject {
    static let shared = FaviconCache()

    // Published: the fetch lands after the chip is on screen, and without
    // this the circle keeps its letter forever and only picks up the real
    // icon the next time something else redraws it.
    @Published private var images: [String: PlatformImage] = [:]
    private var inflight: Set<String> = []

    func image(for host: String) -> PlatformImage? { images[host] }

    func load(_ host: String) {
        guard images[host] == nil, !inflight.contains(host) else { return }
        inflight.insert(host)
        Task {
            defer { inflight.remove(host) }
            guard let image = await Self.fetch(host) else { return }
            images[host] = image
        }
    }

    /// Where a site's icon actually lives.
    ///
    /// `/favicon.ico` is the guess everyone makes and, on modern sites, usually
    /// the wrong one: they ship `/favicon.png`, or an SVG referenced from a
    /// `<link rel="icon">` in the head. So the guess is tried, and on a miss the
    /// home page is read for the link tag. Two requests for a site that hides
    /// its icon, one for a site that does not.
    private static func fetch(_ host: String) async -> PlatformImage? {
        if let image = await image(at: "https://\(host)/favicon.ico") { return image }
        guard let html = await text(at: "https://\(host)/") else { return nil }
        for url in iconLinks(in: html, base: "https://\(host)") {
            if let image = await image(at: url) { return image }
        }
        return nil
    }

    /// `href` of every `rel="icon"`-ish link tag, resolved against the site.
    nonisolated static func iconLinks(in html: String, base: String) -> [String] {
        guard let base = URL(string: base) else { return [] }
        // Bounded scan: favicons are declared in the head, and reading a whole
        // news page to find one is wasteful and slow.
        let head = String(html.prefix(64 * 1024))
        let pattern = #"<link[^>]*rel\s*=\s*["']?(?:shortcut\s+)?(?:icon|mask-icon)["']?[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(head.startIndex..., in: head)
        var found: [String] = []
        for match in regex.matches(in: head, range: range) {
            guard let tag = Range(match.range, in: head).map({ String(head[$0]) }) else { continue }
            guard let hrefRange = tag.range(of: #"href\s*=\s*["']([^"'\s]+)"#, options: .regularExpression)
            else { continue }
            var href = String(tag[hrefRange])
            if let eq = href.firstIndex(of: "=") { href = String(href[href.index(after: eq)...]) }
            href = href.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if href.hasPrefix("//") {
                href = "https:" + href
            } else if href.hasPrefix("/") {
                href = "\(base.scheme ?? "https")://\(base.host ?? "")\(href)"
            }
            if href.hasPrefix("http"), !found.contains(href) { found.append(href) }
        }
        return found
    }

    private static func image(at string: String) async -> PlatformImage? {
        guard let url = URL(string: string) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let image = PlatformImage(data: data),
              // A 1x1 tracking pixel decodes fine and is not a favicon.
              image.size.width >= 8, image.size.height >= 8
        else { return nil }
        return image
    }

    private static func text(at string: String) async -> String? {
        guard let url = URL(string: string),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One round source bubble: the site's favicon, or its initial.
struct SourceChip: View {
    let source: MessageSource
    var size: CGFloat = 22

    @ObservedObject private var cache = FaviconCache.shared
    private var host: String {
        guard let string = source.url, let url = URL(string: string) else { return source.name }
        return url.host ?? source.name
    }

    /// The initial to fall back on. `www.rbb24.de` must not become "W".
    private var initial: String {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(bare.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(.quaternary.opacity(0.7))
            if let image = cache.image(for: host) {
                #if os(iOS)
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
                #else
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
                #endif
            } else {
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
        .onAppear { cache.load(host) }
        .onChange(of: host) { _, new in cache.load(new) }
    }
}

/// The stacked bubbles, which expand into the list of what was cited.
///
/// Collapsed it is four small circles rather than a labelled disclosure: it is
/// recognisable at a glance, takes a line, and the numbering still matches the
/// `[1]` markers in the text because the order is the server's.
struct SourcesRow: View {
    let sources: [MessageSource]
    private let visible = 4

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    HStack(spacing: -6) {
                        ForEach(Array(sources.prefix(visible).enumerated()), id: \.element.id) { _, source in
                            SourceChip(source: source)
                                // The ring is what makes overlapping circles read
                                // as separate sites rather than one blob.
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        }
                    }
                    if sources.count > visible {
                        Text("+\(sources.count - visible)")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sources (\(sources.count))")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { number, source in
                        row(number: number, source: source)
                    }
                }
                .font(.footnote)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func row(number: Int, source: MessageSource) -> some View {
        HStack(alignment: .center, spacing: 8) {
            SourceChip(source: source, size: 18)
            Text("\(number + 1).")
                .foregroundStyle(.tertiary).monospacedDigit()
            Group {
                if let string = source.url, let url = URL(string: string) {
                    Link(destination: url) {
                        Text(source.name).foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(source.name).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .lineLimit(2)
        }
    }
}
