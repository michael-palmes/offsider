import SwiftUI
import WebKit

/// A sign-in form inside a WKWebView, from local HTML with no network, so `login` can be checked against web content.
struct WebLoginView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Web Login")
                .font(.headline)
                .accessibilityIdentifier("web-login-title")
            LocalWebView(html: Self.page)
                .accessibilityIdentifier("web-login-view")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .navigationTitle("Web Login")
    }

    /// Every id doubles as the element's accessibility label, so the tree names each field on iOS and Android.
    static let page = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
    <style>body{font:17px -apple-system,sans-serif;margin:16px}input,button{display:block;width:100%;font-size:17px;margin:8px 0;padding:10px;box-sizing:border-box}</style>
    </head><body>
    <form id="web-login-form" onsubmit="document.getElementById('web-login-result').textContent='Submitted';return false;">
    <label for="web-email-field">Email</label>
    <input id="web-email-field" aria-label="Email" type="email" autocomplete="off">
    <label for="web-password-field">Password</label>
    <input id="web-password-field" aria-label="Password" type="password" autocomplete="off">
    <button id="web-login-button" type="submit">Log in</button>
    </form>
    <p id="web-login-result" aria-live="polite"></p>
    </body></html>
    """
}

/// Loads `html` with no base URL and blocks every navigation, so the page never reaches the network.
struct LocalWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
