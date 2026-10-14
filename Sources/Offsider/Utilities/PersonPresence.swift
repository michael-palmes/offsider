import Darwin
import Foundation
import LocalAuthentication
import OffsiderCore

/// Asks the person at the Mac to confirm a step with Touch ID or their login password.
protocol PresenceChecking: Sendable {
    func confirm(reason: String) async throws
}

/// The gate in front of anything an agent must not do alone: reading a guarded login, linking apps, loosening a saved login.
enum PersonPresence {
    /// Tests inject a fake; there is no environment switch.
    @TaskLocal static var current: any PresenceChecking = LocalAuthenticationPresence()
    /// Whether standard input is a terminal. Tests inject the answer.
    @TaskLocal static var terminal: @Sendable () -> Bool = { isatty(STDIN_FILENO) != 0 }
    /// Whether this process can open its controlling terminal. Tests inject the answer.
    @TaskLocal static var controllingTerminal: @Sendable () -> Bool = {
        let descriptor = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }

    /// `reason` completes macOS's sentence "offsider is trying to ...", and never names a username.
    static func confirm(reason: String) async throws {
        try await current.confirm(reason: reason)
    }

    /// Refuses with `person_required` when standard input is not a terminal. `instead` names the command a person runs.
    static func requireTerminal(instead: String) throws {
        guard terminal() else {
            throw CLIError.personRequired("This step needs a person at a terminal, and standard input is not one. Nothing was changed. \(instead)")
        }
    }

    /// Refuses with `person_required` when there is no controlling terminal to ask on, as when piped from another program with no terminal.
    static func requireControllingTerminal(instead: String) throws {
        guard controllingTerminal() else {
            throw CLIError.personRequired("This step needs a person at a terminal, and this process has none. Nothing was changed. \(instead)")
        }
    }

    static let noSessionMessage = "Offsider needs Touch ID or your password in a logged-in GUI session; over ssh it cannot be confirmed. Nothing was typed or saved."
    static let cancelledMessage = "The confirmation was cancelled, so nothing was typed or saved."

    /// The `person_required` error for a LocalAuthentication failure.
    static func error(for code: LAError.Code?) -> CLIError {
        switch code {
        case .userCancel?, .appCancel?, .systemCancel?, .userFallback?:
            return .personRequired(cancelledMessage)
        case .notInteractive?, .passcodeNotSet?, .companionNotAvailable?:
            return .personRequired(noSessionMessage)
        case .authenticationFailed?:
            return .personRequired("Touch ID or the password did not confirm the person at this Mac, so nothing was typed or saved.")
        default:
            let detail = code.map { " (LocalAuthentication error \($0.rawValue))" } ?? ""
            return .personRequired("Could not confirm a person at this Mac\(detail). \(noSessionMessage)")
        }
    }
}

/// `LAContext` with `.deviceOwnerAuthentication`: Touch ID, a paired watch, or the login password.
struct LocalAuthenticationPresence: PresenceChecking {
    func confirm(reason: String) async throws {
        let context = LAContext()
        context.interactionNotAllowed = false
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            throw PersonPresence.error(for: problem.map { LAError.Code(rawValue: $0.code) } ?? nil)
        }
        let box = ContextBox(context: context)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    let code = (error as? LAError)?.code ?? (error as NSError?).flatMap { LAError.Code(rawValue: $0.code) }
                    continuation.resume(throwing: PersonPresence.error(for: code))
                }
            }
        }
    }
}

/// `LAContext` is not `Sendable`; the box only carries it into the reply closure's evaluation call.
private final class ContextBox: @unchecked Sendable {
    let context: LAContext
    init(context: LAContext) { self.context = context }
}
