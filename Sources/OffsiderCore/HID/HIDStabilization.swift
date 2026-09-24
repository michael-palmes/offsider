import Foundation

public enum HIDStabilization {
    public static let environmentKey = "OFFSIDER_HID_STABILIZATION_MS"
    public static let defaultMilliseconds: UInt64 = 25
    public static let maximumMilliseconds: UInt64 = 1000

    public enum Source: String, Codable, Sendable {
        case defaultValue = "default"
        case environment
        case clamped
        case ignored
    }

    public static func resolve(environmentValue: String?) -> (milliseconds: UInt64, source: Source) {
        guard let environmentValue else {
            return (defaultMilliseconds, .defaultValue)
        }
        guard let milliseconds = UInt64(environmentValue) else {
            return (defaultMilliseconds, .ignored)
        }
        if milliseconds > maximumMilliseconds {
            return (maximumMilliseconds, .clamped)
        }
        return (milliseconds, .environment)
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> (milliseconds: UInt64, source: Source) {
        resolve(environmentValue: environment[environmentKey])
    }
}
