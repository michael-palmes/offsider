import Foundation

public enum StatusBarDataNetwork: String, CaseIterable, Sendable {
    case wifi
    case fiveG = "5g"
    case lte
    case fourG = "4g"
    case threeG = "3g"
    case none

    var iosName: String { self == .none ? "hide" : rawValue }
    /// Wi-Fi shows its own icon on Android, so the mobile data type stays LTE.
    var androidDataType: String { self == .wifi ? "lte" : self == .none ? "null" : rawValue }
}

/// A clean status bar; nil bars turn that radio off.
public struct StatusBarOverride: Equatable, Sendable {
    public var time = "9:41"
    public var batteryLevel = 100
    public var charging = false
    public var wifiBars: Int? = 3
    public var cellularBars: Int? = 4
    public var operatorName = ""
    public var dataNetwork = StatusBarDataNetwork.wifi
    public var notificationsHidden = true

    public init() {}

    /// `H:MM` or `HH:MM`, 24-hour.
    public static func parseTime(_ text: String) throws -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), parts[1].count == 2,
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw DeviceSettingsError("--time takes HH:MM, for example 9:41; got \(text).")
        }
        return "\(hour):\(parts[1])"
    }

    /// `off` or a bar count from 0 to `maximum`.
    public static func parseBars(_ text: String, option: String, maximum: Int) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "off" { return nil }
        guard let bars = Int(trimmed), (0...maximum).contains(bars) else {
            throw DeviceSettingsError("\(option) takes off or 0 to \(maximum); got \(text).")
        }
        return bars
    }

    /// iOS has three Wi-Fi bars and Android four levels: 0, 1, 2 and 3 bars are levels 0, 1, 3 and 4.
    public static func androidWifiLevel(bars: Int) -> Int {
        [0, 1, 3, 4][max(0, min(3, bars))]
    }

    public func iosOverrideArguments(udid: String) -> [String] {
        var arguments = ["simctl", "status_bar", udid, "override", "--time", time, "--dataNetwork", dataNetwork.iosName]
        if let wifiBars {
            arguments += ["--wifiMode", "active", "--wifiBars", String(wifiBars)]
        } else {
            arguments += ["--wifiMode", "failed", "--wifiBars", "0"]
        }
        if let cellularBars {
            arguments += ["--cellularMode", "active", "--cellularBars", String(cellularBars)]
        } else {
            arguments += ["--cellularMode", "notSupported"]
        }
        arguments += ["--operatorName", operatorName, "--batteryState", charging ? "charging" : "discharging", "--batteryLevel", String(batteryLevel)]
        return arguments
    }

    public static func iosClearArguments(udid: String) -> [String] {
        ["simctl", "status_bar", udid, "clear"]
    }

    public static func iosListArguments(udid: String) -> [String] {
        ["simctl", "status_bar", udid, "list"]
    }

    /// The `key: value` pairs under "Current Status Bar Overrides:"; empty when nothing is overridden.
    public static func parseIOSList(_ output: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for line in output.components(separatedBy: .newlines) where !line.hasPrefix("Current Status Bar") && !line.hasPrefix("===") {
            for field in line.split(separator: ",") {
                let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                pairs.append((parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)))
            }
        }
        return pairs
    }

    static let demoBroadcast = "am broadcast -a com.android.systemui.demo -e command"

    /// One adb round trip: the first stdout line is the previous `sysui_demo_allowed`; `fully` drops the no-internet mark.
    public var androidEnterScript: String {
        let wifi = wifiBars.map { "-e wifi show -e level \(Self.androidWifiLevel(bars: $0)) -e fully true" } ?? "-e wifi hide"
        let mobile = cellularBars.map { "-e mobile show -e datatype \(dataNetwork.androidDataType) -e level \($0) -e fully true" } ?? "-e mobile hide"
        let commands = [
            "enter",
            "clock -e hhmm \(time.replacingOccurrences(of: ":", with: "").leftPadded(to: 4))",
            "battery -e level \(batteryLevel) -e plugged \(charging)",
            "network \(wifi)",
            "network \(mobile)",
            "notifications -e visible \(!notificationsHidden)",
        ].map { "\(Self.demoBroadcast) \($0) > /dev/null" }
        return (["settings get global sysui_demo_allowed", "settings put global sysui_demo_allowed 1"].joined(separator: "; "))
            + " && " + commands.joined(separator: " && ")
    }

    public static let androidClearScript = "\(demoBroadcast) exit > /dev/null; settings delete global sysui_demo_allowed > /dev/null"
    public static let androidShowScript = "settings get global sysui_demo_allowed"

    /// `1` is allowed, `0` not, `null` never set.
    public static func parseDemoAllowed(_ line: String) -> Bool? {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

/// What a status bar read reports: iOS lists its overrides; Android only whether demo mode is allowed.
public struct StatusBarReading: Equatable, Sendable {
    public let overrides: [String: String]?
    public let demoAllowed: Bool?

    public init(overrides: [String: String]? = nil, demoAllowed: Bool? = nil) {
        self.overrides = overrides
        self.demoAllowed = demoAllowed
    }
}
