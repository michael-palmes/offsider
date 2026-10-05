import Foundation
import OffsiderCore

/// One part of an `InputEvent` and where it goes: the broker's touch, key or button requests, the runner, or a pause.
enum DeviceSessionAction: Equatable {
    case touch([DeviceSessionStep])
    case keys([DeviceSessionStep])
    /// Down, a hold timed in the broker, then up.
    case press(HardwareButton, hold: TimeInterval)
    /// Touches when the broker does not send them, in UI points as the event carried them.
    case runner(InputEvent)
    case wait(TimeInterval)
}

/// Lowers `InputEvent`s for the broker. A touch, key or button held down goes to the broker in one request with its
/// pauses and its release, since the broker releases everything a request leaves held; nothing stays down between events.
struct DeviceSessionLowering {
    static let tapHold: TimeInterval = 0.06
    /// idb's swipe step when the caller gives none.
    static let defaultSwipeDelta: Double = 10

    /// False sends touches to the runner as the events carried them.
    let brokerTouches: Bool
    private var touching = false
    private var heldKeys: Set<UInt32> = []
    private var heldButton: (button: HardwareButton, hold: TimeInterval)?

    init(brokerTouches: Bool) {
        self.brokerTouches = brokerTouches
    }

    /// Adjacent touch steps, key steps and the pauses while they are held merge into one request each.
    mutating func actions(for event: InputEvent) throws -> [DeviceSessionAction] {
        touching = false
        heldKeys = []
        heldButton = nil
        var actions: [DeviceSessionAction] = []
        for leaf in Self.leaves(of: event) {
            let holding = (touch: touching, keys: !heldKeys.isEmpty)
            guard let part = try part(for: leaf) else { continue }
            switch (actions.last, part) {
            case let (.touch(earlier)?, .touch(steps)):
                actions[actions.count - 1] = .touch(earlier + steps)
            case let (.keys(earlier)?, .keys(steps)):
                actions[actions.count - 1] = .keys(earlier + steps)
            default:
                if holding.touch || holding.keys { throw Self.heldAcrossRequests }
                actions.append(part)
            }
        }
        guard !touching, heldKeys.isEmpty, heldButton == nil else { throw Self.heldAcrossRequests }
        return actions
    }

    static let heldAcrossRequests = IOSDeviceError.notSupportedOnDevice(
        "A touch, key or button that stays down between commands, or while other input is sent",
        instead: "Pass its down, hold and up in one command: `touch --down --up --delay`, `key --duration` or `button --duration`."
    )

    private static func leaves(of event: InputEvent) -> [InputEvent] {
        if case .composite(let events) = event { return events.flatMap(leaves) }
        return [event]
    }

    private mutating func part(for leaf: InputEvent) throws -> DeviceSessionAction? {
        if let held = heldButton {
            switch leaf {
            case .delay(let seconds):
                heldButton?.hold += max(seconds, 0)
                return nil
            case .button(.up, held.button):
                heldButton = nil
                return .press(held.button, hold: held.hold)
            default:
                throw Self.heldAcrossRequests
            }
        }
        switch leaf {
        case .tapAt(let x, let y):
            guard brokerTouches else { return .runner(leaf) }
            return .touch(try contact(x, y, down: true) + [.wait(Self.tapHold)] + contact(x, y, down: false))
        case .touch(let direction, let x, let y):
            guard brokerTouches else { return .runner(leaf) }
            return .touch(try contact(x, y, down: direction == .down))
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            guard brokerTouches else { return .runner(leaf) }
            return .touch(try swipe(from: (xStart, yStart), to: (xEnd, yEnd), delta: delta, duration: duration))
        case .shortButtonPress(let button):
            _ = try button.requireDeviceUsage()
            return .press(button, hold: button.deviceShortPressHold)
        case .button(let direction, let button):
            _ = try button.requireDeviceUsage()
            guard direction == .down else { throw Self.heldAcrossRequests }
            heldButton = (button, 0)
            return nil
        case .keyboard(let direction, let code):
            if direction == .down { heldKeys.insert(code) } else { heldKeys.remove(code) }
            return .keys([.key(code, down: direction == .down)])
        case .shortKeyPress(let code):
            return .keys([.key(code, down: true), .key(code, down: false)])
        case .delay(let seconds):
            guard seconds > 0 else { return nil }
            if touching { return .touch([.wait(seconds)]) }
            if !heldKeys.isEmpty { return .keys([.wait(seconds)]) }
            return .wait(seconds)
        case .composite:
            return nil
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

    /// A lift needs a contact down earlier in the same event.
    private mutating func contact(_ x: Double, _ y: Double, down: Bool) throws -> [DeviceSessionStep] {
        guard down || touching else { throw Self.heldAcrossRequests }
        let kind: DeviceSessionStep.Kind = down ? (touching ? .move : .down) : .up
        touching = down
        return [.touch(kind, x: x, y: y)]
    }

    /// Down, a position every `duration / steps`, then up at the last point.
    private mutating func swipe(from start: (Double, Double), to end: (Double, Double), delta: Double, duration: Double) throws -> [DeviceSessionStep] {
        let distance = ((end.0 - start.0) * (end.0 - start.0) + (end.1 - start.1) * (end.1 - start.1)).squareRoot()
        let count = max(1, Int(distance / (delta > 0 ? delta : Self.defaultSwipeDelta)))
        let pause = max(duration, 0) / Double(count)
        var steps = try contact(start.0, start.1, down: true)
        for index in 1...count {
            let progress = Double(index) / Double(count)
            if pause > 0 { steps.append(.wait(pause)) }
            steps += try contact(start.0 + (end.0 - start.0) * progress, start.1 + (end.1 - start.1) * progress, down: true)
        }
        return steps + (try contact(end.0, end.1, down: false))
    }
}
