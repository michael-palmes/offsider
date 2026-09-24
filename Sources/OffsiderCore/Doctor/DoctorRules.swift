import Foundation

public enum BrokerDirectoryState: Equatable, Sendable {
    public static let notADirectoryReason = "not a directory"

    case absent
    case unsafe(reason: String, ownedByCurrentUser: Bool)
    case healthy(live: Int, stale: Int, unexpectedEntries: [String])
}

public enum DeviceHubState: Equatable, Sendable {
    case missing
    case notRunning
    case running
    case runningFromOtherXcode(path: String)
}

public enum DeviceWindowState: Equatable, Sendable {
    case found
    case notFound
    case titlesUnavailable
    case deviceHubNotRunning
}

public enum AccessibilityProbeState: Equatable, Sendable {
    case known
    case emptyRoot
    case failed(String)
}

/// Pure verdicts for each doctor check; probes gather the inputs.
public enum DoctorRules {
    public typealias Verdict = (status: CheckStatus, detail: String, hint: String?)

    public static let dtuhidCoreSimulatorVersion = "1155.4"
    public static let minimumXcodeMajor = 26
    public static let deviceHubXcodeMajor = 27
    public static let minimumBootUptime: TimeInterval = 10

    // MARK: Versions

    public static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        return numbers
    }

    public static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        guard let lhs = versionComponents(version), let rhs = versionComponents(minimum) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    public static func majorVersion(_ version: String?) -> Int? {
        version.flatMap(versionComponents)?.first
    }

    public static func isDTUHIDEra(coreSimulatorVersion: String?) -> Bool {
        guard let coreSimulatorVersion else { return false }
        return isVersion(coreSimulatorVersion, atLeast: dtuhidCoreSimulatorVersion)
    }

    public static func isDeviceHubEra(xcodeMajor: Int?) -> Bool {
        (xcodeMajor ?? 0) >= deviceHubXcodeMajor
    }

    public static func xcodeVersion(_ version: String?, build: String? = nil) -> Verdict {
        let hint = "Offsider needs Xcode \(minimumXcodeMajor) or later; Xcode 27 is the target."
        guard let version, let major = majorVersion(version) else {
            return (.fail, "Could not read the Xcode version", hint)
        }
        let description = build.map { "Xcode \(version) (\($0))" } ?? "Xcode \(version)"
        guard major >= minimumXcodeMajor else {
            return (.fail, "\(description) is too old", hint)
        }
        return (.pass, description, nil)
    }

    public static func coreSimulator(version: String?, xcodeMajor: Int?) -> Verdict {
        let hint = "Run xcodebuild -runFirstLaunch so CoreSimulator matches Xcode 27."
        guard let version else {
            return (.warn, "Could not read the CoreSimulator version", hint)
        }
        if isDeviceHubEra(xcodeMajor: xcodeMajor), !isVersion(version, atLeast: dtuhidCoreSimulatorVersion) {
            return (.warn, "CoreSimulator \(version) is older than Xcode 27 expects (\(dtuhidCoreSimulatorVersion))", hint)
        }
        return (.pass, "CoreSimulator \(version)", nil)
    }

    // MARK: Host

    public static func simulatorApp(isRunning: Bool, xcodeMajor: Int?) -> Verdict {
        guard isDeviceHubEra(xcodeMajor: xcodeMajor) else {
            return (.skip, "Only checked with Xcode 27 or later", nil)
        }
        guard !isRunning else {
            return (.fail, "Simulator.app is running", "Quit Simulator.app; Xcode 27 runs simulators under Device Hub.")
        }
        return (.pass, "Simulator.app is not running", nil)
    }

    public static func deviceHub(_ state: DeviceHubState, appPath: String, xcodeMajor: Int?) -> Verdict {
        guard isDeviceHubEra(xcodeMajor: xcodeMajor) else {
            return (.skip, "Only checked with Xcode 27 or later", nil)
        }
        let hint = "Open Device Hub: open -g \"\(appPath)\" (or offsider doctor --fix)."
        switch state {
        case .missing:
            return (.fail, "Device Hub is missing at \(appPath)", "Reinstall Xcode or select a complete Xcode 27 installation.")
        case .notRunning:
            return (.warn, "Device Hub is not running", hint)
        case .running:
            return (.pass, "Device Hub is running", nil)
        case .runningFromOtherXcode(let path):
            return (.warn, "Device Hub is running from another Xcode: \(path)", "Quit Device Hub, then open the one in the selected Xcode: open -g \"\(appPath)\".")
        }
    }

    public static func isDeviceHubFixable(_ state: DeviceHubState, xcodeMajor: Int?) -> Bool {
        isDeviceHubEra(xcodeMajor: xcodeMajor) && state == .notRunning
    }

    public static func stabilization(environmentValue: String?) -> Verdict {
        let resolved = HIDStabilization.resolve(environmentValue: environmentValue)
        let hint = "Unset \(HIDStabilization.environmentKey) or set 1 to \(HIDStabilization.maximumMilliseconds)."
        switch resolved.source {
        case .defaultValue:
            return (.pass, "\(resolved.milliseconds) ms (default)", nil)
        case .environment where resolved.milliseconds == 0:
            return (.warn, "0 ms: the settle delay after each input is turned off", hint)
        case .environment:
            return (.pass, "\(resolved.milliseconds) ms (\(HIDStabilization.environmentKey))", nil)
        case .clamped:
            return (.warn, "\(environmentValue ?? "") ms is above the cap; \(resolved.milliseconds) ms used", hint)
        case .ignored:
            return (.warn, "\"\(environmentValue ?? "")\" is not a whole number; \(resolved.milliseconds) ms used", hint)
        }
    }

    public static func brokerDirectory(_ state: BrokerDirectoryState, path: String) -> Verdict {
        let hint = "Remove the stale broker directory: rm -rf \"\(path)\" (or offsider doctor --fix)."
        switch state {
        case .absent:
            return (.pass, "Not created yet", nil)
        case .unsafe(let reason, _) where reason == BrokerDirectoryState.notADirectoryReason:
            return (.fail, "Unsafe broker directory: \(reason)", "Offsider did not create \"\(path)\"; check what it is and remove it yourself.")
        case .unsafe(let reason, let owned):
            return (.fail, "Unsafe broker directory: \(reason)", owned ? hint : "Remove \"\(path)\" as its owner, then run the command again.")
        case .healthy(let live, let stale, let unexpected):
            if !unexpected.isEmpty {
                return (.warn, "Unexpected entries: \(unexpected.joined(separator: ", "))", "Inspect \"\(path)\" and remove the entries Offsider did not create.")
            }
            if stale > 0 {
                let hint = live > 0 ? "Stale sockets are replaced on the next input command; no action needed while a broker is live." : hint
                return (.warn, "\(plural(stale, "stale socket")), \(plural(live, "live broker"))", hint)
            }
            return (.pass, plural(live, "live broker"), nil)
        }
    }

    public static func isBrokerDirectoryFixable(_ state: BrokerDirectoryState) -> Bool {
        switch state {
        case .absent:
            return false
        case .unsafe(let reason, let owned):
            return owned && reason != BrokerDirectoryState.notADirectoryReason
        case .healthy(let live, let stale, let unexpected):
            return stale > 0 && live == 0 && unexpected.isEmpty
        }
    }

    public static func bootedSimulators(count: Int) -> Verdict {
        guard count > 0 else {
            return (.warn, "No simulators are booted", "Boot one with xcrun simctl boot <UDID>.")
        }
        return (.pass, "\(count) booted", nil)
    }

    // MARK: Simulator

    public static func bootUptime(seconds: TimeInterval) -> Verdict {
        guard seconds >= minimumBootUptime else {
            return (.warn, "booted \(Int(max(0, seconds))) s ago and still settling; HID checks skipped", "Wait a few seconds and run doctor again.")
        }
        return (.pass, "up \(formatUptime(seconds))", nil)
    }

    public static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    public static func deviceWindow(_ state: DeviceWindowState, udid: String) -> Verdict {
        switch state {
        case .found:
            return (.pass, "Device window is open", nil)
        case .notFound:
            return (.warn, "No Device Hub window shows this simulator", "Open the device window: open \"devices://device/open?id=\(udid)\" (or --fix).")
        case .titlesUnavailable:
            return (.skip, "Window titles are unavailable without Screen Recording permission", nil)
        case .deviceHubNotRunning:
            return (.skip, "Device Hub is not running", nil)
        }
    }

    public static func resizeMode(exitStatus: Int32, output: String, udid: String) -> Verdict {
        if output.contains("24004") {
            return (.pass, "Resize Mode is off", nil)
        }
        if exitStatus == 0 {
            return (.fail, "Resize Mode is hosting this device; input is reported as sent but dropped", "Turn off Resize Mode for this device in Device Hub.")
        }
        return (.warn, "Could not determine whether Resize Mode is on", "Check that Resize Mode is off for this device in Device Hub.")
    }

    public static func dtuhidd(processIdentifier: Int32?) -> Verdict {
        guard let processIdentifier, processIdentifier > 0 else {
            return (.pass, "not running", nil)
        }
        return (.pass, "dtuhidd pid \(processIdentifier)", nil)
    }

    public static func parseNotifyFlag(_ notifyutilOutput: String) -> Int? {
        let tokens = notifyutilOutput.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 2 else { return nil }
        return Int(tokens[1])
    }

    /// `selectedTransport` is the transport Offsider picked ("dtuhid" or "indigo"), or nil when that probe did not run or failed.
    public static func dtuhidState(flag: Int?, dtuhiddRunning: Bool, dtuhidEra: Bool, selectedTransport: String?, udid: String) -> Verdict {
        guard dtuhidEra else {
            return (.skip, "Only used from CoreSimulator \(dtuhidCoreSimulatorVersion)", nil)
        }
        guard let flag else {
            return (.warn, "Could not read the dtuhidd active flag", "Run doctor again; if it persists, reboot the simulator.")
        }
        switch (flag != 0, dtuhiddRunning) {
        case (false, false):
            return (.pass, "Indigo transport; keyboard and buttons use the legacy services", nil)
        case (true, true):
            return (.pass, "DTUHID transport; the legacy keyboard and buttons are off for this boot, as expected", nil)
        case (true, false):
            let hint = "Open the device window (offsider doctor --udid \(udid) --fix) or reboot the simulator: xcrun simctl shutdown \(udid) && xcrun simctl boot \(udid)."
            switch selectedTransport {
            case "dtuhid":
                return (.pass, "dtuhidd is idle and starts on demand", nil)
            case "indigo":
                return (
                    .fail,
                    "Legacy keyboard and buttons are off for this boot, but Offsider selected Indigo, so type, key and button input is dropped",
                    hint
                )
            default:
                return (
                    .warn,
                    "Legacy keyboard and buttons are off for this boot and dtuhidd is not running; the selected HID transport is unknown",
                    hint
                )
            }
        case (false, true):
            return (.warn, "dtuhidd is attaching", "Run doctor again in a few seconds.")
        }
    }

    public static func accessibility(_ state: AccessibilityProbeState) -> Verdict {
        let hint = "Launch an app, or run describe-ui to see the error."
        switch state {
        case .known:
            return (.pass, "Accessibility tree is readable", nil)
        case .emptyRoot:
            return (.warn, "Empty tree: no frontmost app, or accessibility is not ready yet", hint)
        case .failed(let message):
            return (.fail, message, hint)
        }
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
