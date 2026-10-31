import ArgumentParser
import Foundation
import OffsiderCore

struct KeySequence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a sequence of keys by their keycodes on the device.",
        discussion: """
        Press multiple keys in sequence using their HID keycode values.
        Each key will be pressed and released before the next key is pressed.
        
        Examples:
          offsider key-sequence --keycodes 11,8,15,15,18 --device DEVICE_ID    # Type "hello" (h=11, e=8, l=15, l=15, o=18)
          offsider key-sequence --keycodes 40,40,40 --device DEVICE_ID         # Press Enter 3 times

        Letters, digits, space and punctuation (the keypad's too) need a text field with focus: with none, nothing is pressed (exit 1,
        no_focused_field), since keys that reach no field can act as app shortcuts. With a password field focused they are
        refused (exit 64, secure_field_argument), since keycodes stay in shell history; use login or type --stdin. A
        sequence holding a modifier (224 to 231), Return, Tab, arrows and other keys skip that refusal, and Return, Tab,
        arrows and other keys skip the focus check too.
        """
    )
    
    @Option(name: .customLong("keycodes"), help: "Comma-separated list of HID keycodes to press in sequence.")
    var keycodesString: String
    
    @Option(name: .customLong("delay"), help: "Delay between key presses in seconds (default: 0.1).")
    var delay: Double?
    
    @OptionGroup
    var systemKeys: SystemKeyOptions

    @OptionGroup
    var jsonOption: InputJSONOption

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption
    
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
        // The keys may spell typed text, so neither the receipt nor the JSON counts or names them.
        try await InputOutput.reporting(command: "key-sequence", target: "keys", json: jsonOption.json) { _ in
            let logger = OffsiderLogger()
            let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
            await appOption.apply(to: route)
            try await Console.current.progress("Pressing the keys") { try await perform(on: route, logger: logger) }
            Console.current.show(InputPersonView.receipt("Sent the key sequence"))
        }
    }

    /// Letters, digits, space, punctuation and the keypad's digits and operators type text; Return, Tab, arrows and modifiers do not.
    static func typesText(_ keycodes: [Int]) -> Bool {
        keycodes.contains { (4...39).contains($0) || (44...56).contains($0) || (84...87).contains($0) || (89...99).contains($0) }
    }

    /// Keys that spell text a password field would keep; a sequence with a modifier in it is a shortcut.
    static func spellsText(_ keycodes: [Int]) -> Bool {
        typesText(keycodes) && !keycodes.contains { (224...231).contains($0) }
    }

    @MainActor
    func perform(on route: DeviceRouter.Route, logger: OffsiderLogger) async throws {
        let backend = route.backend
        let device = route.device
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        try systemKeys.check(parsedKeycodes, on: device)
        try await backend.prepare()

        if Self.typesText(parsedKeycodes) {
            try await Type.checkTextFocus(
                readTree: { try await backend.accessibilityTree(for: device) }, device: device, clock: .live,
                warn: { Console.current.notice(.warning(InputPersonView.sentence($0), agent: $0)) },
                refusingSecureTarget: Self.spellsText(parsedKeycodes) ? Type.secureFieldRefusal(device: device, keys: true) : nil, keys: true,
                hitTester: backend as? any PointHitTesting
            )
        }

        let keyDelay = delay ?? 0.1  // Default 100ms delay between keys
        
        logger.info().log("Pressing \(parsedKeycodes.count) key\(parsedKeycodes.count == 1 ? "" : "s")")
        logger.info().log("Delay between keys: \(keyDelay) seconds")

        var events: [InputEvent] = []
        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }
        let sequenceEvent = InputEvent.composite(events)

        try await backend.performTracked(sequenceEvent, on: device)
        
        logger.info().log("Key sequence completed successfully")
    }
} 
