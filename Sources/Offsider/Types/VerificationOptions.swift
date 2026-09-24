import ArgumentParser
import Foundation
import OffsiderCore

struct VerificationOptions: ParsableArguments {
    static let allowedTimeout = 0.5...30.0
    static let defaultTimeout = 2.0

    @Flag(name: .customLong("verify"), help: "Check for an observable change after the input; exit 5 if there is none.")
    var verify = false

    @Option(name: .customLong("verify-timeout"), help: "Seconds to wait for a change per attempt (default: 2).")
    var verifyTimeout: Double?

    @Option(name: .customLong("retries"), help: "Extra attempts when nothing changes, 0 to 3 (default: 1). Tap retries switch the tap style.")
    var retries: Int?

    @Flag(name: .customLong("json"), help: "Print one JSON result to stdout; human text goes to stderr. Requires --verify.")
    var json = false

    func validate() throws {
        if !verify, verifyTimeout != nil || retries != nil || json {
            throw ValidationError("--verify-timeout, --retries and --json require --verify.")
        }
        if let verifyTimeout, !(verifyTimeout.isFinite && Self.allowedTimeout.contains(verifyTimeout)) {
            throw ValidationError("--verify-timeout must be between 0.5 and 30 seconds.")
        }
        if let retries, !RetryPolicy.allowedRetries.contains(retries) {
            throw ValidationError("--retries must be between 0 and 3.")
        }
    }

    var isRequested: Bool {
        verify || json || verifyTimeout != nil || retries != nil
    }

    var resolvedTimeout: Double { verifyTimeout ?? Self.defaultTimeout }
    var resolvedRetries: Int { retries ?? RetryPolicy.defaultRetries }
}

protocol VerifiableCommand {
    var verification: VerificationOptions { get }
}
