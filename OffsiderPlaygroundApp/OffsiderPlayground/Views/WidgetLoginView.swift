import SwiftUI

/// A native sign-in form with a small web view at the screen's vertical centre, as a person check widget sits in some forms.
struct WidgetLoginView: View {
    /// What a tick on the widget's box leads to.
    enum Mode: String {
        /// Passes and stays passed.
        case pass
        /// Passes, then goes back to an unticked box once `passLifetime` is over.
        case expiry
        /// Says the check failed.
        case error
        /// Checks by itself first, then asks for a tick once `checkingTime` is over.
        case late
        /// Ticks itself `tickDelay` after the screen opens, as a person would while a command waits and holds the device.
        case ticked
    }

    var mode = Mode.pass

    /// How long an `expiry` pass lasts, in seconds.
    static let passLifetime = 5
    /// How long a `late` widget checks by itself before it shows its box, in seconds.
    static let checkingTime = 4
    /// How long a `ticked` widget shows its box before it ticks itself, in seconds.
    static let tickDelay = 6

    @State private var email = ""
    @State private var password = ""
    @State private var result = "Waiting"
    @State private var signedIn = false

    var body: some View {
        GeometryReader { proxy in
            let middle = proxy.size.height / 2
            let width = proxy.size.width - 32
            ZStack {
                if signedIn {
                    Button("Sign out") {
                        signedIn = false
                        result = "Waiting"
                        email = ""
                        password = ""
                    }
                    .accessibilityIdentifier("widget-login-sign-out")
                    .position(x: proxy.size.width / 2, y: middle + 72)
                } else {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("widget-login-email")
                        .frame(width: width)
                        .position(x: proxy.size.width / 2, y: middle - 120)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("widget-login-password")
                        .frame(width: width)
                        .position(x: proxy.size.width / 2, y: middle - 72)
                    LocalWebView(html: Self.widget(mode))
                        .accessibilityIdentifier("turnstile-widget")
                        .frame(width: width, height: 64)
                        .position(x: proxy.size.width / 2, y: middle)
                    Button("Log in", action: submit)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("widget-login-submit")
                        .position(x: proxy.size.width / 2, y: middle + 72)
                }
                Text(result)
                    .accessibilityIdentifier("widget-login-result")
                    .position(x: proxy.size.width / 2, y: middle + 120)
            }
        }
        .ignoresSafeArea()
        .navigationTitle("Widget Login")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// An email that starts with `refused` is turned away with the fields kept, as a server's refusal leaves them; any other signs in and the form leaves.
    private func submit() {
        if email.isEmpty || password.isEmpty {
            result = "Missing fields"
        } else if email.lowercased().hasPrefix("refused") {
            result = "This account cannot sign in"
        } else {
            signedIn = true
            result = "Signed in"
        }
    }

    /// A person check drawn by local HTML with no network, standing in for a third-party widget: a box to tick, then its words for checking, passed or failed.
    static func widget(_ mode: Mode) -> String {
        """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>body{font:15px -apple-system,sans-serif;margin:0;padding:0 12px;border:1px solid #ccc;border-radius:8px;box-sizing:border-box;height:64px;display:flex;align-items:center}</style>
        </head><body>
        <label id="widget-prompt"><input id="widget-check-box" type="checkbox" aria-label="Verify you are human"> Verify you are human</label>
        <button id="widget-status" type="button" style="display:none;margin-left:44px;font:inherit;border:0;background:none;padding:0"></button>
        <script>
        var label = document.getElementById('widget-prompt'), box = document.getElementById('widget-check-box'), words = document.getElementById('widget-status');
        function say(text) { label.style.display = 'none'; words.style.display = 'inline'; words.textContent = text; }
        function reset() { box.checked = false; words.style.display = 'none'; label.style.display = 'inline'; }
        function tick() {
          say('Verifying...');
          setTimeout(function () {
            if ('\(mode.rawValue)' === 'error') { say('Verification failed'); return; }
            say('Success!');
            if ('\(mode.rawValue)' === 'expiry') { setTimeout(reset, \(passLifetime * 1000)); }
          }, 600);
        }
        box.addEventListener('change', tick);
        if ('\(mode.rawValue)' === 'ticked') { setTimeout(function () { box.checked = true; tick(); }, \(tickDelay * 1000)); }
        if ('\(mode.rawValue)' === 'late') { say('Verifying...'); setTimeout(reset, \(checkingTime * 1000)); }
        </script>
        </body></html>
        """
    }
}
