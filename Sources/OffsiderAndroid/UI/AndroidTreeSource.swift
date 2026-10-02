import Foundation

/// `OFFSIDER_ANDROID_TREE`: how Android reads the screen.
enum AndroidTreeMode: String, Sendable {
    /// The helper, falling back to uiautomator with one warning when it cannot run.
    case auto
    /// The helper only; an unavailable helper is an error.
    case helper
    /// uiautomator only; the helper never starts.
    case uiautomator

    static let variable = "OFFSIDER_ANDROID_TREE"

    /// Unset or empty is auto.
    static func mode(host: AndroidHost) throws -> AndroidTreeMode {
        guard let value = host.variable(variable) else { return .auto }
        guard let mode = AndroidTreeMode(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: variable, value: value, expected: "auto, helper or uiautomator")
        }
        return mode
    }
}

/// Where one command reads one emulator's screen; chosen on its first tree read and kept, so every read compares alike.
enum AndroidTreeSource {
    case helper(HelperSession)
    case uiautomator(HelperUnavailableReason)

    static func fallbackWarning(serial: String, reason: HelperUnavailableReason) -> String {
        "The UiAutomation helper is unavailable on \(serial) (\(reason)). Reading the screen with uiautomator instead, which takes about 2 s per read."
    }

    static func truncationWarning(serial: String) -> String {
        "The screen on \(serial) has more than 20,000 accessibility nodes; describe-ui shows the first 20,000."
    }
}
