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
    /// Called when the browser closes. `true` means the flow came back to the
    /// Open WebUI host, i.e. it finished; `false` means the user pressed Done and
    /// may never have signed in. Selecting a tool on a bail-out would put a dead
    /// tool on the chat, which is the failure this whole path exists to avoid.
    var onFinished: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var whereAmI: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // A hand-off that goes wrong fails silently by default: the sheet
                // just sits there and the only honest description is "nothing
                // happened". Both of these turn that into something to act on.
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.orange.opacity(0.12))
                }
                SessionBrowser(
                    url: url, token: token, domain: domain,
                    onURL: { whereAmI = $0 }, onFailed: { failure = $0 }
                ) {
                    onFinished(true)
                    dismiss()
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Where the hand-off actually is. iOS 18 has no navigation
                // subtitle, and guessing from a blank page is what we are here
                // to stop doing.
                if let whereAmI, !whereAmI.isEmpty {
                    Text(whereAmI)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Some providers end on a page that is not the callback —
                    // a consent screen, a "you may close this window". Without a
                    // way out the sheet would be a trap.
                    Button("Done") { onFinished(false); dismiss() }
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
    var onURL: (String) -> Void
    var onFailed: (String) -> Void
    var onCallback: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback, host: domain, onURL: onURL, onFailed: onFailed)
    }

    func makeUIViewController(context: Context) -> WebController {
        let configuration = WKWebViewConfiguration()
        // Identity providers love opening their consent screen with window.open().
        // By default WKWebView refuses that *before* the delegate is consulted, so
        // the popup handler below never runs and the flow dies silently right
        // after a successful login - which is exactly what this looked like.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
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
        private let onURL: (String) -> Void
        private let onFailed: (String) -> Void
        /// The Open WebUI host the flow started from. Coming back here is what
        /// "finished" means.
        private let host: String
        /// Set once the dance has gone off to the identity provider.
        private var leftOrigin = false

        init(onCallback: @escaping () -> Void, host: String,
             onURL: @escaping (String) -> Void, onFailed: @escaping (String) -> Void) {
            self.onCallback = onCallback
            self.host = host
            self.onURL = onURL
            self.onFailed = onFailed
        }

        private func isMine(_ url: URL?) -> Bool {
            guard let host = url?.host else { return false }
            return host == self.host || host.hasSuffix(".\(self.host)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onURL(webView.url.map(Self.describe) ?? "")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // ATS refusals and unreachable hosts used to leave a blank sheet.
            onFailed((error as? LocalizedError)?.localizedDescription ?? error.localizedDescription)
        }

        private static func describe(_ url: URL) -> String {
            url.host.map { $0 + (url.path == "/" ? "" : url.path) } ?? url.absoluteString
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Allowed to complete first: the callback request is what makes the
            // server exchange the code for a token. Cancelling the navigation to
            // close earlier would end the dance one step short of it working.
            let url = webView.url
            guard isMine(url) else {
                leftOrigin = true
                return
            }
            // The callback handler answers with a redirect to the Open WebUI
            // root, so by the time a navigation *finishes* the url is the site
            // home, not `/callback` - watching for the callback path alone never
            // fires and the sheet just sits there showing the web app, which
            // looks exactly like a login button that did nothing.
            if url?.path.contains("/callback") == true || leftOrigin { onCallback() }
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
