import Foundation
import OffsiderCore

/// Shell scripts and parsers for the screen's power and lock state, stay awake and the lock screen code.
enum AndroidAwakeState {
    /// The maker, `dumpsys power`, the keyguard lines of `dumpsys window policy`, then the credential type, which some releases do not print: about 0.2 s on a phone.
    static let readScript = "echo maker=$(getprop ro.product.manufacturer); dumpsys power | grep -E '^  m(Wakefulness|IsPowered|PlugType|StayOnWhilePluggedInSetting|ScreenOffTimeoutSetting|MaximumScreenOffTimeoutFromDeviceAdmin)='; "
        + "dumpsys window policy | grep -E '^ +(showing|occluded|secure)='; "
        + "dumpsys lock_settings | grep -m1 -E '^ +CredentialType:'; true"

    /// For `boot` and `doctor` only: whether the user has unlocked since boot, and the RAM the device sees.
    static let userStateScript = "; u=$(am get-current-user); echo user_state=$(am get-started-user-state ${u:-0}); echo ce_available=$(getprop sys.user.${u:-0}.ce_available)"
        + "; echo memtotal_kb=$(grep MemTotal /proc/meminfo)"

    /// For `doctor` on a phone: the adb authorisation timeout and the automatic system update switch.
    static let phoneSettingsScript = "; echo adb_allowed_connection_time=$(settings get global adb_allowed_connection_time)"
        + "; echo ota_disable_automatic_update=$(settings get global ota_disable_automatic_update)"

    /// The value of a `key=value` line the scripts print.
    static func value(of key: String, in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(key + "=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    static let afterMarker = "offsider-stay-awake-after"

    /// AC, USB, wireless and dock, as Developer options writes on Android 14 and later; earlier releases ignore the dock bit.
    static let everySource = PowerSources([.ac, .usb, .wireless, .dock])

    /// Reads, sets, then reads the setting back; `settings put` is a fifth of the time of `svc power stayon`, which writes the same setting.
    static func setScript(_ on: Bool) -> String {
        "\(readScript); echo \(afterMarker); settings put global stay_on_while_plugged_in \(on ? everySource.rawValue : 0) && settings get global stay_on_while_plugged_in"
    }

    /// The label the code's shell command runs under, so errors and timings never carry it.
    static let codeLabel = "input text <code withheld>"

    /// `input text` for the code, then Enter only if every piece was typed.
    static func codeScript(_ code: UnlockCode) -> String {
        (AdbShellQuoting.inputTextCommands(for: code.text) + ["input keyevent KEYCODE_ENTER"]).joined(separator: " && ")
    }

    static func wakeScript(screenOn: Bool, lockScreen: LockScreen) -> (script: String, sent: [String])? {
        var commands: [String] = []
        var sent: [String] = []
        if !screenOn {
            commands.append("input keyevent KEYCODE_WAKEUP")
            sent.append("KEYCODE_WAKEUP")
        }
        if lockScreen != .hidden {
            commands.append("wm dismiss-keyguard")
            sent.append("dismiss-keyguard")
        }
        return commands.isEmpty ? nil : (commands.joined(separator: "; "), sent)
    }

    /// Nil when the wakefulness or keyguard lines are missing; the first value of a repeated key wins.
    static func parse(_ output: String) -> AwakeReading? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let separator = text.hasPrefix("CredentialType:") ? ":" : "="
            guard let index = text.firstIndex(of: Character(separator)) else { continue }
            let key = String(text[..<index])
            if values[key] == nil {
                values[key] = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let screen = values["mWakefulness"].flatMap(screenPower), let showing = values["showing"].flatMap(Bool.init) else { return nil }
        let secure = values["secure"] == "true"
        let lockScreen: LockScreen = showing && values["occluded"] != "true" ? (secure ? .secure : .swipe) : .hidden
        let powered = values["mIsPowered"] == "true"
        return AwakeReading(
            screen: screen,
            lockScreen: lockScreen,
            credential: values["CredentialType"].flatMap(credential),
            stayAwake: PowerSources(rawValue: values["mStayOnWhilePluggedInSetting"].flatMap { Int($0) } ?? 0),
            charging: powered ? PowerSources(rawValue: values["mPlugType"].flatMap { Int($0) } ?? 0) : [],
            screenTimeoutMilliseconds: values["mScreenOffTimeoutSetting"].flatMap { Int($0) },
            timeoutCappedByPolicy: values["mMaximumScreenOffTimeoutFromDeviceAdmin"]?.contains("enforced=true") == true,
            maker: values["maker"].flatMap { $0.isEmpty ? nil : $0 },
            userUnlocked: userUnlocked(state: values["user_state"], ceAvailable: values["ce_available"]),
            memTotalKB: values["memtotal_kb"].flatMap(kilobytes)
        )
    }

    /// `RUNNING_UNLOCKED` is unlocked; `RUNNING_LOCKED` and `RUNNING_UNLOCKING` are not; otherwise `ce_available` decides.
    static func userUnlocked(state: String?, ceAvailable: String?) -> Bool? {
        let state = state?.uppercased() ?? ""
        if state.contains("RUNNING_UNLOCKED") { return true }
        if state.contains("RUNNING_LOCKED") || state.contains("RUNNING_UNLOCKING") { return false }
        switch ceAvailable {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `MemTotal:        6149664 kB` gives 6149664.
    static func kilobytes(_ line: String) -> Int? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let index = fields.firstIndex(where: { Int($0) != nil }) else { return nil }
        return Int(fields[index])
    }

    /// The reading before the change, and the setting's value read back after it.
    static func parseSet(_ output: String) -> (before: AwakeReading, after: PowerSources)? {
        let parts = output.components(separatedBy: afterMarker + "\n")
        guard parts.count == 2, let before = parse(parts[0]),
              let value = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (before, PowerSources(rawValue: value))
    }

    static func screenPower(_ wakefulness: String) -> ScreenPower? {
        switch wakefulness {
        case "Awake": return .on
        case "Asleep": return .off
        case "Dozing": return .dozing
        case "Dreaming": return .dreaming
        default: return nil
        }
    }

    static func credential(_ type: String) -> String? {
        switch type.uppercased() {
        case "PIN": return "pin"
        case "PATTERN": return "pattern"
        case "PASSWORD", "PASSWORD_OR_PIN": return "password"
        case "NONE": return "none"
        default: return nil
        }
    }

    /// The focused password field inside System UI, which shows the lock screen; a code is typed nowhere else.
    static func lockScreenCodeField(in roots: [UINode]) -> UINode? {
        func search(_ node: UINode, insideSystemUI: Bool) -> UINode? {
            let inside = insideSystemUI || node.id?.hasPrefix("com.android.systemui:") == true
            if inside, node.role == .secureTextField, node.state.focused == true { return node }
            for child in node.children {
                if let found = search(child, insideSystemUI: inside) { return found }
            }
            return nil
        }
        for root in roots where root.role != .keyboard {
            if let found = search(root, insideSystemUI: false) { return found }
        }
        return nil
    }
}
