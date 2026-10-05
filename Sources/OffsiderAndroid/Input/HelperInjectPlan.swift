import Foundation
import OffsiderCore

/// Steps as helper `inject` requests, in logical pixels like `input`; the twin of `AdbInputScript`.
enum HelperInjectPlan {
    /// The helper's own limits: a step waits at most 30 s, a request at most 60 s, and holds at most 2,000 steps.
    static let maxStepMilliseconds = 30_000
    static let maxRequestMilliseconds = 60_000
    static let maxSteps = 2_000
    static let maxMoves = 1_000

    struct Request: Equatable, Sendable {
        var steps: [HelperValue] = []
        /// Device-side waiting, so the caller can give the request enough time.
        var waitMilliseconds = 0
    }

    /// `held` carries the modifiers down across calls in one session, so later keys carry their meta state.
    static func requests(for steps: [AndroidInputStep], held: inout Set<UInt32>) throws -> [Request] {
        var builder = Builder()
        for step in steps {
            switch step {
            case .tap(let point):
                builder.add(["kind": .string("tap"), "x": .double(point.x), "y": .double(point.y)])
            case let .swipe(from, to, duration, count):
                let ms = milliseconds(duration)
                guard ms <= maxStepMilliseconds else {
                    throw AndroidError.notSupported("A swipe longer than 30 s through the UiAutomation helper")
                }
                builder.add([
                    "kind": .string("swipe"),
                    "fromX": .double(from.x), "fromY": .double(from.y), "toX": .double(to.x), "toY": .double(to.y),
                    "durationMs": .int(ms), "moves": .int(min(max(1, count), maxMoves)),
                ], waiting: ms)
            case .touch(let phase, let point):
                let name = phase == .down ? "down" : phase == .move ? "move" : "up"
                builder.add(["kind": .string("touch"), "phase": .string(name), "x": .double(point.x), "y": .double(point.y), "pointer": .int(0)])
            case let .key(phase, usage):
                let code = try AndroidKeyTable.requireKeyCode(for: usage)
                if AndroidKeyMeta.bits(for: usage) != nil {
                    switch phase {
                    case .down: held.insert(usage)
                    case .up: held.remove(usage)
                    case .press: break
                    }
                }
                builder.add(key(phase, code: code, meta: AndroidKeyMeta.state(holding: held)))
            case let .button(phase, button):
                builder.add(key(phase, code: try AndroidButtonMap.requireKeyCode(for: button), meta: AndroidKeyMeta.state(holding: held)))
            case .pause(let seconds):
                var left = milliseconds(seconds)
                while left > 0 {
                    let part = min(left, maxStepMilliseconds)
                    builder.add(["kind": .string("pause"), "ms": .int(part)], waiting: part)
                    left -= part
                }
            }
        }
        return builder.finish()
    }

    /// ASCII runs as `text` steps (the helper maps them through the virtual keyboard), Return and Tab as key presses.
    static func requests(for chunks: [AndroidTextPlan.Chunk]) throws -> [Request] {
        var builder = Builder()
        for chunk in chunks {
            switch chunk {
            case .text(let run):
                builder.add(["kind": .string("text"), "text": .string(run)])
            case .key(let usage):
                builder.add(key(.press, code: try AndroidKeyTable.requireKeyCode(for: usage), meta: 0))
            }
        }
        return builder.finish()
    }

    private static func key(_ phase: KeyPhase, code: Int, meta: UInt32) -> [String: HelperValue] {
        let name = phase == .down ? "down" : phase == .up ? "up" : "press"
        return ["kind": .string("key"), "phase": .string(name), "code": .int(code), "meta": .int(Int(meta))]
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000).rounded()))
    }

    /// Starts a new request when the next step would pass the step count or the wait limit.
    private struct Builder {
        var done: [Request] = []
        var current = Request()

        mutating func add(_ step: [String: HelperValue], waiting ms: Int = 0) {
            if !current.steps.isEmpty, current.steps.count == maxSteps || current.waitMilliseconds + ms > maxRequestMilliseconds {
                done.append(current)
                current = Request()
            }
            current.steps.append(.object(step))
            current.waitMilliseconds += ms
        }

        mutating func finish() -> [Request] {
            current.steps.isEmpty ? done : done + [current]
        }
    }
}
