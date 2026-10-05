import Foundation
import OffsiderCore

/// Steps as device shell scripts for `input`; pauses run on the device with `sleep`, which takes fractions.
enum AdbInputScript {
    /// Scripts stay well under the 64 KB adb request limit.
    static let maxScriptLength = 8_000

    /// Modifier downs, a press and their ups become `input keycombination`; a held key becomes `--longpress`.
    static func scripts(for steps: [AndroidInputStep]) throws -> [String] {
        var commands: [String] = []
        var index = 0
        while index < steps.count {
            let (command, used) = try command(at: index, in: steps)
            commands.append(command)
            index += used
        }
        return pack(commands)
    }

    /// Total device-side waiting, so the caller can give the shell call enough time.
    static func waitTime(of steps: [AndroidInputStep]) -> TimeInterval {
        steps.reduce(0) { total, step in
            switch step {
            case .pause(let seconds): return total + seconds
            case .swipe(_, _, let duration, _): return total + duration
            default: return total
            }
        }
    }

    private static func command(at index: Int, in steps: [AndroidInputStep]) throws -> (String, Int) {
        switch steps[index] {
        case .tap(let point):
            return ("input tap \(pixels(point))", 1)
        case let .swipe(from, to, duration, _):
            return ("input swipe \(pixels(from)) \(pixels(to)) \(max(1, Int((duration * 1000).rounded())))", 1)
        case .touch(let phase, let point):
            let action = phase == .down ? "DOWN" : phase == .move ? "MOVE" : "UP"
            return ("input motionevent \(action) \(pixels(point))", 1)
        case .touches:
            throw AndroidError.twoFingersOverInput
        case .pause(let seconds):
            return ("sleep \(decimal(seconds))", 1)
        case .key(.press, let usage):
            return ("input keyevent \(try AndroidKeyTable.requireKeyCode(for: usage))", 1)
        case .button(.press, let button):
            return ("input keyevent \(try AndroidButtonMap.requireKeyCode(for: button))", 1)
        case .key(.down, _), .button(.down, _):
            if let combination = try keyCombination(at: index, in: steps) {
                return combination
            }
            if let held = try heldKey(at: index, in: steps) {
                return held
            }
            throw AndroidError.notSupported("Holding a key or button across other input over adb")
        case .key(.up, _), .button(.up, _):
            throw AndroidError.notSupported("Releasing a key or button that was not pressed in the same command over adb")
        }
    }

    /// `down(a)... press(k) up(a)...` with every down released: `input keycombination a... k`.
    private static func keyCombination(at index: Int, in steps: [AndroidInputStep]) throws -> (String, Int)? {
        var modifiers: [UInt32] = []
        var cursor = index
        while cursor < steps.count, case .key(.down, let usage) = steps[cursor] {
            modifiers.append(usage)
            cursor += 1
        }
        guard !modifiers.isEmpty, cursor < steps.count, case .key(.press, let key) = steps[cursor] else { return nil }
        cursor += 1
        var released: [UInt32] = []
        while cursor < steps.count, released.count < modifiers.count, case .key(.up, let usage) = steps[cursor] {
            released.append(usage)
            cursor += 1
        }
        guard released.sorted() == modifiers.sorted() else { return nil }
        let codes = try (modifiers + [key]).map { String(try AndroidKeyTable.requireKeyCode(for: $0)) }
        return ("input keycombination " + codes.joined(separator: " "), cursor - index)
    }

    /// `down(k)`, optional pauses, `up(k)`: a long press when held, else a plain press.
    private static func heldKey(at index: Int, in steps: [AndroidInputStep]) throws -> (String, Int)? {
        var cursor = index + 1
        var held: TimeInterval = 0
        while cursor < steps.count, case .pause(let seconds) = steps[cursor] {
            held += seconds
            cursor += 1
        }
        guard cursor < steps.count else { return nil }
        let code: Int
        switch (steps[index], steps[cursor]) {
        case let (.key(.down, down), .key(.up, up)) where down == up:
            code = try AndroidKeyTable.requireKeyCode(for: down)
        case let (.button(.down, down), .button(.up, up)) where down == up:
            code = try AndroidButtonMap.requireKeyCode(for: down)
        default:
            return nil
        }
        return (held > 0 ? "input keyevent --longpress \(code)" : "input keyevent \(code)", cursor + 1 - index)
    }

    private static func pack(_ commands: [String]) -> [String] {
        var scripts: [String] = []
        var current = ""
        for command in commands {
            if !current.isEmpty, current.count + command.count + 4 > maxScriptLength {
                scripts.append(current)
                current = ""
            }
            current += current.isEmpty ? command : " && " + command
        }
        if !current.isEmpty {
            scripts.append(current)
        }
        return scripts
    }

    /// Whole logical pixels: `input` takes floats, but fractions of a pixel only add noise.
    private static func pixels(_ point: AndroidPoint) -> String {
        "\(Int(point.x.rounded())) \(Int(point.y.rounded()))"
    }

    private static func decimal(_ seconds: TimeInterval) -> String {
        var text = String(format: "%.3f", seconds)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
