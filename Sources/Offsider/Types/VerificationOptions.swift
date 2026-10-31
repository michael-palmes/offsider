import ArgumentParser
import Foundation
import OffsiderCore

struct VerificationOptions: ParsableArguments {
    static let allowedTimeout = 0.5...30.0
    static let defaultTimeout = 2.0
    /// `--verify-id` waits for a screen to arrive, which takes longer than a control's change.
    static let defaultAppearingTimeout = 10.0

    @Flag(name: .customLong("verify"), help: "Check for an observable change after the input; exit 5 if there is none.")
    var verifyFlag = false

    @Option(name: .customLong("verify-id"), help: ArgumentHelp("Verify that this describe-ui id comes to the front after the input (implies --verify; default --retries 0 and --verify-timeout 10). Refused when it is already in front; one beneath a pushed page counts once that page goes.", valueName: "id"))
    var verifyID: String?

    @Flag(name: .customLong("verify-ignore-text"), help: "Verify, ignoring text and frame changes: only added or removed elements, roles, and enabled, checked, selected or focused states count (implies --verify).")
    var ignoreText = false

    /// Whether this command verifies, by any of the three flags.
    var verify: Bool { verifyFlag || verifyID != nil || ignoreText }

    /// What counts as the input's effect.
    var mode: Verifier.Mode {
        if let verifyID { return .appearing(id: verifyID) }
        return .change(ignoringText: ignoreText)
    }

    @Option(name: .customLong("verify-timeout"), help: "Seconds to wait for a change per attempt (default: 2).")
    var verifyTimeout: Double?

    @Option(name: .customLong("retries"), help: "Extra attempts when nothing changes, 0 to 3 (default: 1, or 0 for a tap on a switch, checkbox or radio button, for type without --replace and for button app-switch). Tap retries switch the tap style. None is sent while the screen is still changing.")
    var retries: Int?

    @Flag(name: .customLong("json"), help: "Print one JSON result to stdout; human text goes to stderr. With --verify, the verify report.")
    var json = false

    func validate() throws {
        if !verify, verifyTimeout != nil || retries != nil {
            throw ValidationError("--verify-timeout and --retries require --verify.")
        }
        if verifyID != nil && ignoreText {
            throw ValidationError("Use only one of --verify-id or --verify-ignore-text.")
        }
        if let verifyID, verifyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--verify-id must not be empty.")
        }
        if let verifyTimeout, !(verifyTimeout.isFinite && Self.allowedTimeout.contains(verifyTimeout)) {
            throw ValidationError("--verify-timeout must be between 0.5 and 30 seconds.")
        }
        if let retries, !RetryPolicy.allowedRetries.contains(retries) {
            throw ValidationError("--retries must be between 0 and 3.")
        }
    }

    var isRequested: Bool {
        verify || verifyTimeout != nil || retries != nil
    }

    var resolvedTimeout: Double { verifyTimeout ?? (verifyID != nil ? Self.defaultAppearingTimeout : Self.defaultTimeout) }
    var resolvedRetries: Int { retries ?? (verifyID != nil ? 0 : RetryPolicy.defaultRetries) }

    /// No default retry for a switch, checkbox or radio button: one that changes late would be flipped back by a second tap.
    func resolvedRetries(target: UINode?) -> Int {
        retries ?? (Self.retriesUndo(target) ? 0 : resolvedRetries)
    }

    /// No default retry for `type`: added text that lands late would be sent twice, a secret from `--stdin` too. `--replace` ends the same however often it runs.
    func resolvedRetries(replacing: Bool) -> Int {
        retries ?? (replacing ? resolvedRetries : 0)
    }

    static func retriesUndo(_ target: UINode?) -> Bool {
        target.map { Verifier.stateRoles.contains($0.role) } ?? false
    }
}

protocol VerifiableCommand {
    var verification: VerificationOptions { get }
}
