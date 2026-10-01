import OffsiderCore
import Testing
@testable import Offsider

@Suite("Batch Step Failure Tests")
@MainActor
struct BatchStepFailureTests {
    private func runSteps(_ steps: [String], continueOnError: Bool, on session: RecordingInputSession) async throws {
        let context = BatchContext(
            backend: StubBackend(session: session),
            device: session.device,
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200
        )
        try await Batch.runSteps(
            steps,
            context: context,
            session: session,
            continueOnError: continueOnError,
            logger: OffsiderLogger()
        )
    }

    @Test("a failing step stops the batch and reports the underlying error text")
    func failingStepReportsUnderlyingError() async {
        let session = RecordingInputSession(
            failingOn: .shortKeyPress(40),
            with: CLIError(errorDescription: "HID broker read timed out.")
        )

        let error = await #expect(throws: CLIError.self) {
            try await runSteps(["key 40", "key 41"], continueOnError: false, on: session)
        }

        #expect(error?.userFacingDescription == "Step 1 failed: [key]\nHID broker read timed out.")
        #expect(session.calls == [.perform(.shortKeyPress(40))])
    }

    @Test("continue-on-error runs later steps and reports each failure's underlying error text")
    func continueOnErrorReportsEachUnderlyingError() async {
        let session = RecordingInputSession()

        let error = await #expect(throws: CLIError.self) {
            try await runSteps(
                ["unknown-command", "sleep", "key abc", "tap --id Missing", "key 40"],
                continueOnError: true,
                on: session
            )
        }

        let message = error?.userFacingDescription ?? ""
        #expect(message.hasPrefix("Batch completed with 4 failure(s):\n"))
        #expect(message.contains("Step 1 failed: [unknown-command] -> Unsupported batch step 'unknown-command'."))
        #expect(message.contains("Step 2 failed: [sleep] -> Sleep step format: sleep <seconds>"))
        #expect(message.contains("Step 3 failed: [key] -> The value 'abc' is invalid for '<keycode>'"))
        #expect(message.contains("Step 4 failed: [tap] -> No accessibility element matched --id 'Missing'."))
        #expect(!message.contains("The operation couldn’t be completed"))
        #expect(session.calls == [.perform(.shortKeyPress(40))])
    }
}
