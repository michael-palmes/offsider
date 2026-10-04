import ArgumentParser
import Foundation
import Testing
@testable import Offsider

@Suite("Device Option Tests")
struct DeviceOptionTests {
    private static let commandsWithoutDevice: Set<String> = ["boot", "init", "list-devices"]

    @Test("every device command takes --device and none takes --udid")
    func deviceCommandsTakeDevice() async throws {
        let rootHelp = try await TestHelpers.runOffsiderCommand("--help").output
        let names = TestHelpers.listedSubcommands(in: rootHelp).filter { !Self.commandsWithoutDevice.contains($0) }

        #expect(names.contains("tap"))
        #expect(names.contains("doctor"))
        #expect(!rootHelp.contains("list-simulators"))
        var commands: [String] = []
        for name in names {
            let nested = TestHelpers.listedSubcommands(in: try await TestHelpers.runOffsiderCommand("\(name) --help").output)
            commands += nested.isEmpty ? [name] : nested.map { "\(name) \($0)" }
        }
        #expect(commands.contains("rn prepare"))
        for name in commands {
            let help = try await TestHelpers.runOffsiderCommand("\(name) --help").output
            #expect(help.contains("--device <id>"), "\(name) --help does not show --device <id>")
            #expect(!help.contains("--udid"), "\(name) --help still mentions --udid")
        }
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
