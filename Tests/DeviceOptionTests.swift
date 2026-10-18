import ArgumentParser
import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Device Option Tests")
struct DeviceOptionTests {
    private static let commandsWithoutDevice: Set<String> = ["boot", "guide", "init", "list-devices", "run"]

    @Test("every device command takes --device and none takes --udid")
    func deviceCommandsTakeDevice() async throws {
        let rootHelp = try await TestHelpers.runOffsiderCommand("--help").output
        let names = TestHelpers.listedSubcommands(in: rootHelp).filter { !Self.commandsWithoutDevice.contains($0) }

        #expect(names.contains("tap"))
        #expect(names.contains("doctor"))
        #expect(!rootHelp.contains("list-simulators"))
        var commands: [String] = []
        var pending = names
        while let name = pending.first {
            pending.removeFirst()
            let nested = TestHelpers.listedSubcommands(in: try await TestHelpers.runOffsiderCommand("\(name) --help").output)
            if nested.isEmpty { commands.append(name) } else { pending += nested.map { "\(name) \($0)" } }
        }
        #expect(commands.contains("rn prepare"))
        #expect(commands.contains("rn logbox dismiss"))
        for name in commands {
            let help = try await TestHelpers.runOffsiderCommand("\(name) --help").output
            #expect(help.contains("--device <id>"), "\(name) --help does not show --device <id>")
            #expect(!help.contains("--udid"), "\(name) --help still mentions --udid")
        }
    }

    private static func allCommands(_ root: any ParsableCommand.Type = OffsiderCommand.self) -> [any ParsableCommand.Type] {
        root.configuration.subcommands.flatMap { sub in
            sub.configuration.subcommands.isEmpty ? [sub] : allCommands(sub)
        }
    }

    @Test("exactly the commands that can lock the device take --wait-lock")
    func waitLockOnlyOnLockingCommands() {
        let commands = Self.allCommands()
        #expect(commands.count > 30)
        for command in commands {
            let help = command.helpMessage(columns: 400)
            let name = command._commandName
            #expect(help.contains("--wait-lock") == (command is any LockingCommand.Type), "\(name): --wait-lock in help does not match LockingCommand")
        }
        #expect(PermissionCommand.self is any LockingCommand.Type)
        #expect(StatusBarCommand.self is any LockingCommand.Type)
        #expect(!(Logs.self is any LockingCommand.Type))
    }

