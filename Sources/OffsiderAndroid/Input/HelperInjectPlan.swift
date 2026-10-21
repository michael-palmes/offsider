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
    /// The helper's own time around a resting move (its sleep's overrun and the inject), about 2 ms on an emulator, taken off the pause before it.
    static let restingMoveCostMilliseconds = 2

    struct Request: Equatable, Sendable {
        var steps: [HelperValue] = []
        /// Pauses and swipes, which the helper's 60 s request limit counts.
        var waitMilliseconds = 0
        /// The estimated time to inject the request's key events.
        var typingMilliseconds = 0
        var textCharacters = 0
        /// Whether the helper waits for the app to handle each event; a timed touch goes without, as the helper's swipe moves do, so it keeps its length.
        var sync = true

        /// Device-side time the caller adds to the request timeout.
        var deviceMilliseconds: Int { waitMilliseconds + typingMilliseconds }

        /// Touch phases and pauses alone, with at least one pause.
        var isTimedTouch: Bool {
            let kinds = steps.map(Self.kind)
            return kinds.contains("pause") && kinds.allSatisfy { $0 == "touch" || $0 == "pause" }
        }

        static func kind(of step: HelperValue) -> String? {
            guard case .object(let fields) = step, case .string(let kind)? = fields["kind"] else { return nil }
            return kind
        }

        /// A rest before the lift goes with the lift in a request that waits, so the reply follows the lift; a lift straight after a move stays behind it, as a fling needs.
        func confirmingLift() -> [Request] {
            guard !sync, let restStart = Self.restBeforeLift(steps) else { return [self] }
            let tail = Request(steps: Array(steps[restStart...]), waitMilliseconds: Self.pauseMilliseconds(steps[restStart...]))
            guard restStart > 0 else { return [tail] }
            return [Request(steps: Array(steps[..<restStart]), waitMilliseconds: Self.pauseMilliseconds(steps[..<restStart]), sync: false), tail]
        }

        /// The first step's pause made `milliseconds` shorter, never below zero, so a round trip just before this request does not lengthen it.
        mutating func shortenLeadingPause(by milliseconds: Int) {
            guard milliseconds > 0, let ms = steps.first.flatMap(Self.pause) else { return }
            let shorter = max(0, ms - milliseconds)
            steps[0] = .object(["kind": .string("pause"), "ms": .int(shorter)])
            waitMilliseconds -= ms - shorter
        }

        /// Where the pauses just before the closing lifts begin; nil when the steps do not end in a lift, or nothing rests before it.
        private static func restBeforeLift(_ steps: [HelperValue]) -> Int? {
            var start = steps.endIndex
            while start > steps.startIndex, isLift(steps[start - 1]) {
                start -= 1
            }
            guard start < steps.endIndex else { return nil }
            let lifts = start
            while start > steps.startIndex, pause(steps[start - 1]) != nil {
                start -= 1
            }
            return start < lifts ? start : nil
        }

        private static func isLift(_ step: HelperValue) -> Bool {
            guard case .object(let fields) = step, case .string("touch")? = fields["kind"], case .string("up")? = fields["phase"] else { return false }
            return true
        }

        private static func pause(_ step: HelperValue) -> Int? {
            guard case .object(let fields) = step, case .string("pause")? = fields["kind"], case .int(let ms)? = fields["ms"] else { return nil }
            return ms
        }

        private static func pauseMilliseconds(_ steps: ArraySlice<HelperValue>) -> Int {
            steps.compactMap(pause).reduce(0, +)
        }
    }

    /// `held` carries the modifiers down across calls in one session, so later keys carry their meta state.
    static func requests(for steps: [AndroidInputStep], held: inout Set<UInt32>) throws -> [Request] {
        var builder = Builder()
        var fingers: [AndroidPoint] = []
        for (index, step) in steps.enumerated() {
            switch step {
            case .tap(let point):
                builder.add(["kind": .string("tap"), "x": .double(point.x), "y": .double(point.y)])
            case let .swipe(from, to, duration, count):
                let ms = AndroidInputStep.milliseconds(duration)
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
                builder.add(touch(name, point, pointer: 0))
                fingers = phase == .up ? [] : [point]
            case .touches(let phase, let points):
                let name = phase == .down ? "down" : phase == .move ? "move" : "up"
                let numbered = Array(points.enumerated())
                for (pointer, point) in phase == .up ? numbered.reversed() : numbered {
                    builder.add(touch(name, point, pointer: pointer))
                }
                fingers = phase == .up ? [] : points
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
                var left = AndroidInputStep.milliseconds(seconds)
                if index + 1 < steps.count, steps[index + 1].restsAt(fingers) {
                    left = max(0, left - restingMoveCostMilliseconds)
                }
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

    private static func touch(_ phase: String, _ point: AndroidPoint, pointer: Int) -> [String: HelperValue] {
        ["kind": .string("touch"), "phase": .string(phase), "x": .double(point.x), "y": .double(point.y), "pointer": .int(pointer)]
    }

    private static func key(_ phase: KeyPhase, code: Int, meta: UInt32) -> [String: HelperValue] {
        let name = phase == .down ? "down" : phase == .up ? "up" : "press"
        return ["kind": .string("key"), "phase": .string(name), "code": .int(code), "meta": .int(Int(meta))]
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

        /// Timed touches go without waiting; only the last request confirms its lift, so a long hold split by the limits never waits midway.
        mutating func finish() -> [Request] {
            var requests = current.steps.isEmpty ? done : done + [current]
            for index in requests.indices where requests[index].isTimedTouch {
                requests[index].sync = false
            }
            guard let last = requests.popLast() else { return requests }
            return requests + last.confirmingLift()
        }
    }
}

