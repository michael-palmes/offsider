import Foundation
import OffsiderCore

/// Steps as helper `inject` requests, in logical pixels like `input`; the twin of `AdbInputScript`.
enum HelperInjectPlan {
    /// The helper's own limits: a step waits at most 30 s, a request at most 60 s, and holds at most 2,000 steps.
    static let maxStepMilliseconds = 30_000
    static let maxRequestMilliseconds = 60_000
    static let maxSteps = 2_000
    static let maxMoves = 1_000
    /// The helper injects each key event synchronously; an estimate per event, so a request's timeout grows with its keys.
    static let keyEventMilliseconds = 8
    /// Text characters in one request, so one request's typing stays well inside its timeout.
    static let maxTextCharacters = AndroidTextPlan.maxChunkBytes

    struct Request: Equatable, Sendable {
        var steps: [HelperValue] = []
        /// Pauses and swipes, which the helper's 60 s request limit counts.
        var waitMilliseconds = 0
        /// The estimated time to inject the request's key events.
        var typingMilliseconds = 0
        var textCharacters = 0

        /// Device-side time the caller adds to the request timeout.
        var deviceMilliseconds: Int { waitMilliseconds + typingMilliseconds }
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
                builder.add(key(phase, code: code, meta: AndroidKeyMeta.state(holding: held)), typing: typingMilliseconds(phase))
            case let .button(phase, button):
                builder.add(
                    key(phase, code: try AndroidButtonMap.requireKeyCode(for: button), meta: AndroidKeyMeta.state(holding: held)),
                    typing: typingMilliseconds(phase)
                )
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

    /// ASCII runs as `text` steps and Return and Tab as key presses, with at most `maxTextCharacters` of text per request.
    static func requests(for chunks: [AndroidTextPlan.Chunk]) throws -> [Request] {
        var builder = Builder()
        for chunk in chunks {
            switch chunk {
            case .text(let run):
                var rest = Substring(run)
                while !rest.isEmpty {
                    let room = maxTextCharacters - builder.current.textCharacters
                    let part = rest.prefix(room > 0 ? room : maxTextCharacters)
                    rest = rest.dropFirst(part.count)
                    builder.add(["kind": .string("text"), "text": .string(String(part))], typing: typingMilliseconds(of: part), text: part.count)
                }
            case .key(let usage):
                builder.add(key(.press, code: try AndroidKeyTable.requireKeyCode(for: usage), meta: 0), typing: typingMilliseconds(.press))
            }
        }
        return builder.finish()
    }

    /// A press is a down and an up.
    private static func typingMilliseconds(_ phase: KeyPhase) -> Int {
        (phase == .press ? 2 : 1) * keyEventMilliseconds
    }

    /// The virtual keyboard sends a down and an up per character, wrapped in Shift down and up for a shifted one.
    static func typingMilliseconds(of text: Substring) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isShifted(scalar) ? 4 : 2) * keyEventMilliseconds
        }
    }

    private static func isShifted(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || #"~!@#$%^&*()_+{}|:"<>?"#.unicodeScalars.contains(scalar)
    }

    private static func key(_ phase: KeyPhase, code: Int, meta: UInt32) -> [String: HelperValue] {
        let name = phase == .down ? "down" : phase == .up ? "up" : "press"
        return ["kind": .string("key"), "phase": .string(name), "code": .int(code), "meta": .int(Int(meta))]
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000).rounded()))
    }

    /// Starts a new request when the next step would pass the step count, the wait limit or the text limit.
    private struct Builder {
        var done: [Request] = []
        var current = Request()

        mutating func add(_ step: [String: HelperValue], waiting ms: Int = 0, typing: Int = 0, text: Int = 0) {
            if !current.steps.isEmpty, current.steps.count == maxSteps
                || current.waitMilliseconds + ms > maxRequestMilliseconds
                || current.textCharacters + text > maxTextCharacters {
                done.append(current)
                current = Request()
            }
            current.steps.append(.object(step))
            current.waitMilliseconds += ms
            current.typingMilliseconds += typing
            current.textCharacters += text
        }

        mutating func finish() -> [Request] {
            current.steps.isEmpty ? done : done + [current]
        }
    }
}
