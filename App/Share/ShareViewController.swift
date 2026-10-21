import UIKit
import SwiftUI
import PhotosUI

/// The share sheet target: hand tiAi a link or some text from anywhere.
///
/// Deliberately narrow. Text and URLs travel to the app through the `tiai://`
/// scheme, which needs no shared container and no new capabilities — an App Group
/// would mean a new entitlement on every App ID and a rebuilt profile, for the
/// one case (images) that a URL cannot carry. Photos are left out of the
/// activation rule rather than half-supported, so the extension simply does not
/// appear when you share a picture, instead of appearing and failing.
///
/// The extension does not talk to the server. It hands over a composed prompt and
/// gets out of the way; the app, which has the session, does the sending. That
/// also means a share works before anyone has signed in.
public final class ShareViewController: UIViewController {
    private var payload: String = ""
    private var status = UILabel()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "Ask tiAi"

        let note = UITextView()
        note.isEditable = false
        note.font = .preferredFont(forTextStyle: .body)
        note.backgroundColor = .secondarySystemGroupedBackground
        note.layer.cornerRadius = 10
        note.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)

        status = UILabel()
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        let send = UIButton(primaryAction: UIAction(title: "Open tiAi",
                                                   attributes: []) { [weak self] _ in
            self?.handOff(note)
        })
        send.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(send)

        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            note.heightAnchor.constraint(equalToConstant: 150),
            status.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: note.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            send.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            send.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        Task { await load() }
        _ = send
    }

    /// The item the user shared, as text worth asking about.
    private func load() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        var pieces: [String] = []
        for item in items {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await attachment.loadItem(forTypeIdentifier: UTType.url.identifier)
                    as? URL {
                    pieces.append(url.absoluteString)
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await attachment.loadItem(
                            forTypeIdentifier: UTType.plainText.identifier) as? String {
                    pieces.append(text)
                }
            }
        }
        // A URL shared on its own is the common case and needs no framing: the
        // question belongs to the person, not to the extension.
        payload = pieces.joined(separator: "\n\n")
        await MainActor.run {
            (view.subviews.first { $0 is UITextView } as? UITextView)?.text = payload
            status.text = payload.isEmpty
                ? "Nothing readable was shared."
                : "Opens tiAi with this in the composer. Nothing is sent until you press send."
        }
    }

    private func handOff(_ note: UITextView) {
        let text = note.text ?? payload
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        var components = URLComponents()
        components.scheme = "tiai"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = components.url else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
        // The only supported way out of a share extension into its host app.
        extensionContext?.open(url)
    }
}
