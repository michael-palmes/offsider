import Foundation
import OffsiderCore
import Security

/// Why the login Keychain would not answer without a person, as a refusal that names the fix.
enum KeychainAccess {
    enum Block: Equatable {
        /// The login Keychain is locked.
        case locked
        /// macOS would have to ask a person to let this build read the item, and nobody can be asked.
        case needsPerson
    }

    /// Whether the user domain's Keychain, the login Keychain Offsider's items live in, is locked; tests bind the answer.
    @TaskLocal static var isLocked: @Sendable () -> Bool = { liveIsLocked() }

    /// Unattended, a Keychain item this build may not read fails at once instead of raising a prompt nobody answers.
    static func configureForProcess(unattended: Bool = Unattended.isOn) {
        guard unattended else { return }
        SecKeychainSetUserInteractionAllowed(false)
    }

    /// With interaction off, macOS reports a locked Keychain and a prompt it may not show as errSecAuthFailed; without a GUI session, as errSecInteractionNotAllowed.
    static func block(for status: OSStatus, unattended: Bool = Unattended.isOn) -> Block? {
        let asks = status == errSecInteractionNotAllowed || (unattended && (status == errSecAuthFailed || status == errSecUserCanceled))
        let lockedAuth = status == errSecAuthFailed || status == errSecInteractionNotAllowed
        if lockedAuth, isLocked() { return .locked }
        return asks ? .needsPerson : nil
    }

    /// The clause for a message: `the login Keychain is locked`.
    static func clause(_ block: Block) -> String {
        switch block {
        case .locked: return "the login Keychain is locked"
        case .needsPerson:
            return Unattended.isOn
                ? "macOS must ask a person to let this Offsider build read it, and \(UnattendedMode.because)"
                : "macOS must ask a person to let this Offsider build read it, and this session has no screen to ask on"
        }
    }

    /// The block a `clause` describes, for a refusal that carries only its text.
    static func block(describedBy detail: String) -> Block {
        detail == clause(.locked) ? .locked : .needsPerson
    }

    static func reason(_ block: Block) -> FailureReason {
        block == .locked ? .keychainLocked : .personRequired
    }

    /// What the person does in the morning: unlock the Keychain, or rerun the command at the Mac and allow it.
    static func ask(_ block: Block) -> String {
        switch block {
        case .locked:
            guard let command = Unattended.currentCommand() else { return "Can you unlock the login Keychain on this Mac?" }
            return "Can you unlock the login Keychain on this Mac, then run `\(command)`?"
        case .needsPerson:
            return Unattended.runAsk(then: "choose Always Allow when macOS asks")
        }
    }

    private static func liveIsLocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDomainDefault(.user, &keychain) == errSecSuccess, let keychain else { return false }
        var status = SecKeychainStatus()
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) == 0
    }
}
