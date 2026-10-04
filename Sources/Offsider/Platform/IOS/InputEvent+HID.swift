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
    /// Nil for Android-only buttons, which the simulator has no HID button for.
    var hidButton: FBSimulatorHIDButton? {
        switch self {
        case .applePay: return FBSimulatorHIDButton(rawValue: 1)
        case .home: return FBSimulatorHIDButton(rawValue: 2)
        case .lock: return FBSimulatorHIDButton(rawValue: 3)
        case .sideButton: return FBSimulatorHIDButton(rawValue: 4)
        case .siri: return FBSimulatorHIDButton(rawValue: 5)
        case .back, .appSwitch, .volumeUp, .volumeDown: return nil
        }
    }

    func requireHIDButton() throws -> FBSimulatorHIDButton {
        guard let hidButton else {
            let name = ButtonType.allCases.first { $0.hardwareButton == self }?.rawValue ?? rawValue
            throw CLIError(errorDescription: "The \(name) button is Android only. iOS buttons: \(ButtonType.names(on: .ios)).", reason: .unsupportedButton)
        }
        return hidButton
    }
}

extension InputEvent {
    func hidEvent() throws -> FBSimulatorHIDEvent {
        switch self {
        case let .tapAt(x, y):
            return .tapAt(x: x, y: y)
        case let .touch(direction, x, y):
            return .touch(direction: direction.hidDirection, x: x, y: y)
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            return .swipe(xStart, yStart: yStart, xEnd: xEnd, yEnd: yEnd, delta: delta, duration: duration)
        case let .button(direction, button):
            return .button(direction: direction.hidDirection, button: try button.requireHIDButton())
        case let .shortButtonPress(button):
            return .shortButtonPress(try button.requireHIDButton())
        case let .keyboard(direction, keyCode):
            return .keyboard(direction: direction.hidDirection, keyCode: keyCode)
        case let .shortKeyPress(keyCode):
            return .shortKeyPress(keyCode)
        case let .delay(seconds):
            return .delay(seconds)
        case let .composite(events):
            return .composite(try events.map { try $0.hidEvent() })
        }
    }
}
