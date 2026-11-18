import Foundation

/// The first draft `guard init` writes for the app's developer to sharpen: labels that move money (ask) or change who can get into an account (never).
public enum GuardStarter {
    static let askLabels = ["Buy now", "Sell now", "Place order", "Confirm order", "Pay now", "Transfer", "Withdraw", "Send", "Deposit", "Swap"]
    static let neverLabels = ["Change password", "Reset password", "Two-factor", "2FA", "Authenticator", "Change email", "Change phone", "API key", "Delete account", "Close account"]

    public static func config(apps: [String]) -> GuardConfig {
        let ask = askLabels.map { GuardRule(name: $0, action: .ask, control: GuardMatcher(label: $0)) }
        let never = neverLabels.map { GuardRule(name: $0, action: .never, control: GuardMatcher(labelContains: $0)) }
        return GuardConfig(apps: apps, rules: ask + never)
    }

    /// What is left for whoever knows the app, in the order to do it.
    public static let todo = [
        "Delete the rules this app has no control for.",
        "Search the app's source for each remaining label and swap it for the control's id or testID, which survives a copy change.",
        "Add a rule for every other control that moves money or assets (ask) or changes sign-in or account security (never).",
        "Scope a common label such as Confirm to its screen: \"screen\": { \"id\": \"<an id on that screen>\" }.",
        "Leave device-only settings such as Face ID out, so they stay free.",
    ]
}