    @Test("a command that never locks refuses --wait-lock as a usage error")
    func waitLockRefusedOnReads() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("displays --wait-lock 5 --device \(UUID().uuidString)")
        #expect(result.exitCode == 64)
    }

    @Test("--device is required on input commands and optional on doctor")
    func deviceRequirement() throws {
        #expect(throws: (any Error).self) { try Tap.parse(["-x", "1", "-y", "1"]) }
        #expect(try Tap.parse(["-x", "1", "-y", "1", "--device", "ID"]).deviceOption.id == "ID")
        #expect(try Doctor.parse([]).deviceOption.id == nil)
        let udid = UUID().uuidString
        #expect(try Doctor.parse(["--device", udid]).deviceOption.id == udid)
        #expect(try Doctor.parse(["--device", "emulator-5556"]).deviceOption.id == "emulator-5556")
    }

    private static func withDefault<T>(_ value: String?, _ body: () throws -> T) rethrows -> T {
        try DeviceDefault.$environment.withValue({ value }, operation: body)
    }

    @Test("without --device, OFFSIDER_DEVICE names the device; without either the command is refused")
    func environmentDefault() throws {
        let tap = try Self.withDefault("emulator-5554") { try Tap.parse(["-x", "1", "-y", "1"]) }
        #expect(Self.withDefault("emulator-5554") { tap.deviceOption.id } == "emulator-5554")
        #expect(Self.withDefault("emulator-5554") { tap.deviceOption.source } == .environment)
        let read = try Self.withDefault("emulator-5554") { try DescribeUI.parse([]) }
        #expect(Self.withDefault("emulator-5554") { read.deviceOption.id } == "emulator-5554")
        do {
            _ = try Self.withDefault(nil) { try Tap.parse(["-x", "1", "-y", "1"]) }
            Issue.record("expected a usage error")
        } catch {
            #expect(Tap.exitCode(for: error) == .validationFailure)
            #expect(Tap.message(for: error) == DeviceDefault.missingMessage)
        }
    }

    @Test("an explicit --device wins over OFFSIDER_DEVICE")
    func explicitWins() throws {
        let tap = try Self.withDefault("emulator-5554") { try Tap.parse(["-x", "1", "-y", "1", "--device", "emulator-5556"]) }
        #expect(Self.withDefault("emulator-5554") { tap.deviceOption.id } == "emulator-5556")
        #expect(Self.withDefault("emulator-5554") { tap.deviceOption.source } == .option)
    }

    @Test("a blank OFFSIDER_DEVICE counts as unset", arguments: ["", "  ", "\n"])
    func blankIsUnset(value: String) {
        #expect(DeviceDefault.resolve(explicit: nil, environment: value) == nil)
        #expect(throws: (any Error).self) { try Self.withDefault(value) { try Tap.parse(["-x", "1", "-y", "1"]) } }
    }

    @Test("doctor and permission pick up OFFSIDER_DEVICE; permission services and runner and session filters ignore it")
    func environmentScope() throws {
        try Self.withDefault("emulator-5554") {
            let doctor = try Doctor.parse([])
            #expect(doctor.deviceOption.id == "emulator-5554")
            #expect(doctor.deviceOption.source == .environment)
            #expect(try PermissionCommand.parse(["grant", "camera", "--app", "com.example.app"]).device == "emulator-5554")
            #expect(try PermissionCommand.parse(["services"]).device == nil)
            #expect(try RunnerStop.parse([]).device == nil)
            #expect(try RunnerStatus.parse([]).device == nil)
        }
        #expect(try Self.withDefault(nil) { try Doctor.parse([]) }.deviceOption.explicitID == nil)
    }

    @Test("batch steps cannot choose their own device", arguments: [
        ["-x", "1", "--device", "OTHER"], ["--device=OTHER"], ["--udid", "OTHER"], ["--udid=OTHER"],
    ])
    func batchStepsRejectDevice(arguments: [String]) {
        #expect(throws: ValidationError.self) { try BatchStepParser.rejectPerStepDevice(arguments) }
    }

    @Test("batch step text that merely mentions a device is allowed")
    func batchStepTextIsAllowed() throws {
        try BatchStepParser.rejectPerStepDevice(["--device-name", "x"])
        try BatchStepParser.rejectPerStepDevice(["hello --udid"])
    }

    @Test("the device picker lists booted simulators and running emulators, never a physical device even when it is allowed")
    @MainActor
    func pickerNeverListsPhysical() async throws {
        var phone = DeviceSummary(
            id: PolicyFixtures.phone, platform: .ios, state: "Booted", name: "Test iPhone", osVersion: "iOS 27.2", deviceType: "iPhone 17 Pro", kind: .physical, connection: "usb"
        )
        phone.allowed = true
        let simulator = DeviceSummary(id: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios, state: "Booted", name: "Test Sim", osVersion: "iOS 27.1", deviceType: nil, kind: .simulator, connection: nil)
        let stopped = DeviceSummary(id: "ABCDEF00-0000-4000-8000-00000000ABCE", platform: .ios, state: "Shutdown", name: "Stopped Sim", osVersion: "iOS 27.1", deviceType: nil, kind: .simulator, connection: nil)
        let terminal = try AccessTerminal()
        terminal.type(["\r"])
        let picked = try await DevicePicker.pickRunning(descriptor: terminal.secondary) { [phone, simulator, stopped] }
        #expect(picked == simulator)
        let transcript = terminal.finish()
        #expect(transcript.contains("\(DevicePickerScreen.deviceQuestion) \(TerminalUI.Controls(rescan: true).text(style: .detect(isTerminal: true)))"))
        #expect(transcript.contains("Test Sim  iOS 27.1"))
        #expect(!transcript.contains("Test iPhone"))
        #expect(!transcript.contains("Stopped Sim"))
        #expect(DevicePickerScreen.using(simulator, style: .plain) == "Using Test Sim · add --device \(simulator.id) to skip this")
    }

    @Test("a picker no one answers closes after its idle time, and the missing-device error stands with exit 64")
    @MainActor
    func unansweredPickerTimesOut() async throws {
        let simulator = DeviceSummary(id: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios, state: "Booted", name: "Test Sim", osVersion: "iOS 27.1", deviceType: nil, kind: .simulator, connection: nil)
        let terminal = try AccessTerminal()
        let missing = Self.parseError(["tap", "-x", "1", "-y", "1"])
        let started = Date()
        let timedOut = await #expect(throws: PromptTimedOut.self) {
            _ = try await DevicePicker.pickRunning(descriptor: terminal.secondary, idle: 0.3) { [simulator] }
        }
        #expect(timedOut?.exitCode.rawValue == 64)
        let error = await #expect(throws: (any Error).self) {
            _ = try await DevicePicker.orUnanswered(missing) { try await DevicePicker.pickRunning(descriptor: terminal.secondary, idle: 0.3) { [simulator] } }
        }
        // Two prompts left to the default idle would take twice this; a full parallel run can hold the main actor for many seconds.
        #expect(Date().timeIntervalSince(started) < TerminalPrompt.defaultIdle)
        #expect(OffsiderCommand.exitCode(for: try #require(error)).rawValue == 64)
        #expect(OffsiderCommand.message(for: try #require(error)).contains(DeviceDefault.missingMessage))
        #expect(DevicePickerScreen.unanswered(within: PromptTimedOut.duration(TerminalPrompt.defaultIdle)) == "No device chosen within 60 s; pass --device <id>.")
        #expect(PromptTimedOut.duration(DeviceAccessAllow.promptIdle) == "10 minutes")
    }

    @Test("without a terminal, or under JSON output, a command with no device still exits 64 and no picker is offered")
    func noPickerForAgents() async throws {
        #expect(DevicePicker.offers(arguments: ["tap", "-x", "1", "-y", "1"], terminal: true))
        #expect(!DevicePicker.offers(arguments: ["tap", "-x", "1", "-y", "1"], terminal: false))
        for flag in ["--json", "--format", "--format=json", "--compact"] {
            #expect(!DevicePicker.offers(arguments: ["screenshot", flag], terminal: true))
        }
        let piped = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1", unsetting: ["OFFSIDER_DEVICE"])
        #expect(piped.exitCode == 64)
        #expect(piped.stderr.contains(DeviceDefault.missingMessage))
        let json = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json", unsetting: ["OFFSIDER_DEVICE"])
        #expect(json.exitCode == 64)
        #expect(json.stdout.contains("\"exitCode\":64"))
        let boot = try await TestHelpers.runOffsiderCommandSeparated("boot")
        #expect(boot.exitCode == 64)
    }

    @Test("a parse that fails only for want of a device or boot name is the one the picker answers")
    func pickerAnswersOnlyMissingDevice() {
        func need(_ arguments: [String]) -> DevicePicker.Need? { Self.withDefault(nil) { DevicePicker.need(for: Self.parseError(arguments), arguments: arguments) } }
        #expect(need(["tap", "-x", "1", "-y", "1"]) == .device)
        #expect(need(["tap", "-x", "1", "-y", "1", "--bogus"]) == nil)
        #expect(need(["credential", "set"]) == .device)
        #expect(need(["credential", "set", "--app", "com.example.app"]) == nil)
        #expect(need(["boot"]) == .boot)
        #expect(need(["boot", "--timeout", "1"]) == nil)
        #expect(need(["tap", "-x", "1", "-y", "1", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD", "--bogus"]) == nil)
    }

    @Test("checking whether a pick would mend a line never lends a device to a parse running alongside it")
    func pickerCheckStaysInItsTask() async {
        let line = ["tap", "-x", "1", "-y", "1"]
        let parsedWithoutDevice = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { Self.withDefault(nil) { _ = DevicePicker.need(for: Self.parseError(line), arguments: line) }; return false }
                group.addTask { Self.withDefault(nil) { (try? Tap.parse(Array(line.dropFirst()))) != nil } }
            }
            return await group.contains(true)
        }
        #expect(!parsedWithoutDevice)
    }

    private static func parseError(_ arguments: [String]) -> any Error {
        Self.withDefault(nil) {
            do {
                _ = try OffsiderCommand.parseAsRoot(arguments)
                return CancellationError()
            } catch {
                return error
            }
        }
    }
}
