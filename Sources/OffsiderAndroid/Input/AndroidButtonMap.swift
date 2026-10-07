import Foundation
import OffsiderCore

/// Android's hardware buttons as `KEYCODE_*` values for adb and gRPC `sendKey` events for the emulator.
enum AndroidButtonMap {
    static func keyCode(for button: HardwareButton) -> Int? {
        switch button {
        case .home: return 3
        case .lock: return 26
        case .back: return 4
        case .appSwitch: return 187
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .menu: return 82
        case .applePay, .sideButton, .siri: return nil
        }
    }

    static func w3cKey(for button: HardwareButton) -> String? {
        switch button {
        case .home: return "GoHome"
        case .lock: return "Power"
        case .back: return "GoBack"
        case .appSwitch: return "AppSwitch"
        case .volumeUp: return "AudioVolumeUp"
        case .volumeDown: return "AudioVolumeDown"
        case .menu, .applePay, .sideButton, .siri: return nil
        }
    }

    /// HID keyboard usage 118 (Menu), which `key 118` sends as the same KEYCODE_MENU.
    static let menuUsage: UInt32 = 118

    /// The emulator's key event for a button: Menu as its key's event, the others as W3C key values.
    static func grpcKey(for button: HardwareButton, phase: KeyPhase) -> EmulatorKeyEvent? {
        if button == .menu { return AndroidKeyTable.grpcKey(for: menuUsage, phase: phase) }
        return w3cKey(for: button).map { .w3c($0, phase) }
    }

    static func requireKeyCode(for button: HardwareButton) throws -> Int {
        guard let code = keyCode(for: button) else { throw AndroidError.unsupportedButton(button) }
        return code
    }
}
