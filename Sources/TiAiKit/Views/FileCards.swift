import SwiftUI
#if os(iOS)
import QuickLook
#endif

struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if os(iOS)
/// QuickLook, wrapped. It renders PDFs, images, plain text, iWork and Office
/// documents natively — page thumbnails, pinch-zoom, text selection and printing
/// included — which is a great deal of work not to do, and the reason the app
/// does not try to draw a document itself.
///
/// The controller does not dismiss itself when the reader is done, so the
/// coordinator forwards that to the environment dismiss, without which the only
/// way out is a swipe nobody looks for.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        // Embedded deliberately. QuickLook puts its Done button and its action
        // menu (share, save, copy, print) in a navigation bar, and it only draws
        // that bar when it is inside a navigation controller — dropped straight
        // into a SwiftUI cover it renders the document with no way out and no
        // way to share.
        let nav = UINavigationController(rootViewController: controller)
        // And a way out, because the bar it draws has no Done button of its own
        // when it arrives this way: a preview you cannot leave is a dead end.
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator,
            action: #selector(Coordinator.close))
        return nav
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url, dismiss: dismiss) }

    /// Not `@MainActor`: UIKit declares these delegate protocols as nonisolated,
    /// so conforming from main-actor code is what Swift 6 rejects. The one thing
    /// that needs the main actor is the dismiss, so that is where the hop goes.
    final class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        private let url: URL
        private let dismiss: DismissAction
        init(url: URL, dismiss: DismissAction) {
            self.url = url
            self.dismiss = dismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            // `URL` already is a `QLPreviewItem`; the file has to be a real path
            // on disk, which is why the bytes are written out before previewing.
            url as QLPreviewItem
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) { close() }

        @objc func close() {
            let dismiss = dismiss
            Task { @MainActor in dismiss() }
        }
    }
}
#endif

struct TerminalFileCard: View {
        let file: TerminalFile
        let busy: Bool
        let failed: Bool
        let open: () -> Void

        var body: some View {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(busy ? "Opening…"
                            : failed ? "Could not fetch it — is the terminal gone?"
                            : "\(file.extension.uppercased()) file · tap to preview")
                            .font(.caption)
                            .foregroundStyle(failed ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(cardBackground, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            // The tap has to be a button, not a gesture: inside a scrollable row a
            // bare `onTapGesture` loses to the scroll view and does nothing.
            .contentShape(Rectangle())
        }

        private var icon: String {
            switch file.extension {
            case "pdf": "doc.richtext"
            case "png", "jpg", "jpeg", "gif", "webp", "heic": "photo"
            case "csv", "xlsx", "json": "tablecells"
            case "zip", "gz", "tar": "doc.zipper"
            case "py", "sh", "js", "html": "chevron.left.forwardslash.chevron.right"
            default: "doc"
            }
        }
    }

/// A link the answer gave to a file it produced, made tappable in-app.
///
/// The system would happily open the URL itself — and get a 401, because those
/// routes need the app's bearer token. So the link is fetched here and handed to
/// the share sheet instead.
struct FileLinkCard: View {
    let link: FileLink
    let busy: Bool
    let failed: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(busy ? "Opening\u{2026}"
                        : failed ? "Could not fetch it"
                        : "Tap to preview")
                        .font(.caption)
                        .foregroundStyle(failed ? .orange : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(11)
            .background(cardBackground, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
