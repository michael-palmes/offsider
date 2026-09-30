import Foundation

public enum InputDirection: Equatable, Sendable {
    case down
    case up
}

/// Hardware buttons across platforms; `lock` is the power key on Android.
public enum HardwareButton: String, CaseIterable, Equatable, Sendable {
    case applePay
    case home
    case lock
    case sideButton
    case siri
    case back
    case appSwitch
    case volumeUp
    case volumeDown

    public var platforms: Set<DevicePlatform> {
        switch self {
        case .home, .lock: return [.ios, .android]
        case .applePay, .sideButton, .siri: return [.ios]
        case .back, .appSwitch, .volumeUp, .volumeDown: return [.android]
        }
    }
}

/// Intent-level input. Coordinates are already in the backend's input space (iOS: portrait HID points).
public indirect enum InputEvent: Equatable, Sendable {
    case tapAt(x: Double, y: Double)
    case touch(direction: InputDirection, x: Double, y: Double)
    case swipe(Double, yStart: Double, xEnd: Double, yEnd: Double, delta: Double, duration: Double)
    case button(direction: InputDirection, button: HardwareButton)
    case shortButtonPress(HardwareButton)
    case keyboard(direction: InputDirection, keyCode: UInt32)
    case shortKeyPress(UInt32)
    case delay(TimeInterval)
    case composite([InputEvent])
}
