import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Unlock code prompts")
struct UnlockCodePromptTests {
    @Test("a bad code names the fix, and a wrong or unconfirmed saved code warns with the command that saves it again", arguments: [
        (UnlockAttemptRecord.Outcome.rejected, "The saved PIN is wrong: Pixel stayed locked after Offsider typed it on 21 Sep at 14:13. Offsider won't type it again: repeated wrong PINs can lock a phone out."),
        (UnlockAttemptRecord.Outcome.started, "Offsider can't tell if the saved PIN is right: it has no result for its unlock of Pixel on 21 Sep at 14:13. Offsider won't type it until then: repeated wrong PINs can lock a phone out."),
    ])
    func codeProblems(outcome: UnlockAttemptRecord.Outcome, warning: String) throws {
        #expect(UnlockCodeScreen.codeProblem("123") != nil)
        #expect(UnlockCodeScreen.codeProblem("1234") == nil)
        let attempt = UnlockAttemptRecord(outcome: outcome, at: Date(timeIntervalSince1970: 1_790_000_000), credential: "pin")
        let page = UnlockCodeScreen.status(name: "Pixel", device: "SERIAL", saved: true, lastAttempt: attempt, timeZone: try #require(TimeZone(identifier: "UTC")))
        #expect(page.notices.map(\.kind) == [.warning])
        #expect(page.notices.first?.text == warning)
        #expect(page.notices.first?.command == "offsider unlock-code set --device SERIAL")
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
