import ArgumentParser
import Foundation
import OffsiderCore

struct KeySequence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a sequence of keys by their keycodes on the simulator.",
        discussion: """
        Press multiple keys in sequence using their HID keycode values.
        Each key will be pressed and released before the next key is pressed.
        
        Examples:
          offsider key-sequence 11,8,15,15,18 --udid SIMULATOR_UDID    # Type "hello" (h=11, e=8, l=15, l=15, o=18)
          offsider key-sequence 40,40,40 --udid SIMULATOR_UDID          # Press Enter 3 times
          offsider key-sequence 224,4,225 --udid SIMULATOR_UDID        # Ctrl+A (Ctrl=224, A=4, release Ctrl=225)
        """
    )
    
    @Option(name: .customLong("keycodes"), help: "Comma-separated list of HID keycodes to press in sequence.")
    var keycodesString: String
    
    @Option(name: .customLong("delay"), help: "Delay between key presses in seconds (default: 0.1).")
    var delay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String
    
    func validate() throws {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        
        // Validate that we have at least one keycode
        guard !parsedKeycodes.isEmpty else {
            throw ValidationError("At least one keycode must be provided.")
        }
        
        // Validate that all keycodes are in valid range
        for keycode in parsedKeycodes {
            guard keycode >= 0 && keycode <= 255 else {
                throw ValidationError("All keycodes must be between 0 and 255. Invalid keycode: \(keycode)")
            }
        }
        
        // Validate delay if provided
        if let delay = delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 5.0 else {
                throw ValidationError("Delay must not exceed 5 seconds.")
            }
        }
        
        // Validate sequence length
        guard parsedKeycodes.count <= 100 else {
            throw ValidationError("Key sequence must not exceed 100 keys.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(simulatorUDID, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1  // Default 100ms delay between keys
        
        logger.info().log("Pressing key sequence: \(parsedKeycodes)")
        logger.info().log("Delay between keys: \(keyDelay) seconds")

        var events: [InputEvent] = []
        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }
        let sequenceEvent = InputEvent.composite(events)

        try await backend.perform(sequenceEvent, on: device)
        
        logger.info().log("Key sequence completed successfully")
    }
} 
