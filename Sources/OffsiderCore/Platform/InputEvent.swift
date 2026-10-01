import Foundation

public enum InputDirection: Equatable, Sendable {
    case down
    case up
}

/// Exactly the five hardware buttons idb supports.
public enum HardwareButton: String, CaseIterable, Equatable, Sendable {
    case applePay
    case home
    case lock
    case sideButton
    case siri
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
