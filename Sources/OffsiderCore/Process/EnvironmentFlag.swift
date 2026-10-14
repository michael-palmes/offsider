import Foundation

/// A yes or no environment variable: `1`, `true`, `yes` or `on` is true; `0`, `false`, `no` or `off` is false; anything else is unset.
public enum EnvironmentFlag {
    public static func bool(_ key: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool? {
        guard let raw = environment[key] else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}
