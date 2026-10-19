import Foundation

/// `OFFSIDER_SIMULATOR_SESSION` and `OFFSIDER_SIMULATOR_SESSION_IDLE`: whether a simulator's input session stays warm between commands, and for how long.
public enum SimulatorSessionSettings {
    public static let modeVariable = "OFFSIDER_SIMULATOR_SESSION"
    public static let idleVariable = "OFFSIDER_SIMULATOR_SESSION_IDLE"
    public static let defaultIdleSeconds = 60
    public static let maxIdleSeconds = 3600
    /// A broker stops at its next idle moment after this long, so the next command starts a fresh one.
    public static let maxLifetimeSeconds = 12 * 3600

    /// Unset or empty is on; anything but on or off is refused.
    public static func isWarm(_ environment: [String: String]) throws -> Bool {
        let value = environment[modeVariable]?.trimmingCharacters(in: .whitespaces) ?? ""
        switch value.lowercased() {
        case "", "on": return true
        case "off": return false
        default: throw InvalidValue(variable: modeVariable, value: value, expected: "on or off")
        }
    }

    /// 60 when unset or not a positive whole number, at most 3600.
    public static func idleSeconds(_ environment: [String: String]) -> Int {
        let seconds = environment[idleVariable].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
        return min(seconds ?? defaultIdleSeconds, maxIdleSeconds)
    }

    public struct InvalidValue: Error, Equatable, Sendable, CustomStringConvertible {
        public let variable: String
        public let value: String
        public let expected: String

        public var description: String { "\(variable) is \"\(value)\"; use \(expected)." }
    }
}
