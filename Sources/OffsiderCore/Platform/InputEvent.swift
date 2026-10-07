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
    /// Two fingers down or up together, at (x1, y1) and (x2, y2).
    case twoFingerTouch(direction: InputDirection, x1: Double, y1: Double, x2: Double, y2: Double)
    case swipe(Double, yStart: Double, xEnd: Double, yEnd: Double, delta: Double, duration: Double)
    case button(direction: InputDirection, button: HardwareButton)
    case shortButtonPress(HardwareButton)
    case keyboard(direction: InputDirection, keyCode: UInt32)
    case shortKeyPress(UInt32)
    case delay(TimeInterval)
    case composite([InputEvent])
}

extension InputEvent {
    /// The largest coordinate magnitude any backend is sent, in its points or pixels; no screen comes near it.
    public static let coordinateLimit = 100_000.0
    /// The longest hold, swipe or pause one event may ask for, in seconds.
    public static let durationLimit: TimeInterval = 3600

    /// Why no device could act on this event's numbers (not finite, or an absurd coordinate or time); nil when all are usable.
    public var unusableNumber: String? {
        switch self {
        case let .tapAt(x, y), let .touch(_, x, y):
            return Self.unusable(coordinates: [("x", x), ("y", y)])
        case let .twoFingerTouch(_, x1, y1, x2, y2):
            return Self.unusable(coordinates: [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)])
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            return Self.unusable(coordinates: [("start x", xStart), ("start y", yStart), ("end x", xEnd), ("end y", yEnd), ("delta", delta)])
                ?? Self.unusable(duration: duration, named: "duration")
        case .delay(let seconds):
            return Self.unusable(duration: seconds, named: "pause")
        case .composite(let events):
            return events.lazy.compactMap(\.unusableNumber).first
        case .button, .shortButtonPress, .keyboard, .shortKeyPress:
            return nil
        }
    }

    private static func unusable(coordinates: [(name: String, value: Double)]) -> String? {
        coordinates.first { !$0.value.isFinite || abs($0.value) > coordinateLimit }
            .map { "\($0.name) \($0.value) is not a coordinate within ±\(Int(coordinateLimit))" }
    }

    private static func unusable(duration seconds: Double, named name: String) -> String? {
        seconds.isFinite && (0...durationLimit).contains(seconds) ? nil : "\(name) \(seconds) s is not between 0 and \(Int(durationLimit)) s"
    }
}
