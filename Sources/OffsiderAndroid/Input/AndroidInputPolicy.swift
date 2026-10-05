import Foundation

/// `OFFSIDER_ANDROID_INPUT`: how input reaches a device that has no gRPC route (a phone, or an emulator on adb).
enum AndroidInputPolicy: String, Sendable {
    /// The helper when this command already runs one on the device, else `input`.
    case auto
    /// The helper only; starting it if needed, and an unavailable helper is an error.
    case helper
    /// `input` shell commands only.
    case input

    static let variable = "OFFSIDER_ANDROID_INPUT"

    /// Unset or empty is auto.
    static func policy(host: AndroidHost) throws -> AndroidInputPolicy {
        guard let value = host.variable(variable) else { return .auto }
        guard let policy = AndroidInputPolicy(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: variable, value: value, expected: "auto, helper or input")
        }
        return policy
    }
}
