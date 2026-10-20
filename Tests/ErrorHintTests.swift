import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid
@testable import OffsiderIOSDevice

@Suite("Error hints for people")
struct ErrorHintTests {
    @Test("a hint the message does not already name prints as a Try line, dim only with colours")
    func tryLine() {
        #expect(ErrorReporter.hintText("offsider devices", message: "Simulator X not found.", style: .plain) == "Try: offsider devices\n")
        #expect(ErrorReporter.hintText("offsider devices", message: "Run `offsider devices` to see them.", style: .plain) == "")
        #expect(ErrorReporter.hintText(nil, message: "Nothing to do.", style: .plain) == "")
        #expect(ErrorReporter.hintText("", message: "Nothing to do.", style: .plain) == "")
        let dim = ErrorReporter.hintText("offsider doctor", message: "x", style: TerminalStyle(colours: true))
        #expect(dim.hasPrefix("\u{1B}[2m") && TerminalText.stripStyle(dim) == "Try: offsider doctor\n")
    }

    @Test("a Try line escapes control characters like the Error line")
    func tryLineIsSanitised() {
        let text = ErrorReporter.hintText("offsider tap --id a\u{1B}]52;c;eA==\u{07}\nError: forged", message: "x", style: .plain)
        #expect(!text.contains("\u{1B}"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test("a failing command prints its hint on stderr when the message lacks it")
    func hintReachesStderr() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("displays --device \(UUID().uuidString)")
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Error: "))
        #expect(result.stderr.contains("\nTry: offsider devices\n"))
    }

    @Test("device_busy says to add --wait-lock to the same command, never rebuilding it without its arguments")
    func busyHint() {
        let busy = DeviceBusy(device: "emulator-5554", command: "type", holder: nil, waited: nil)
        #expect(busy.hint == "add --wait-lock 30 to the same command")
        #expect(busy.hint?.contains("offsider type") == false)
    }

    @Test("an agent is asked to fetch the user; a person at a terminal gets the command, never with --device")
    func allowWording() {
        let agent = CLIError.deviceNotAllowed(name: "Test Phone", key: "SERIAL123", refusal: .notAllowed, audience: .agent)
        #expect(agent.userFacingDescription.contains("Ask the user to run `offsider device-access allow` in their own terminal and choose Test Phone (SERIAL123); an agent cannot allow a device."))
        let person = CLIError.deviceNotAllowed(name: "Test Phone", key: "SERIAL123", refusal: .notAllowed, audience: .person)
        #expect(person.userFacingDescription.hasSuffix("so nothing was sent to it."))
        #expect(!person.userFacingDescription.contains("Ask the user"))
        #expect(!person.userFacingDescription.contains("--device"))
        #expect(person.hint == "offsider device-access allow")
    }

    @Test("an app outside the phone's allowance and a missing team split the same way")
    func appAndTeamWording() {
        let agent = AndroidError.appNotPermitted("SERIAL123", package: "com.example.app", byManagedPolicy: false, audience: .agent)
        #expect(agent.message.contains("ask the user to run `offsider device-access allow` in their own terminal"))
        let person = AndroidError.appNotPermitted("SERIAL123", package: "com.example.app", byManagedPolicy: false, audience: .person)
        #expect(!person.message.contains("ask the user"))
        #expect(person.hint == "offsider device-access allow")

        let team = #expect(throws: IOSDeviceError.self) {
            try XcodeRunnerBuilder.resolveTeam(environment: [:], allowanceTeam: nil, signedInTeams: [], audience: .person)
        }
        #expect(team?.message.contains("Ask the user") == false)
        #expect(team?.hint == "offsider device-access allow")
    }

    @Test("in-process callers, such as tests, always get the agent wording")
    func defaultAudienceIsAgent() {
        #expect(ErrorAudience.current == .agent)
    }

    @Test("bare offsider prints six start-here lines and exits 0")
    func bareOffsider() async throws {
        let result = try await CommandRunner.runSeparated(try TestHelpers.getOffsiderPath())
        #expect(result.exitCode == 0)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines.allSatisfy { $0.hasPrefix("  offsider ") })
        #expect(lines.map { $0.split(separator: " ")[1] } == ["devices", "doctor", "init", "guide", "boot", "--help"])
    }

    @Test("--help groups commands from Start to Sessions")
    func helpGroups() {
        let help = OffsiderCommand.helpMessage(columns: 200)
        let headings = ["START SUBCOMMANDS:", "READ SUBCOMMANDS:", "INPUT SUBCOMMANDS:", "DEVICE STATE SUBCOMMANDS:", "PHYSICAL DEVICES SUBCOMMANDS:", "SESSIONS SUBCOMMANDS:"]
        let positions = headings.compactMap { help.range(of: $0)?.lowerBound }
        #expect(positions.count == headings.count)
        #expect(positions == positions.sorted())
    }
}

@Suite("boot a simulator")
struct BootSimulatorTests {
    @Test("an unknown simulator UDID is not found and names devices")
    func unknownUDID() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("boot \(UUID().uuidString)")
        #expect(result.exitCode != 0 && result.exitCode != 64)
        #expect(result.stderr.contains("No simulator or AVD is named"))
    }

    @Test("boot --json for a simulator prints one versioned object")
    func report() {
        #expect(SimulatorBootReport(udid: "SIM-A", name: "iPhone 17", alreadyRunning: true).jsonLine()
            == #"{"version":1,"ok":true,"platform":"ios","name":"iPhone 17","udid":"SIM-A","alreadyRunning":true,"exitCode":0}"#)
    }
}
