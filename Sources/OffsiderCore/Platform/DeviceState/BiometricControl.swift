import Foundation

public enum BiometricModality: String, CaseIterable, Sendable {
    case face
    case finger

    public var displayName: String {
        self == .face ? "Face ID" : "Touch ID"
    }
}

public enum BiometricOutcome: String, Sendable {
    case match
    case noMatch = "no-match"
}

public enum BiometricAction: String, CaseIterable, Sendable {
    case enrol
    case unenrol
    case match
    case noMatch = "no-match"
    case status

    /// US spellings work too, and are kept out of the help.
    public static func parse(_ text: String) -> BiometricAction? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "enroll": return .enrol
        case "unenroll": return .unenrol
        case let other: return BiometricAction(rawValue: other)
        }
    }
}

/// The BiometricKit notifications behind the simulator's Face ID and Touch ID menus, and the emulator console's finger commands.
public enum BiometricControl {
    public static let enrolmentKey = "com.apple.BiometricKit.enrollmentChanged"

    public static func notification(_ outcome: BiometricOutcome, modality: BiometricModality) -> String {
        let sensor = modality == .face ? "pearl" : "fingerTouch"
        return "com.apple.BiometricKit_Sim.\(sensor).\(outcome == .match ? "match" : "nomatch")"
    }

    /// Touch ID for the iPhone SE and iPads other than iPad Pro; Face ID otherwise.
    public static func defaultModality(deviceTypeName: String) -> BiometricModality {
        if deviceTypeName.hasPrefix("iPhone SE") { return .finger }
        if deviceTypeName.hasPrefix("iPad"), !deviceTypeName.hasPrefix("iPad Pro") { return .finger }
        return .face
    }

    public static func iosSetEnrolmentArguments(udid: String, enrolled: Bool) -> [[String]] {
        [
            ["simctl", "spawn", udid, "notifyutil", "-s", enrolmentKey, enrolled ? "1" : "0"],
            ["simctl", "spawn", udid, "notifyutil", "-p", enrolmentKey],
        ]
    }

    public static func iosReadEnrolmentArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, "notifyutil", "-g", enrolmentKey]
    }

    public static func iosPostArguments(udid: String, notification: String) -> [String] {
        ["simctl", "spawn", udid, "notifyutil", "-p", notification]
    }

    public static let androidMatchFinger = 1
    /// No fingerprint is enrolled with this id, so the sensor reports it as not recognised.
    public static let androidNoMatchFinger = 10

    public static func androidTouchArguments(serial: String, fingerID: Int) -> [String] {
        ["-s", serial, "emu", "finger", "touch", String(fingerID)]
    }

    public static func androidRemoveArguments(serial: String) -> [String] {
        ["-s", serial, "emu", "finger", "remove"]
    }

    /// The enrolled count from `dumpsys fingerprint`'s JSON line, nil when it cannot tell.
    public static func parseAndroidEnrolled(_ dumpsys: String) -> Bool? {
        guard let range = dumpsys.range(of: #""count":\s*(\d+)"#, options: .regularExpression) else { return nil }
        let digits = dumpsys[range].filter(\.isNumber)
        return Int(digits).map { $0 > 0 }
    }
}
