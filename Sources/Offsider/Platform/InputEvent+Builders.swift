import Foundation
import OffsiderCore

extension InputEvent {
    /// `[delay(pre)?, main, delay(post)?]` as a composite, or `main` alone when neither delay is positive.
    static func delayed(_ main: InputEvent, pre: Double?, post: Double?) -> InputEvent {
        var events: [InputEvent] = []
        if let pre, pre > 0 {
            events.append(.delay(pre))
        }
        events.append(main)
        if let post, post > 0 {
            events.append(.delay(post))
        }
        return events.count == 1 ? events[0] : .composite(events)
    }

    /// Touch down, hold, `steps` evenly spaced moves over `duration`, hold, touch up; `settling` slows the last moves, as below.
    static func compositeDrag(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        finalHold: TimeInterval,
        settling: Bool = false
    ) throws -> InputEvent {
        guard finalHold >= 0 else {
            throw CLIError(errorDescription: "Drag hold durations must be non-negative.", reason: .usage)
        }
        var events = try pressEvents(from: start, to: end, duration: duration, steps: steps, initialHold: initialHold, settling: settling)
        events.append(.delay(finalHold))
        events.append(.touch(direction: .up, x: end.x, y: end.y))
        return .composite(events)
    }

    /// Both fingers down at the first frame, moved through the rest over `duration`, then lifted together; a later down while both are down is a move.
    static func compositePinch(frames: [(first: (x: Double, y: Double), second: (x: Double, y: Double))], duration: TimeInterval) -> InputEvent {
        guard let start = frames.first, let end = frames.last else { return .composite([]) }
        let pause = frames.count > 1 ? duration / Double(frames.count - 1) : 0
        var events: [InputEvent] = [.twoFingerTouch(direction: .down, x1: start.first.x, y1: start.first.y, x2: start.second.x, y2: start.second.y)]
        for frame in frames.dropFirst() {
            events.append(.delay(pause))
            events.append(.twoFingerTouch(direction: .down, x1: frame.first.x, y1: frame.first.y, x2: frame.second.x, y2: frame.second.y))
        }
        events.append(.twoFingerTouch(direction: .up, x1: end.first.x, y1: end.first.y, x2: end.second.x, y2: end.second.y))
        return .composite(events)
    }

    /// `compositeDrag` up to its end hold: touch down, hold, the moves, leaving the finger down at `end`.
    static func compositeDragPress(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        settling: Bool = false
    ) throws -> InputEvent {
        .composite(try pressEvents(from: start, to: end, duration: duration, steps: steps, initialHold: initialHold, settling: settling))
    }

    private static func pressEvents(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        settling: Bool
    ) throws -> [InputEvent] {
        guard duration >= 0 else {
            throw CLIError(errorDescription: "Drag duration must be non-negative.", reason: .usage)
        }
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.", reason: .usage)
        }
        guard initialHold >= 0 else {
            throw CLIError(errorDescription: "Drag hold durations must be non-negative.", reason: .usage)
        }

        var events: [InputEvent] = [
            .touch(direction: .down, x: start.x, y: start.y),
            .delay(initialHold)
        ]
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard settling, distance > settleDistance else {
            events += moves(from: start, to: end, duration: duration, steps: steps)
            return events
        }
        let fraction = settleDistance / distance
        let approach = (x: end.x - (end.x - start.x) * fraction, y: end.y - (end.y - start.y) * fraction)
        let slow = min(settleDuration, duration / 2)
        events += moves(from: start, to: approach, duration: duration - slow, steps: min(steps, PixelMath.maxSwipeSteps - settleSteps))
        events += moves(from: approach, to: end, duration: slow, steps: settleSteps)
        return events
    }

    /// The last stretch of a drag that stops: a finger held still sends no new moves, so the speed a list reads at the lift is that of these, however long the hold.
    private static let settleDistance = 3.0
    private static let settleDuration: TimeInterval = 0.15
    private static let settleSteps = 8

    private static func moves(from start: (x: Double, y: Double), to end: (x: Double, y: Double), duration: TimeInterval, steps: Int) -> [InputEvent] {
        let stepDelay = duration / Double(steps)
        return (1...steps).flatMap { step -> [InputEvent] in
            let progress = Double(step) / Double(steps)
            return [.delay(stepDelay), .touch(direction: .down, x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)]
        }
    }

    static func compositeDragMovePoints(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        steps: Int
    ) throws -> [(x: Double, y: Double)] {
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.", reason: .usage)
        }

        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            return (
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
        }
    }
}
