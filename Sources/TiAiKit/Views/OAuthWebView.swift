#if os(iOS)
import SwiftUI
import WebKit

/// An in-app browser for an MCP server's OAuth sign-in.
///
/// Handing the flow to Safari works only if the user already happens to be
/// logged into Open WebUI there. The authorize page reads the session from a
/// `token` cookie — `auth.py`: `request.cookies.get('token')` — and a phone's
/// Safari usually has none, so the redirect lands on "not authorized" with
/// nothing on the page to explain why.
///
/// So the request is made here, with the app's own bearer token presented as
/// that cookie. It is the same session the app already holds, not a new
/// credential, and the app never sees the identity provider's password. The
/// default website data store persists, so a sign-in at the provider is not
/// repeated on every attempt.
struct OAuthWebView: View {
    let url: URL
    let token: String
    let domain: String
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionBrowser(url: url, token: token, domain: domain) {
                onFinished()
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Some providers end on a page that is not the callback —
                    // a consent screen, a "you may close this window". Without a
                    // way out the sheet would be a trap.
                    Button("Done") { onFinished(); dismiss() }
                }
            }
        }
    }
}

private struct SessionBrowser: UIViewControllerRepresentable {
    let url: URL
    let token: String
    let domain: String
    var onCallback: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    func makeUIViewController(context: Context) -> WebController {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        let controller = WebController(web: web)
        let cookie = HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: "token",
            .value: token,
            .secure: "TRUE",
            // Long enough to outlive the dance; the server's own expiry is what
            // actually governs it.
            .expires: Date().addingTimeInterval(86_400),
        ])
        guard let cookie else {
            web.load(URLRequest(url: url))
            return controller
        }
        // The cookie has to be in the store before the request goes out, so the
        // load waits for the insert rather than racing it.
        web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            DispatchQueue.main.async { web.load(URLRequest(url: url)) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: WebController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: WebController, coordinator: Coordinator) {
        uiViewController.web.stopLoading()
    }

    /// A `WKWebView` is a view, not a view controller, so it needs a host.
    final class WebController: UIViewController {
        let web: WKWebView
        init(web: WKWebView) {
            self.web = web
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            web.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(web)
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: view.topAnchor),
                web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCallback: () -> Void
        init(onCallback: @escaping () -> Void) { self.onCallback = onCallback }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Allowed to complete first: the callback request is what makes the
            // server exchange the code for a token. Cancelling the navigation to
            // close earlier would end the dance one step short of it working.
            if webView.url?.path.contains("/callback") == true { onCallback() }
        }
    }
}
#endif
