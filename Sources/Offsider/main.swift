import ArgumentParser
import Foundation
import AppKit
import FBControlCore
import OffsiderCore
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct OffsiderCommand: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let offsiderLogger = OffsiderLogger()

    static let configuration = CommandConfiguration(
        commandName: "offsider",
        abstract: "A hand for your agent on iOS and Android, simulated or real: read and drive iOS Simulators, Android Emulators and USB iPhones, iPads and Android phones.",
        version: VERSION,
        subcommands: [HIDBrokerCommand.self, DeviceSessionCommand.self, AndroidSessionCommand.self, ListDevicesAlias.self],
        groupedSubcommands: [
            CommandGroup(name: "Start", subcommands: [ListDevices.self, Doctor.self, Init.self, Guide.self, Boot.self]),
            CommandGroup(name: "Read", subcommands: [
                DescribeUI.self, Screenshot.self, Logs.self, Wait.self, Assert.self, Displays.self, RecordVideo.self, StreamVideo.self,
            ]),
            CommandGroup(name: "Input", subcommands: [
                Tap.self, Type.self, Swipe.self, Drag.self, Touch.self, Gesture.self, Key.self, KeySequence.self, KeyCombo.self,
                Button.self, Slider.self, Shake.self, Turnstile.self, LoginCommand.self, CredentialCommand.self, Batch.self, RN.self,
            ]),
            CommandGroup(name: "Device state", subcommands: [
                OrientationCommand.self, PostureCommand.self, AppearanceCommand.self, ContentSizeCommand.self, PermissionCommand.self,
                StatusBarCommand.self, BiometricCommand.self, StayAwakeCommand.self, Wake.self, UnlockCodeCommand.self,
            ]),
            CommandGroup(name: "Physical devices", subcommands: [RunnerCommand.self]),
            CommandGroup(name: "Sessions", subcommands: [SessionCommand.self, RunCommand.self, LeaseCommand.self]),
        ]
    )

    static func main() async {
        await withCLIDefaults(runCommandLine)
    }

    /// Runs `body` as the CLI runs every command: a device watchdog that goes off ends the process.
    static func withCLIDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        try await DeviceWatchdog.$defaultAction.withValue(.exitProcess, operation: body)
    }

    @MainActor
    private static func runCommandLine() async {
        Timings.installTotal()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            Console.current.show(StartScreen.page(version: VERSION))
            Darwin.exit(0)
        }
        if let hint = ArgumentHints.hint(for: arguments) {
            let reason: FailureReason = hint.isLegacy ? .legacyArgument : .usage
            ErrorReporter.prepare(command: nil, arguments: arguments)
            ErrorReporter.writeEnvelopeIfWanted(ErrorPayload(reason: reason, message: hint.message))
            ErrorReporter.writeErrorLine(hint.message)
            Darwin.exit(reason.exitCode.rawValue)
        }
        // ArgumentParser's own `main(nil)`, with the command's backends closed before the process exits.
        var parsed: (any ParsableCommand)?
        do {
            var command = try await parseOrPick(arguments)
            parsed = command
            ErrorReporter.prepare(command: command, arguments: arguments)
            let path = CommandPath.of(command)
            await CommandScope.current.configure(command: path)
            await DeviceClaims.current.configure(
                command: path,
                waitOption: (command as? any LockingCommand)?.waitLock
            )
            let recorder = EvidenceRecorder.records(path)
                ? EvidenceRecorder(environment: .live(), command: path, arguments: Self.arguments(after: path, in: arguments))
                : EvidenceRecorder.current
            try await EvidenceRecorder.$current.withValue(recorder) {
                try await OutputMasks.$current.withValue(OutputMasks { AmbientMasks.outputMask() }) {
                    try await CommandScope.current.run {
                        if var asyncCommand = command as? any AsyncParsableCommand {
                            try await asyncCommand.run()
                        } else {
                            try command.run()
                        }
                    }
                }
            }
            Console.current.release()
        } catch {
            if parsed == nil {
                ErrorReporter.prepare(command: nil, arguments: arguments)
            }
            ErrorReporter.exit(error)
        }
    }

    /// Parses the command line; at a terminal, a missing device or boot name is chosen from a picker and the line parsed again.
    @MainActor
    static func parseOrPick(_ arguments: [String]) async throws -> any ParsableCommand {
        do {
            return try parseAsRoot(nil)
        } catch {
            guard DevicePicker.offers(arguments: arguments, terminal: DevicePicker.terminal()), let need = DevicePicker.need(for: error, arguments: arguments) else { throw error }
            if need == .device {
                let row = try await DevicePicker.orUnanswered(error) { try await DevicePicker.pickRunning() }
                DeviceDefault.picked = row.id
                let command = try parseAsRoot(nil)
                Console.current.data(DevicePickerScreen.using(row, style: Console.current.err.canvas.style) + "\n", to: .err)
                return command
            }
            let row = try await DevicePicker.orUnanswered(error, boot: true) { try await DevicePicker.pickBootable() }
            return try parseAsRoot([arguments[0], DevicePickerScreen.bootName(row)] + arguments.dropFirst())
        }
    }

    /// The arguments after the command's path words, as an evidence run records them.
    static func arguments(after path: String, in arguments: [String]) -> [String] {
        var remaining = arguments[...]
        for word in path.split(separator: " ") where remaining.first == String(word) {
            remaining = remaining.dropFirst()
        }
        return Array(remaining)
    }
}
