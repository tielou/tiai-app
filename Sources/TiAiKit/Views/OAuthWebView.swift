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
                ToolbarItem(placement: .topBarLeading) {
                    // The way out when the page itself will not cooperate in a web
                    // view. Safari usually already holds an Open WebUI session, so
                    // it often skips the sign-in step entirely.
                    Button("Safari") { UIApplication.shared.open(url) }
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
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.autofillScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: .page))
        let web = WKWebView(frame: .zero, configuration: configuration)
        // The sign-in form is centred, so with the keyboard up the submit button
        // sits underneath it — and nothing scrolled, so there was no way to reach
        // it or to get rid of the keyboard.
        web.scrollView.keyboardDismissMode = .interactive
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
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

    /// iOS fills a password field without firing the events a single-page app
    /// listens for, so its "both fields are filled, enable the button" check
    /// never runs and sign-in looks unclickable after autofill. Re-broadcast the
    /// input when the field turns yellow.
    static let autofillScript = """
        (() => {
          const style = document.createElement('style')
          style.textContent = '@keyframes tiai-autofill { from { } to { } }'
            + 'input:-webkit-autofill { animation-name: tiai-autofill; '
            + 'animation-duration: 0.01s; animation-delay: 0.01s; }'
          document.head.appendChild(style)
          document.addEventListener('animationstart', event => {
            const node = event.target
            if (node && node.tagName === 'INPUT' && event.animationName === 'tiai-autofill') {
              node.dispatchEvent(new Event('input', { bubbles: true }))
              node.dispatchEvent(new Event('change', { bubbles: true }))
            }
          }, true)
        })()
        """

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
            // Pinned to the safe area, not the view: under the navigation bar the
            // top of the form was unreachable.
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCallback: () -> Void
        init(onCallback: @escaping () -> Void) { self.onCallback = onCallback }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Allowed to complete first: the callback request is what makes the
            // server exchange the code for a token. Cancelling the navigation to
            // close earlier would end the dance one step short of it working.
            if webView.url?.path.contains("/callback") == true { onCallback() }
        }

        /// Identity providers love opening their login in a new window. A
        /// `WKWebView` with no UI delegate silently drops that request, which
        /// looks exactly like a login button that does nothing — so the request
        /// is loaded in the window the user can already see.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame?.isMainFrame != true {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
#endif
