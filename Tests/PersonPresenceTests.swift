import Foundation
import LocalAuthentication
import OffsiderCore
import Testing
@testable import Offsider

/// A scripted Touch ID or password check: records each reason and fails with `failure` when set.
final class FakePresence: PresenceChecking, @unchecked Sendable {
    private(set) var reasons: [String] = []
    var failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func confirm(reason: String) async throws {
        reasons.append(reason)
        if let failure { throw failure }
    }
}

@Suite("Person presence")
struct PersonPresenceTests {
    @Test("a cancelled prompt is person_required and says nothing was typed or saved", arguments: [LAError.Code.userCancel, .appCancel, .systemCancel, .userFallback])
    func cancelled(code: LAError.Code) {
        let error = PersonPresence.error(for: code)
        #expect(error.reason == .personRequired)
        #expect(error.exitCode == .failure)
        #expect(error.userFacingDescription == "The confirmation was cancelled, so nothing was typed or saved.")
    }

    @Test("no GUI session, as over ssh, is person_required and names the logged-in GUI session", arguments: [LAError.Code.notInteractive, .passcodeNotSet])
    func noSession(code: LAError.Code) {
        let error = PersonPresence.error(for: code)
        #expect(error.reason == .personRequired)
        #expect(error.userFacingDescription.contains("in a logged-in GUI session; over ssh it cannot be confirmed"))
    }

    @Test("a failed match and an unknown error are person_required too, never a fallback that lets the step run")
    func otherFailures() {
        #expect(PersonPresence.error(for: .authenticationFailed).reason == .personRequired)
        let unknown = PersonPresence.error(for: nil)
        #expect(unknown.reason == .personRequired)
        #expect(unknown.userFacingDescription.hasPrefix("Could not confirm a person at this Mac."))
        #expect(PersonPresence.error(for: .biometryLockout).userFacingDescription.contains("LocalAuthentication error"))
    }

    @Test("requireTerminal refuses with person_required and the command a person runs, and passes at a terminal")
    func requireTerminal() throws {
        let error = PersonPresence.$terminal.withValue({ false }) {
            #expect(throws: CLIError.self) { try PersonPresence.requireTerminal(instead: "Ask the user to run `offsider credential join --device <id>` in their own terminal.") }
        }
        #expect(error?.reason == .personRequired)
        #expect(error?.userFacingDescription.hasSuffix("Ask the user to run `offsider credential join --device <id>` in their own terminal.") == true)
        try PersonPresence.$terminal.withValue({ true }) {
            try PersonPresence.requireTerminal(instead: "x")
        }
        let piped = PersonPresence.$controllingTerminal.withValue({ false }) {
            #expect(throws: CLIError.self) { try PersonPresence.requireControllingTerminal(instead: "y") }
        }
        #expect(piped?.reason == .personRequired)
    }

    @Test("the injected check is the one confirm uses")
    func injected() async throws {
        let fake = FakePresence()
        try await PersonPresence.$current.withValue(fake) {
            try await PersonPresence.confirm(reason: "type the saved login dev into com.example.app on emulator-5554")
        }
        #expect(fake.reasons == ["type the saved login dev into com.example.app on emulator-5554"])
    }
}
