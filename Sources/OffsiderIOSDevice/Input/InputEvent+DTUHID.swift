import Foundation
import OffsiderCore

/// One step of device input: a message on the socket for its feature, or a pause.
public enum DTUHIDStep: Equatable, Sendable {
    case send(DTUHIDValue, feature: String)
    case wait(TimeInterval)
}

/// Lowers `InputEvent`s in panel points to device `dtuhidd` messages; holds the one contact across events.
public struct DTUHIDLowering: Sendable {
    public static let tapHold: TimeInterval = 0.06
    /// idb's swipe step when the caller gives none.
    public static let defaultSwipeDelta: Double = 10

    public let panel: IOSDevicePanel
    private var contact = DTUHIDContact()

    public init(panel: IOSDevicePanel) {
        self.panel = panel
    }

    public mutating func steps(for event: InputEvent) throws -> [DTUHIDStep] {
        switch event {
        case let .tapAt(x, y):
            return touch(x, y, down: true) + [.wait(Self.tapHold)] + touch(x, y, down: false)
        case let .touch(direction, x, y):
            return touch(x, y, down: direction == .down)
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            return swipe(from: (xStart, yStart), to: (xEnd, yEnd), delta: delta, duration: duration)
        case let .button(direction, button):
            return [press(direction == .down ? .down : .up, usage: try button.requireDeviceUsage())]
        case let .shortButtonPress(button):
            let usage = try button.requireDeviceUsage()
            return [press(.down, usage: usage), .wait(button.deviceShortPressHold), press(.up, usage: usage)]
        case let .keyboard(direction, keyCode):
            return [key(keyCode, direction == .down ? .down : .up)]
        case let .shortKeyPress(keyCode):
            return [key(keyCode, .down), key(keyCode, .up)]
        case let .delay(seconds):
            return seconds > 0 ? [.wait(seconds)] : []
        case let .composite(events):
            var steps: [DTUHIDStep] = []
            for event in events {
                steps += try self.steps(for: event)
            }
            return steps
        }
    }

    private mutating func touch(_ x: Double, _ y: Double, down: Bool) -> [DTUHIDStep] {
        let fraction = panel.fraction(x: x, y: y)
        let phase = contact.phase(touchingDown: down)
        return [.send(DTUHIDMessage.touch(x: fraction.x, y: fraction.y, phase: phase, target: 0), feature: DTUHIDMessage.digitizerService)]
    }

    /// Start, a position every `duration / steps`, then end at the last point.
    private mutating func swipe(from start: (Double, Double), to end: (Double, Double), delta: Double, duration: Double) -> [DTUHIDStep] {
        let distance = ((end.0 - start.0) * (end.0 - start.0) + (end.1 - start.1) * (end.1 - start.1)).squareRoot()
        let count = max(1, Int(distance / (delta > 0 ? delta : Self.defaultSwipeDelta)))
        let pause = max(duration, 0) / Double(count)
        var steps = touch(start.0, start.1, down: true)
        for index in 1...count {
            let progress = Double(index) / Double(count)
            if pause > 0 { steps.append(.wait(pause)) }
            steps += touch(start.0 + (end.0 - start.0) * progress, start.1 + (end.1 - start.1) * progress, down: true)
        }
        return steps + touch(end.0, end.1, down: false)
    }

    private func key(_ code: UInt32, _ state: DTUHIDMessage.ButtonState) -> DTUHIDStep {
        .send(DTUHIDMessage.keyboard(usage: UInt64(code), state: state), feature: DTUHIDMessage.keyboardService)
    }

    private func press(_ state: DTUHIDMessage.ButtonState, usage: UInt64) -> DTUHIDStep {
        .send(DTUHIDMessage.button(usagePage: DTUHIDMessage.consumerUsagePage, usage: usage, state: state), feature: DTUHIDMessage.buttonService)
    }
}
