import Foundation
import OffsiderCore

/// `devicectl device install app` and `device uninstall app`: their arguments, what they report and why a device refused.
public enum DevicectlAppInstall {
    /// devicectl's own limit; the process is given `outerTimeout` so its answer is read rather than cut off.
    static let timeout = 300
    static let outerTimeout: TimeInterval = 330
    static let uninstallTimeout: TimeInterval = 60

    /// No provisioning flag exists here to pass: Offsider installs what was built and signed, and nothing else.
    public static func installArguments(udid: String, path: String) -> [String] {
        ["device", "install", "app", "--device", udid, path, "--json-output", "-", "-q", "--timeout", String(timeout)]
    }

    public static func uninstallArguments(udid: String, bundleID: String) -> [String] {
        ["device", "uninstall", "app", "--device", udid, bundleID, "--timeout", "30", "--json-output", "-", "-q"]
    }

    /// The bundle ids the device says it installed; nil when the reply names none.
    public static func installedIDs(_ data: Data) -> [String]? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let rows = (root["result"] as? [String: Any])?["installedApplications"] as? [[String: Any]] else { return nil }
        let ids = rows.compactMap { ($0["bundleID"] as? String) ?? ($0["bundleIdentifier"] as? String) }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : ids
    }

    /// Why the device refused, in its own words first, with the fix for the reasons Offsider knows. Codes and whole phrases only, as the text can quote an app's name.
    public static func refusal(_ cause: CoreDeviceErrorInfo?, stderr: String, app: String, device: String) -> AppLifecycleError {
        let line = stderr.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let said = TerminalText.line(cause?.rootCause ?? line ?? "devicectl gave no reason", cap: 300)
        let words = ((cause?.chain.compactMap(\.description) ?? []) + [stderr]).joined(separator: " ").lowercased()
        let has: ([String]) -> Bool = { $0.contains(where: words.contains) }
        let fix: String
        if has(["0xe8008015", "0xe8008012", "0xe8008011", "provisioning profile"]) {
            fix = "No valid provisioning profile covers this device: a person adds it to the team in Xcode (Window > Devices and Simulators), then the app is built again."
        } else if has(["0xe800801c", "0xe8008016", "0xe8008018", "code signature", "no code signature", "not signed", "integrity could not be verified"]) {
            fix = "Its code signature was refused: build and sign it again in Xcode for this device."
        } else if has(["requires a newer version of ios", "requires a newer version of ipados", "minimum os version", "osversiontoolow"]) {
            fix = "Its iOS is older than the build's deployment target: lower the target, or update the device."
        } else if has(["not enough space", "no space left", "not enough storage", "insufficient storage", "disk space"]) {
            fix = "Free some space on the device, then run the same command again."
        } else {
            fix = "Run `offsider doctor --device \(device)` to check the device."
        }
        return AppLifecycleError(.installFailed, "\(device) refused to install \(app), so nothing changed. It said: \(said). \(fix)")
    }
}

/// The profile check before a transfer: a courtesy that saves sending a build the device would refuse.
enum AppProvisioning {
    /// Nil when the profile covers the device, or cannot be read: the device then decides.
    static func refusal(_ coverage: ProvisioningProfile.Coverage?, udid: String, bundle: String, now: Date) -> AppLifecycleError? {
        guard let coverage else { return nil }
        let rebuild = "Nothing was sent. A person adds the device to the team in Xcode (Window > Devices and Simulators), then the app is built again."
        if let expires = coverage.ExpirationDate, expires <= now {
            let day = ISO8601DateFormatter.string(from: expires, timeZone: .gmt, formatOptions: [.withFullDate])
            return AppLifecycleError(.notProvisioned, "\(bundle)'s provisioning profile expired on \(day), so \(udid) would refuse it. Nothing was sent. Build the app again in Xcode for a new profile.")
        }
        if coverage.ProvisionsAllDevices == true { return nil }
        guard let devices = coverage.ProvisionedDevices else {
            return AppLifecycleError(.notProvisioned, "\(bundle) is signed for the App Store, which no device takes from a Mac. Nothing was sent. Build a development copy in Xcode for this device.")
        }
        guard devices.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) else {
            return AppLifecycleError(.notProvisioned, "\(bundle)'s provisioning profile does not list \(udid), so the device would refuse it. \(rebuild)")
        }
        return nil
    }
}
