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

    /// The current user, a marker, then the fingerprint dump, in one round trip; read only, so it suits a phone too.
    public static let androidStatusScript = "cmd activity get-current-user 2>/dev/null; echo \(androidStatusMarker); dumpsys fingerprint; true"
    static let androidStatusMarker = "__offsider_fingerprint__"
    /// A sensor line longer than this is left unread, so enrolment reads as unknown.
    static let maximumSensorLineBytes = 65_536

    /// Whether the user in front has a print on any sensor; nil for no sensor line, or an unread one and no print elsewhere.
    public static func parseAndroidEnrolled(_ output: String) -> Bool? {
        let (user, dump) = splitStatus(output)
        var sensors = 0
        var unreadable = false
        for line in dump.split(whereSeparator: \.isNewline) where line.contains("\"prints\"") {
            sensors += 1
            guard let counts = enrolledCounts(line), let count = user.map({ counts[$0] }) ?? (counts.count == 1 ? counts.values.first : nil) else {
                unreadable = true
                continue
            }
            if count > 0 { return true }
        }
        return sensors == 0 || unreadable ? nil : false
    }

    /// A bare dump is the owner's; after the marker, an unreadable user is nil, so only a single-user dump can answer.
    static func splitStatus(_ output: String) -> (user: Int?, dump: Substring) {
        guard let marker = output.range(of: androidStatusMarker) else { return (0, output[...]) }
        let before = output[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(before).flatMap { $0 >= 0 ? $0 : nil }, output[marker.upperBound...])
    }

    /// One sensor's JSON, `{"service":…,"prints":[{"id":0,"count":2,…}]}`, as enrolled prints per user; nil unless every entry has both.
    static func enrolledCounts(_ line: Substring) -> [Int: Int]? {
        guard line.utf8.count <= maximumSensorLineBytes, let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(line[open...close].utf8)) as? [String: Any],
              let prints = object["prints"] as? [Any], !prints.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for entry in prints {
            guard let entry = entry as? [String: Any], let user = integer(entry["id"]), let count = integer(entry["count"]), user >= 0, count >= 0,
                  counts.updateValue(count, forKey: user) == nil else { return nil }
        }
        return counts
    }

    /// A JSON whole number; a boolean, which bridges to 0 or 1, is not one.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e9 else { return nil }
        return Int(double)
    }
}
