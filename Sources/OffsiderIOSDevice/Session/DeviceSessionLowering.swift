import Foundation
import OffsiderCore

/// One part of an `InputEvent` and where it goes: the broker's touch, key or button requests, the runner, or a pause.
enum DeviceSessionAction: Equatable {
    case touch([DeviceSessionStep])
    case keys([DeviceSessionStep])
    case press(HardwareButton)
    case button(HardwareButton, DeviceSessionRequest.ButtonState)
    /// Touches when the broker does not send them, in UI points as the event carried them.
    case runner(InputEvent)
    case wait(TimeInterval)
}

/// Lowers `InputEvent`s for the broker; holds the one contact across events, so a held touch moves until it lifts.
struct DeviceSessionLowering {
    static let tapHold: TimeInterval = 0.06
    /// idb's swipe step when the caller gives none.
    static let defaultSwipeDelta: Double = 10

    /// False sends touches to the runner as the events carried them.
    let brokerTouches: Bool
    private var touching = false

    init(brokerTouches: Bool) {
        self.brokerTouches = brokerTouches
    }

    /// Adjacent touch steps and pauses merge into one request, so a gesture's timing runs in the broker.
    mutating func actions(for event: InputEvent) throws -> [DeviceSessionAction] {
        var actions: [DeviceSessionAction] = []
        for part in try parts(of: event) {
            switch (actions.last, part) {
            case let (.touch(earlier)?, .touch(steps)):
                actions[actions.count - 1] = .touch(earlier + steps)
            case let (.keys(earlier)?, .keys(steps)):
                actions[actions.count - 1] = .keys(earlier + steps)
            default:
                actions.append(part)
            }
        }
        return actions
    }

    private mutating func parts(of event: InputEvent) throws -> [DeviceSessionAction] {
        switch event {
        case .tapAt(let x, let y):
            guard brokerTouches else { return [.runner(event)] }
            return [.touch(contact(x, y, down: true) + [.wait(Self.tapHold)] + contact(x, y, down: false))]
        case .touch(let direction, let x, let y):
            guard brokerTouches else { return [.runner(event)] }
            return [.touch(contact(x, y, down: direction == .down))]
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            guard brokerTouches else { return [.runner(event)] }
            return [.touch(swipe(from: (xStart, yStart), to: (xEnd, yEnd), delta: delta, duration: duration))]
        case .shortButtonPress(let button):
            _ = try button.requireDeviceUsage()
            return [.press(button)]
        case .button(let direction, let button):
            _ = try button.requireDeviceUsage()
            return [.button(button, direction == .down ? .down : .up)]
        case .keyboard, .shortKeyPress:
            return [.keys(try Self.keySteps(for: event))]
        case .delay(let seconds):
            guard seconds > 0 else { return [] }
            // A pause with a contact down belongs to the touch, so the broker keeps the contact alive through it.
            return touching ? [.touch([.wait(seconds)])] : [.wait(seconds)]
        case .composite(let events):
            var all: [DeviceSessionAction] = []
            for event in events { all += try parts(of: event) }
            return all
        }
    }

    /// Key presses and pauses only.
    static func keySteps(for event: InputEvent) throws -> [DeviceSessionStep] {
        switch event {
        case .keyboard(let direction, let code):
            return [.key(code, down: direction == .down)]
        case .shortKeyPress(let code):
            return [.key(code, down: true), .key(code, down: false)]
        case .delay(let seconds):
            return seconds > 0 ? [.wait(seconds)] : []
        case .composite(let events):
            return try events.flatMap { try keySteps(for: $0) }
        case .tapAt, .touch, .swipe, .button, .shortButtonPress:
            throw IOSDeviceError(.sessionFailed, "Only key presses and pauses can go in a key request.")
        }
    }

    /// US keyboard text as key presses; anything else is refused before a key is sent.
    static func keySteps(typing text: String) throws -> [DeviceSessionStep] {
        try keySteps(for: .composite(try TextToHIDEvents.convertTextToHIDEvents(text)))
    }

    private mutating func contact(_ x: Double, _ y: Double, down: Bool) -> [DeviceSessionStep] {
        let kind: DeviceSessionStep.Kind = down ? (touching ? .move : .down) : .up
        touching = down
        return [.touch(kind, x: x, y: y)]
    }

    /// Down, a position every `duration / steps`, then up at the last point.
    private mutating func swipe(from start: (Double, Double), to end: (Double, Double), delta: Double, duration: Double) -> [DeviceSessionStep] {
        let distance = ((end.0 - start.0) * (end.0 - start.0) + (end.1 - start.1) * (end.1 - start.1)).squareRoot()
        let count = max(1, Int(distance / (delta > 0 ? delta : Self.defaultSwipeDelta)))
        let pause = max(duration, 0) / Double(count)
        var steps = contact(start.0, start.1, down: true)
        for index in 1...count {
            let progress = Double(index) / Double(count)
            if pause > 0 { steps.append(.wait(pause)) }
            steps += contact(start.0 + (end.0 - start.0) * progress, start.1 + (end.1 - start.1) * progress, down: true)
        }
        return steps + contact(end.0, end.1, down: false)
    }
}
