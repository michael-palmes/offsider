import Foundation
import OffsiderCore

extension HardwareButton {
    /// The consumer-page usage a device's `dtuhidd` presses for this button; nil when there is no single usage.
    var deviceUsage: UInt64? {
        switch self {
        case .home: return 0x40
        case .lock, .sideButton: return 0x30
        case .siri: return 0xCF
        case .applePay, .back, .appSwitch, .volumeUp, .volumeDown: return nil
        }
    }

    /// How long a short press holds the button: the side button ignores presses under 0.29 s and Siri needs a long one.
    var deviceShortPressHold: TimeInterval {
        switch self {
        case .lock, .sideButton: return 0.4
        case .siri: return 0.85
        default: return 0.08
        }
    }

    func requireDeviceUsage() throws -> UInt64 {
        if let usage = deviceUsage { return usage }
        if self == .applePay {
            throw IOSDeviceError.notSupportedOnDevice("The apple-pay button", instead: "Press the side button twice with `offsider button side-button` instead.")
        }
        throw IOSDeviceError(.unsupportedButton, "The \(rawValue) button is Android only. iOS buttons: home, lock, side-button, siri.")
    }
}
