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
            AppearanceCommand.self,
            ContentSizeCommand.self,
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
        if let message = LegacyArguments.migrationMessage(for: Array(CommandLine.arguments.dropFirst())) {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            Darwin.exit(OffsiderExitCode.usage.rawValue)
        }
        // ArgumentParser's own `main(nil)`, with the command's backends closed before the process exits.
        do {
            var command = try parseAsRoot(nil)
            try await CommandScope.current.run {
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
        } catch {
            exit(withError: error)
        }
    }
}
