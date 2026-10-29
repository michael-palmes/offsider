import SwiftUI

/// A native sign-in form with a small web view at the screen's vertical centre, as a person check widget sits in some forms.
struct WidgetLoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var result = "Waiting"

    var body: some View {
        GeometryReader { proxy in
            let middle = proxy.size.height / 2
            let width = proxy.size.width - 32
            ZStack {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("widget-login-email")
                    .frame(width: width)
                    .position(x: proxy.size.width / 2, y: middle - 120)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("widget-login-password")
                    .frame(width: width)
                    .position(x: proxy.size.width / 2, y: middle - 72)
                LocalWebView(html: Self.widget)
                    .accessibilityIdentifier("widget-login-check")
                    .frame(width: width, height: 64)
                    .position(x: proxy.size.width / 2, y: middle)
                Button("Log in") { result = email.isEmpty || password.isEmpty ? "Missing fields" : "Submitted" }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("widget-login-submit")
                    .position(x: proxy.size.width / 2, y: middle + 72)
                Text(result)
                    .accessibilityIdentifier("widget-login-result")
                    .position(x: proxy.size.width / 2, y: middle + 120)
            }
        }
        .ignoresSafeArea()
        .navigationTitle("Widget Login")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A checkbox drawn by local HTML with no network, standing in for a third-party widget.
    static let widget = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:15px -apple-system,sans-serif;margin:0;padding:12px;border:1px solid #ccc;border-radius:8px;box-sizing:border-box;height:64px}</style>
    </head><body>
    <label><input id="widget-check-box" type="checkbox" aria-label="Confirm you are here"> Confirm you are here</label>
    </body></html>
    """
}
