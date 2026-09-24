import ArgumentParser
import Foundation
import AppKit
import FBControlCore
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct OffsiderCommand: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let offsiderLogger = OffsiderLogger()

    static let configuration = CommandConfiguration(
        commandName: "offsider",
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
        version: VERSION,
        subcommands: [
            DescribeUI.self,
            ListSimulators.self,
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
}
