import FBSimulatorControl
import OffsiderCore

extension InputDirection {
    var hidDirection: FBSimulatorHIDDirection {
        switch self {
        case .down: return .down
        case .up: return .up
        }
    }
}

extension HardwareButton {
    var hidButton: FBSimulatorHIDButton {
        switch self {
        case .applePay: return FBSimulatorHIDButton(rawValue: 1)!
        case .home: return FBSimulatorHIDButton(rawValue: 2)!
        case .lock: return FBSimulatorHIDButton(rawValue: 3)!
        case .sideButton: return FBSimulatorHIDButton(rawValue: 4)!
        case .siri: return FBSimulatorHIDButton(rawValue: 5)!
        }
    }
}

extension InputEvent {
    var hidEvent: FBSimulatorHIDEvent {
        switch self {
        case let .tapAt(x, y):
            return .tapAt(x: x, y: y)
        case let .touch(direction, x, y):
            return .touch(direction: direction.hidDirection, x: x, y: y)
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            return .swipe(xStart, yStart: yStart, xEnd: xEnd, yEnd: yEnd, delta: delta, duration: duration)
        case let .button(direction, button):
            return .button(direction: direction.hidDirection, button: button.hidButton)
        case let .shortButtonPress(button):
            return .shortButtonPress(button.hidButton)
        case let .keyboard(direction, keyCode):
            return .keyboard(direction: direction.hidDirection, keyCode: keyCode)
        case let .shortKeyPress(keyCode):
            return .shortKeyPress(keyCode)
        case let .delay(seconds):
            return .delay(seconds)
        case let .composite(events):
            return .composite(events.map(\.hidEvent))
        }
    }
}
