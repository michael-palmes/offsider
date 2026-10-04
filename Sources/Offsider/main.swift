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
        abstract: "A utility to interact with iOS Simulators and Android Emulators and extract accessibility information.",
        version: VERSION,
        subcommands: [
            DescribeUI.self,
            ListDevices.self,
            Boot.self,
            Doctor.self,
            Init.self,
            Tap.self,
            Slider.self,
            Type.self,
            Swipe.self,
            Drag.self,
            Button.self,
            Shake.self,
            OrientationCommand.self,
            Displays.self,
            PostureCommand.self,
            AppearanceCommand.self,
            ContentSizeCommand.self,
            PermissionCommand.self,
            StatusBarCommand.self,
            BiometricCommand.self,
            Key.self,
            KeySequence.self,
            KeyCombo.self,
            Touch.self,
            Gesture.self,
            StreamVideo.self,
            RecordVideo.self,
            Screenshot.self,
            Logs.self,
            Wait.self,
            Assert.self,
            Batch.self,
            RN.self,
            HIDBrokerCommand.self
        ]
    )

    static func main() async {
        Timings.installTotal()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let message = LegacyArguments.migrationMessage(for: arguments) {
            ErrorReporter.prepare(command: nil, arguments: arguments)
            ErrorReporter.writeEnvelopeIfWanted(ErrorPayload(reason: .legacyArgument, message: message))
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            Darwin.exit(FailureReason.legacyArgument.exitCode.rawValue)
        }
        // ArgumentParser's own `main(nil)`, with the command's backends closed before the process exits.
        var parsed: (any ParsableCommand)?
        do {
            var command = try parseAsRoot(nil)
            parsed = command
            ErrorReporter.prepare(command: command, arguments: arguments)
            let name = type(of: command)._commandName
            let path = command is RNPrepare ? "rn \(name)" : name
            await CommandScope.current.configure(command: path)
            await DeviceClaims.current.configure(
                command: path,
                waitOption: (command as? any DeviceOptionCommand)?.deviceOption.waitLock
            )
            try await CommandScope.current.run {
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
        } catch {
            if parsed == nil {
                ErrorReporter.prepare(command: nil, arguments: arguments)
            }
            ErrorReporter.exit(error)
        }
    }
}
