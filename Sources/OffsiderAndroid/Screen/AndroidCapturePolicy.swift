import Foundation

/// `OFFSIDER_ANDROID_CAPTURE`: how a screenshot is taken on a device without gRPC (a phone, or an emulator on adb).
enum AndroidCapturePolicy: String, Sendable {
    /// `screencap -p` for now.
    case auto
    /// `screencap -p`: the device encodes the PNG.
    case screencap
    /// `screencap` raw pixels, encoded as PNG on the Mac; `screencap -p` when the output cannot be read.
    case raw
    /// The UiAutomation helper's raw pixels, encoded on the Mac; `screencap -p` when the helper cannot serve.
    case helper

    static let variable = "OFFSIDER_ANDROID_CAPTURE"

    /// Unset or empty is auto.
    static func policy(host: AndroidHost) throws -> AndroidCapturePolicy {
        guard let value = host.variable(variable) else { return .auto }
        guard let policy = AndroidCapturePolicy(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: variable, value: value, expected: "auto, screencap, raw or helper")
        }
        return policy
    }
}

/// What `screencap` without `-d` captures on a device with several displays: the active one, or one Offsider must name.
enum ScreencapPick: Sendable {
    case activeDisplay
    case namedDisplay
}
