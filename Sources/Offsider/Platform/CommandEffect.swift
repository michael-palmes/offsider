import Foundation

/// What a command may do to a device, which decides how it updates the tree cache.
enum CommandEffect: String, Sendable {
    /// Sends input or changes device state; a claimed device with no recorded input counts as input at the end.
    case input
    /// Reads the accessibility tree without input.
    case read
    /// Neither; the cache is left alone.
    case none

    /// Keyed by command path (`rn prepare` for a nested one); a test fails when a command is missing.
    static let table: [String: CommandEffect] = [
        "describe-ui": .read,
        "list-devices": .none,
        "boot": .input,
        "doctor": .none,
        "init": .none,
        "guide": .none,
        "tap": .input,
        "turnstile": .input,
        "slider": .input,
        "type": .input,
        "swipe": .input,
        "drag": .input,
        "button": .input,
        "shake": .input,
        "orientation": .input,
        "displays": .none,
        "posture": .input,
        "appearance": .input,
        "content-size": .input,
        "permission": .input,
        "status-bar": .input,
        "biometric": .input,
        "unlock-code": .none,
        "stay-awake": .input,
        "wake": .input,
        "key": .input,
        "key-sequence": .input,
        "key-combo": .input,
        "touch": .input,
        "gesture": .input,
        "stream-video": .none,
        "record-video": .none,
        "screenshot": .read,
        "logs": .none,
        "wait": .read,
        "assert": .read,
        "batch": .input,
        "rn prepare": .input,
        "hid-broker": .none,
    ]

    /// Batch step kinds, so a new step cannot skip the cache rules.
    static let batchSteps: [String: CommandEffect] = [
        "tap": .input, "swipe": .input, "gesture": .input, "touch": .input, "type": .input, "button": .input,
        "key": .input, "key-sequence": .input, "key-combo": .input, "sleep": .none,
        "wait": .read, "assert": .read, "screenshot": .read, "describe-ui": .read,
    ]

    /// Unknown commands count as input, the cautious choice.
    static func of(_ command: String) -> CommandEffect {
        table[command] ?? .input
    }
}
