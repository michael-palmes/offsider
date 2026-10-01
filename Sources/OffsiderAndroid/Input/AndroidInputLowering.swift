import Foundation
import OffsiderCore

struct AndroidPoint: Equatable, Sendable {
    var x: Double
    var y: Double
}

enum TouchPhase: Equatable, Sendable {
    case down
    case move
    case up
}

enum KeyPhase: Equatable, Sendable {
    case down
    case up
    case press
}

/// Intent steps in logical pixels; built by `AndroidInputLowering`, run by one executor.
enum AndroidInputStep: Equatable, Sendable {
    case touch(TouchPhase, AndroidPoint)
    case tap(AndroidPoint)
    case swipe(from: AndroidPoint, to: AndroidPoint, duration: TimeInterval, steps: Int)
    case key(KeyPhase, usage: UInt32)
    case button(KeyPhase, HardwareButton)
    case pause(TimeInterval)
}

enum AndroidInputLowering {
    /// `touchIsDown` carries finger state across calls in one session: a `.touch(.down)` while down is a move.
    /// Every key and button is checked before any step is returned, so a bad code never half-runs a composite.
    static func steps(for event: InputEvent, touchIsDown: inout Bool, scale: Double) throws -> [AndroidInputStep] {
        switch event {
        case .tapAt(let x, let y):
            return [.tap(AndroidPoint(x: x, y: y))]
        case .touch(.down, let x, let y):
            defer { touchIsDown = true }
            return [.touch(touchIsDown ? .move : .down, AndroidPoint(x: x, y: y))]
        case .touch(.up, let x, let y):
            touchIsDown = false
            return [.touch(.up, AndroidPoint(x: x, y: y))]
        case let .swipe(xStart, yStart, xEnd, yEnd, delta, duration):
            let distance = hypot(xEnd - xStart, yEnd - yStart)
            let spacing = delta * scale
            let count = spacing > 0 ? max(1, Int((distance / spacing).rounded(.up))) : 1
            return [.swipe(from: AndroidPoint(x: xStart, y: yStart), to: AndroidPoint(x: xEnd, y: yEnd), duration: duration, steps: count)]
        case .button(let direction, let button):
            _ = try AndroidButtonMap.requireKeyCode(for: button)
            return [.button(direction == .down ? .down : .up, button)]
        case .shortButtonPress(let button):
            _ = try AndroidButtonMap.requireKeyCode(for: button)
            return [.button(.press, button)]
        case .keyboard(let direction, let usage):
            _ = try AndroidKeyTable.requireKeyCode(for: usage)
            return [.key(direction == .down ? .down : .up, usage: usage)]
        case .shortKeyPress(let usage):
            _ = try AndroidKeyTable.requireKeyCode(for: usage)
            return [.key(.press, usage: usage)]
        case .delay(let seconds):
            return seconds > 0 ? [.pause(seconds)] : []
        case .composite(let events):
            var steps: [AndroidInputStep] = []
            for event in events {
                steps += try self.steps(for: event, touchIsDown: &touchIsDown, scale: scale)
            }
            return steps
        }
    }
}
