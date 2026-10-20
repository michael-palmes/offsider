import ArgumentParser
import Darwin
import Foundation
import OffsiderAndroid
import OffsiderCore

/// The pickers `main` offers a person when a device command names no device, or `boot` names nothing to boot.
/// Only a person on a terminal on stdin, stdout and stderr gets one, never under JSON output, so an agent still gets exit 64.
enum DevicePicker {
    /// The flags that ask for machine-readable output.
    static let machineFlags: Set<String> = ["--json", "--format", "--compact"]

    @TaskLocal static var terminal: @Sendable () -> Bool = {
        prompts(terminals: isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0)
    }

    /// A person at terminals on all three streams; an agent on a pseudo-terminal is never kept waiting at a picker.
    static func prompts(terminals: Bool, profile: OutputProfile = .current) -> Bool {
        terminals && profile == .person
    }

    static func offers(arguments: [String], terminal: Bool) -> Bool {
        terminal && !arguments.contains { machineFlags.contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0) }
    }

    /// Whether the parse failed only for want of a device.
    static func missingDevice(_ error: any Error) -> Bool {
        OffsiderCommand.message(for: error).contains(DeviceDefault.missingMessage)
    }

    /// Whether `boot` was given no name: the arguments start with it and the parse asked for `<avd>`.
    static func missingBootName(_ error: any Error, arguments: [String]) -> Bool {
        arguments.first == Boot._commandName && OffsiderCommand.message(for: error).contains("Missing expected argument '<avd>'")
    }

    enum Need: Equatable {
        case device
        case boot
    }

    /// What a picker would supply, or nil when the line fails for another reason a pick would not mend.
    static func need(for error: any Error, arguments: [String]) -> Need? {
        if missingDevice(error) {
            let parses = DeviceDefault.$trialPick.withValue("00000000-0000-4000-8000-000000000000") {
                (try? OffsiderCommand.parseAsRoot(arguments)) != nil
            }
            return parses ? .device : nil
        }
        if missingBootName(error, arguments: arguments) {
            return (try? OffsiderCommand.parseAsRoot([arguments[0], "Offsider_Picker"] + arguments.dropFirst())) == nil ? nil : .boot
        }
        return nil
    }

    /// Runs `pick`; when no key comes in time, writes one dim line and throws the parse error the picker stood in for, so the exit stays 64.
    @MainActor
    static func orUnanswered(_ error: any Error, boot: Bool = false, _ pick: @MainActor () async throws -> DeviceSummary) async throws -> DeviceSummary {
        do {
            return try await pick()
        } catch let timeout as PromptTimedOut {
            let console = Console.current
            console.data(console.err.canvas.style.dim(DevicePickerScreen.unanswered(within: timeout.waited, boot: boot)) + "\n", to: .err)
            throw error
        }
    }

    /// Simulators and emulators only: the physical-device backend is never asked.
    @MainActor
    static func virtualDevices() async throws -> [DeviceSummary] {
        let logger = OffsiderLogger()
        let scope = CommandScope.current
        let backends: [any DeviceBackend] = [scope.adopt(IOSBackend(logger: logger)), scope.adopt(AndroidBackend.make(logger: logger, host: .cli()))]
        return DeviceListOrder.sorted(try await ListDevices.collect(from: backends) { _ in }.filter { $0.kind != .physical })
    }

    /// Asks which running simulator or emulator to drive; R looks again.
    @MainActor
    static func pickRunning(
        descriptor: Int32? = nil, idle: TimeInterval = TerminalPrompt.defaultIdle, list: @MainActor () async throws -> [DeviceSummary] = virtualDevices
    ) async throws -> DeviceSummary {
        try await pick(
            DevicePickerScreen.deviceQuestion, descriptor: descriptor, idle: idle, empty: DevicePickerScreen.noneRunning,
            next: ("Boot", DevicePickerScreen.bootCommand), offered: { DevicePickerScreen.runningDevices(try await list()) }, row: DevicePickerScreen.deviceRow
        )
    }

    /// Asks which simulator or AVD to boot; running ones say so.
    @MainActor
    static func pickBootable(
        descriptor: Int32? = nil, idle: TimeInterval = TerminalPrompt.defaultIdle, list: @MainActor () async throws -> [DeviceSummary] = virtualDevices
    ) async throws -> DeviceSummary {
        try await pick(
            DevicePickerScreen.bootQuestion, descriptor: descriptor, idle: idle, empty: DevicePickerScreen.noneToBoot,
            next: nil, offered: { DevicePickerScreen.bootable(try await list()) }, row: DevicePickerScreen.bootRow
        )
    }

    @MainActor
    private static func pick(
        _ question: String, descriptor: Int32?, idle: TimeInterval, empty: String, next: (label: String, command: String)?,
        offered: @MainActor () async throws -> [DeviceSummary], row: (DeviceSummary) -> MenuRow
    ) async throws -> DeviceSummary {
        try await TerminalPrompt.runAsync(cancelled: DevicePickerScreen.cancelled, descriptor: descriptor, idle: idle) { prompt in
            while true {
                let devices = try await TerminalSpinner.run("Looking for devices", terminal: prompt.terminalDescriptor) { try await offered() }
                do {
                    let index = try prompt.choose(
                        question, rows: devices.map(row), warning: devices.isEmpty ? empty : nil,
                        commands: devices.isEmpty ? next.map { [$0] } ?? [] : [], rescan: true, keepsChoice: false, filterable: true
                    )
                    return devices[index]
                } catch is PromptRefresh {
                    continue
                }
            }
        }
    }
}
