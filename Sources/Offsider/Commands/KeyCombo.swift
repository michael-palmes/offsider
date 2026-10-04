import ArgumentParser
import Foundation
import OffsiderCore

struct KeyCombo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a key while holding one or more modifier keys on the device.",
        discussion: """
        Hold modifier keys and press another key as a single atomic operation.
        Modifier keys are held down, the target key is pressed and released,
        then modifier keys are released in reverse order (LIFO).

        Common modifier keycodes:
          224 - Left Control
          225 - Left Shift
          226 - Left Alt/Option
          227 - Left Command (GUI)
          228 - Right Control
          229 - Right Shift
          230 - Right Alt/Option
          231 - Right Command (GUI)

        Examples:
          offsider key-combo --modifiers 227 --key 4 --device DEVICE_ID          # Cmd+A (Select All)
          offsider key-combo --modifiers 227 --key 6 --device DEVICE_ID          # Cmd+C (Copy)
          offsider key-combo --modifiers 227 --key 25 --device DEVICE_ID         # Cmd+V (Paste)
          offsider key-combo --modifiers 227,225 --key 4 --device DEVICE_ID      # Cmd+Shift+A
        """
    )

    @Option(name: .customLong("modifiers"), help: "Comma-separated list of modifier keycodes to hold (0-255).")
    var modifiersString: String

    @Option(name: .customLong("key"), help: "The HID keycode to press while modifiers are held (0-255).")
    var key: Int

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        guard !parsedModifiers.isEmpty else {
            throw ValidationError("At least one modifier keycode must be provided.")
        }

        guard parsedModifiers.count <= 8 else {
            throw ValidationError("At most 8 modifier keycodes may be provided.")
        }

        for keycode in parsedModifiers {
            guard keycode >= 0 && keycode <= 255 else {
                throw ValidationError("All modifier keycodes must be between 0 and 255. Invalid keycode: \(keycode)")
            }
        }

        guard key >= 0 && key <= 255 else {
            throw ValidationError("Key must be between 0 and 255.")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        logger.info().log("Pressing key combo: modifiers=\(parsedModifiers), key=\(key)")

        // Build composite event:
        //   modifierDown1, modifierDown2, ..., shortKeyPress(key), ..., modifierUp2, modifierUp1
        var events: [InputEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyboard(direction: .down, keyCode: UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyboard(direction: .up, keyCode: UInt32(modifier)))
        }
        let comboEvent = InputEvent.composite(events)

        try await backend.performTracked(comboEvent, on: device)

        logger.info().log("Key combo completed successfully")
    }
}
