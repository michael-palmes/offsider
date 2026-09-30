import Foundation
import OffsiderCore

/// Hardware buttons Android has: `home` and `lock` (the power key) in this build.
enum AndroidButtonMap {
    static func keyCode(for button: HardwareButton) -> Int? {
        switch button {
        case .home: return 3
        case .lock: return 26
        case .applePay, .sideButton, .siri: return nil
        }
    }

    /// The W3C key value the emulator's gRPC `sendKey` takes.
    static func w3cKey(for button: HardwareButton) -> String? {
        switch button {
        case .home: return "GoHome"
        case .lock: return "Power"
        case .applePay, .sideButton, .siri: return nil
        }
    }

    static func requireKeyCode(for button: HardwareButton) throws -> Int {
        guard let code = keyCode(for: button) else { throw AndroidError.unsupportedButton(button) }
        return code
    }
}
