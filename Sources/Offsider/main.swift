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
            Key.self,
            KeySequence.self,
            KeyCombo.self,
            Touch.self,
            Gesture.self,
            StreamVideo.self,
            RecordVideo.self,
            Screenshot.self,
            Batch.self,
            HIDBrokerCommand.self
        ]
    )

    static func main() async {
        if let message = LegacyArguments.migrationMessage(for: Array(CommandLine.arguments.dropFirst())) {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            Darwin.exit(OffsiderExitCode.usage.rawValue)
        }
        await main(nil)
    }
}
