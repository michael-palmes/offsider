import ArgumentParser
import Foundation
import OffsiderCore

struct Key: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a single key by keycode on the device.",
        discussion: """
        Press individual keys using their HID keycode values.
        
        Common keycodes:
          40 - Return/Enter
          42 - Backspace
          43 - Tab
          44 - Space
          58-67 - F1-F10
          224-231 - Modifier keys (Ctrl, Shift, Alt, etc.)
        
        Examples:
          offsider key 40 --device DEVICE_ID                    # Press Enter
          offsider key 44 --device DEVICE_ID                    # Press Space
          offsider key 42 --duration 1.0 --device DEVICE_ID    # Hold Backspace for 1 second
        """
    )
    
    @Argument(help: "The HID keycode to press (0-255).")
    var keycode: Int
    
    @Option(name: .customLong("duration"), help: "Duration to hold the key in seconds (optional).")
    var duration: Double?
    
    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var systemKeys: SystemKeyOptions

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        // Validate keycode range
        guard keycode >= 0 && keycode <= 255 else {
            throw ValidationError("Keycode must be between 0 and 255.")
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
    }

    func run() async throws {
        guard verification.verify else {
            try await execute(progress: nil)
            return
        }
        try await VerifyOutput.reportingFailures(command: "key", target: "keycode \(keycode)", options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try systemKeys.check([keycode], on: device)
        try await backend.prepare()

        logger.info().log("Pressing key with keycode: \(keycode)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let keyEvent: InputEvent
        if let duration = duration {
            keyEvent = .composite([
                .keyboard(direction: .down, keyCode: UInt32(keycode)),
                .delay(duration),
                .keyboard(direction: .up, keyCode: UInt32(keycode))
            ])
        } else {
            keyEvent = .shortKeyPress(UInt32(keycode))
        }
        
        if let progress {
            let request = VerifyRequest(
                command: "key",
                subject: "Key \(keycode)",
                target: "keycode \(keycode)",
                backend: backend,
                device: device,
                options: verification,
                styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries))
            )
            try await VerifyOutput.perform(request, progress: progress) { _, session in
                try await session.perform(keyEvent)
            }
            return
        }

        // Perform the key event
        try await backend.performTracked(keyEvent, on: device)
        
        logger.info().log("Key press completed successfully")
    }
} 
