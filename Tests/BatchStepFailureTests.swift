import Foundation
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

        let error = await #expect(throws: ReportedFailure.self) {
            try await runSteps(["key 40", "key 41"], continueOnError: false, on: session)
        }
        #expect(error?.exitCode == .failure)

        #expect(error?.userFacingDescription == "Step 1 failed: [key]\nHID broker read timed out.\nDispatched: unknown (input may have reached the device; check before resending)")
        #expect(session.calls == [.perform(.shortKeyPress(40))])
    }

    @Test("a failure after a step that sent input says the batch dispatched, whatever the failing step's code")
    func failureAfterInputIsDispatched() async {
        let session = RecordingInputSession(
            failingOn: .shortKeyPress(41),
            with: CLIError(errorDescription: "No device.", reason: .deviceNotFound)
        )
        let error = await #expect(throws: ReportedFailure.self) {
            try await runSteps(["key 40", "key 41"], continueOnError: false, on: session)
        }
        #expect(error?.exitCode == .deviceUnavailable)
        #expect(error?.userFacingDescription.hasSuffix("\nDispatched: yes (input may have reached the device; check before resending)") == true)
    }

    @Test("continue-on-error runs later steps and reports each failure's underlying error text")
    func continueOnErrorReportsEachUnderlyingError() async {
        let session = RecordingInputSession()

        let error = await #expect(throws: ReportedFailure.self) {
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

    @Test("a failed step's record carries the error object, and the batch exits with the first failed step's code")
    func failedStepRecordsErrorObject() async throws {
        let session = RecordingInputSession()
        var lines: [String] = []
        let output = BatchOutput(json: true, write: { lines.append($0) }, writeError: { _ in })
        let context = BatchContext(
            backend: StubBackend(session: session), device: session.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200
        )

        let error = await #expect(throws: ReportedFailure.self) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Batch.runSteps(["tap --id Missing", "key 40"], context: context, session: session, continueOnError: true, output: output, logger: OffsiderLogger())
            }
        }

        #expect(error?.exitCode == .selectorNotFound)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(record["exitCode"] as? Int == 2)
        let payload = try #require(record["error"] as? [String: Any])
        #expect(payload["reason"] as? String == "selector_not_found")
        #expect(payload["dispatched"] as? String == "no")
        #expect((payload["message"] as? String)?.hasPrefix("No accessibility element matched --id 'Missing'.") == true)
        #expect(payload["hint"] as? String == "offsider describe-ui --device <DEVICE_ID> --summary")
    }

    @Test("a send that fails part way reports dispatched unknown, and its code outranks a later step's")
    func failedSendIsUnknown() async throws {
        let session = RecordingInputSession(failingOn: .shortKeyPress(40), with: CLIError(errorDescription: "HID broker read timed out.", reason: .hidBrokerFailed))
        var lines: [String] = []
        let output = BatchOutput(json: true, write: { lines.append($0) }, writeError: { _ in })
        let context = BatchContext(
            backend: StubBackend(session: session), device: session.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200
        )

        let error = await #expect(throws: ReportedFailure.self) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Batch.runSteps(["key 40", "tap --id Missing"], context: context, session: session, continueOnError: true, output: output, logger: OffsiderLogger())
            }
        }

        #expect(error?.exitCode == .failure)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let payload = try #require(record["error"] as? [String: Any])
        #expect(payload["reason"] as? String == "hid_broker_failed")
        #expect(payload["dispatched"] as? String == "unknown")
    }
}
