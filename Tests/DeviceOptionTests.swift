import ArgumentParser
import Foundation
import Testing
@testable import Offsider

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
}
