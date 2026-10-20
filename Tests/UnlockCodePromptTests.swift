import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Unlock code prompts")
struct UnlockCodePromptTests {
    @Test("a bad code names the fix, and a code that failed last time says to save it again")
    func codeProblems() {
        #expect(UnlockCodeScreen.codeProblem("123") != nil)
        #expect(UnlockCodeScreen.codeProblem("1234") == nil)
        #expect(UnlockCodeScreen.status(name: "Pixel", device: "SERIAL", saved: true, lastAttemptFailed: true, style: .plain).contains("unlock-code set --device SERIAL"))
    }

    @Test("unlock-code set --stdin with no terminal to confirm on is person_required, before the pipe is read")
    func pipedCodeNeedsATerminal() async {
        let error = await PersonPresence.$controllingTerminal.withValue({ false }) {
            await #expect(throws: CLIError.self) { try await UnlockCodeCommand.confirmedStandardInput(name: "Offsider_E2E", device: "Offsider_E2E") }
        }
        #expect(error?.reason == .personRequired)
        #expect(error?.hint == nil)
        #expect(error?.userFacingDescription.contains("`offsider unlock-code set --device Offsider_E2E`") == true)
        #expect(UnlockCodeCommand.pipedTitle(name: "Offsider_E2E").contains("Offsider_E2E"))
    }
}
