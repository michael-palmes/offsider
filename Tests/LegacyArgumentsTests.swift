import Foundation
import OffsiderCore
import Testing

@Suite("Legacy Arguments Tests")
struct LegacyArgumentsTests {
    private let udidHint = "--udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs."
    private let listHint = "list-simulators was renamed to list-devices in 0.3.0."

    @Test("--udid in either form gets the rename hint", arguments: [
        ["tap", "-x", "1", "-y", "1", "--udid", "X"], ["describe-ui", "--udid=X"], ["--udid", "X", "tap"], ["doctor", "--udid"],
    ])
    func udidIsRenamed(arguments: [String]) {
        #expect(LegacyArguments.migrationMessage(for: arguments) == udidHint)
    }

    @Test("the list-simulators subcommand gets the rename hint")
    func listSimulatorsIsRenamed() {
        #expect(LegacyArguments.migrationMessage(for: ["list-simulators"]) == listHint)
        #expect(LegacyArguments.migrationMessage(for: ["list-simulators", "--udid", "X"]) == listHint)
    }

    @Test("current names, look-alikes and plain text are left to the parser", arguments: [
        [], ["list-devices"], ["tap", "--device", "X"], ["type", "list-simulators", "--device", "X"],
        ["batch", "--device", "X", "--step", "tap --udid Y"], ["tap", "--udids", "X"], ["type", "--device", "X", "--", "--udid"],
    ])
    func othersAreUntouched(arguments: [String]) {
        #expect(LegacyArguments.migrationMessage(for: arguments) == nil)
    }

    @Test("the internal hid-broker keeps its --udid")
    func brokerKeepsUDID() {
        #expect(LegacyArguments.migrationMessage(for: ["hid-broker", "--udid", "X"]) == nil)
    }

    @Test("the binary prints the hint and exits with a usage error", arguments: [
        ("tap -x 1 -y 1 --udid X", "Error: --udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs.\n"),
        ("list-simulators", "Error: list-simulators was renamed to list-devices in 0.3.0.\n"),
    ])
    func binaryPrintsHint(command: String, expected: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated(command)

        #expect(result.exitCode == 64)
        #expect(result.stderr == expected)
        #expect(result.stdout.isEmpty)
    }
}
