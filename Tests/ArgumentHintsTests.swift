import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Argument hints")
@MainActor
struct ArgumentHintsTests {
    private let udidHint = "--udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs."
    private let listHint = "list-simulators was renamed to list-devices in 0.3.0."

    @Test("--udid in either form gets the rename hint", arguments: [
        ["tap", "-x", "1", "-y", "1", "--udid", "X"], ["describe-ui", "--udid=X"], ["--udid", "X", "tap"], ["doctor", "--udid"],
    ])
    func udidIsRenamed(arguments: [String]) {
        #expect(ArgumentHints.hint(for: arguments) == ArgumentHints.Hint(message: udidHint, isLegacy: true))
    }

    @Test("the list-simulators subcommand gets the rename hint")
    func listSimulatorsIsRenamed() {
        #expect(ArgumentHints.hint(for: ["list-simulators"])?.message == listHint)
        #expect(ArgumentHints.hint(for: ["list-simulators", "--udid", "X"])?.message == listHint)
    }

    @Test("current names, look-alikes, other commands' options and plain text are left to the parser", arguments: [
        [], ["list-devices"], ["tap", "--device", "X"], ["type", "list-simulators", "--device", "X"],
        ["batch", "--device", "X", "--step", "tap --udid Y"], ["tap", "--udids", "X"], ["type", "--device", "X", "--", "--udid"],
        ["wait", "--id", "a", "--timeout", "5"], ["tap", "--id", "a", "--wait-timeout", "5"], ["swipe", "--timeout"],
        ["type", "--device", "X", "--", "--timeout"], ["wait", "--id", "a", "--", "--wait-timeout"],
    ])
    func othersAreUntouched(arguments: [String]) {
        #expect(ArgumentHints.hint(for: arguments) == nil)
    }

    @Test("the internal hid-broker keeps its --udid")
    func brokerKeepsUDID() {
        #expect(ArgumentHints.hint(for: ["hid-broker", "--udid", "X"]) == nil)
    }

    /// Each wrong option, the hint it gets, and the suggested command, which must parse.
    static let misnamed: [(wrong: [String], hint: String, suggestion: [String])] = [
        (["wait", "--id", "a", "--wait-timeout", "5"], "wait takes --timeout <seconds>, not --wait-timeout.", ["wait", "--id", "a", "--timeout", "5"]),
        (["wait", "--id", "a", "--verify-timeout=5"], "wait takes --timeout <seconds>, not --verify-timeout.", ["wait", "--id", "a", "--timeout", "5"]),
        (["assert", "--id", "a", "--timeout", "5"], "assert checks once and has no --timeout. To wait for the condition, run offsider wait with the same selector and --timeout <seconds>.", ["wait", "--id", "a", "--timeout", "5"]),
        (["tap", "--id", "a", "--timeout", "5"], "tap has no --timeout: --wait-timeout <seconds> waits for the element to appear, and --verify-timeout <seconds> (with --verify) waits for the tap's effect.", ["tap", "--id", "a", "--wait-timeout", "5"]),
        (["tap", "--id", "a", "--timeout", "5"], "tap has no --timeout: --wait-timeout <seconds> waits for the element to appear, and --verify-timeout <seconds> (with --verify) waits for the tap's effect.", ["tap", "--id", "a", "--verify", "--verify-timeout", "5"]),
    ]

    @Test("each misnamed option gets its hint as a usage error, never a rename", arguments: misnamed.indices)
    func misnamedOptionHints(index: Int) {
        let (wrong, hint, _) = Self.misnamed[index]
        #expect(ArgumentHints.hint(for: wrong) == ArgumentHints.Hint(message: hint, isLegacy: false))
    }

    @Test("each misnamed option really fails to parse, and each suggestion parses", arguments: misnamed.indices)
    func hintsMatchTheParser(index: Int) throws {
        let (wrong, _, suggestion) = Self.misnamed[index]
        #expect(throws: (any Error).self) { _ = try OffsiderCommand.parseAsRoot(wrong + ["--device", "X"]) }
        _ = try OffsiderCommand.parseAsRoot(suggestion + ["--device", "X"])
    }

    @Test("a batch step with a misnamed option fails with the same hint before anything is sent")
    func batchStepHint() async throws {
        let session = RecordingInputSession()
        let context = BatchContext(backend: StubBackend(session: session), device: session.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 1)
        let error = await #expect(throws: ReportedFailure.self) {
            try await Batch.runSteps(["tap --id a --timeout 5"], context: context, session: session, continueOnError: false, logger: OffsiderLogger())
        }
        #expect(error?.exitCode == .usage)
        #expect(error?.userFacingDescription.contains("tap has no --timeout") == true)
        #expect(session.calls.isEmpty)
    }

    @Test("the binary prints the hint and exits with a usage error", arguments: [
        ("tap -x 1 -y 1 --udid X", "Error: --udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs.\n"),
        ("list-simulators", "Error: list-simulators was renamed to list-devices in 0.3.0.\n"),
        ("wait --id a --wait-timeout 5 --device X", "Error: wait takes --timeout <seconds>, not --wait-timeout.\n"),
    ])
    func binaryPrintsHint(command: String, expected: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated(command)

        #expect(result.exitCode == 64)
        #expect(result.stderr == expected)
        #expect(result.stdout.isEmpty)
    }
}
