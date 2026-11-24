import Foundation
import OffsiderCore

/// TalkBack as Offsider found or turned it on, kept until `screen-reader off`, `session stop` or `devices remove`. It outlives a reboot.
struct AndroidScreenReaderRecord: AndroidSerialRecord, Equatable, Sendable {
    static let maximumBytes = 1_024
    static let directoryName = "screen-reader-android"

    let serial: String
    /// An emulator's serial is only its port, so the AVD name says whose record this is; nil for a phone.
    let avd: String?
    let component: String
    /// False when it was already on: `session stop` leaves it, and the record only says that input must go past TalkBack.
    let turnedOn: Bool
    /// Offsider granted TalkBack's notification permission, so turning it off revokes it.
    let grantedNotifications: Bool

    var name: String { avd ?? serial }

    init(serial: String, avd: String?, component: String, turnedOn: Bool, grantedNotifications: Bool = false) {
        self.serial = serial
        self.avd = avd
        self.component = component
        self.turnedOn = turnedOn
        self.grantedNotifications = grantedNotifications
    }

    func encoded() -> Data {
        var object: [String: Any] = ["serial": serial, "component": component, "turnedOn": turnedOn, "grantedNotifications": grantedNotifications]
        if let avd { object["avd"] = avd }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A component Offsider never writes is not its record, so it never reaches a shell.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let serial = object["serial"] as? String,
              let component = object["component"] as? String, AndroidScreenReader.components.contains(component),
              let turnedOn = object["turnedOn"] as? Bool else { return nil }
        self.init(serial: serial, avd: object["avd"] as? String, component: component, turnedOn: turnedOn, grantedNotifications: object["grantedNotifications"] as? Bool ?? false)
    }
}

typealias AndroidScreenReaderRecordStore = AndroidSerialRecordStore<AndroidScreenReaderRecord>

/// TalkBack's switch: its entry in Android's list of enabled accessibility services. Android binds the service and turns touch exploration on by itself.
enum AndroidScreenReader {
    static let service = "TalkBack"
    /// Google's TalkBack, then Samsung's build of it.
    static let components = [
        "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService",
        "com.samsung.android.accessibility.talkback/com.samsung.android.marvin.talkback.TalkBackService",
    ]
    static let notifications = "android.permission.POST_NOTIFICATIONS"
    static let polls = 15
    static let pollInterval: Duration = .milliseconds(200)
    static let stateScript = "settings get secure enabled_accessibility_services; settings get secure touch_exploration_enabled"
    static let touchScript = "settings get secure touch_exploration_enabled"
    static let installedScript = components.map { "pm path \(package(of: $0)) >/dev/null 2>&1 && echo \(package(of: $0))" }.joined(separator: "; ") + "; true"

    struct State: Equatable {
        var services: [String]
        var touchExploration: Bool

        /// A reader a user would notice: TalkBack is enabled and Android explores by touch.
        func isOn(_ component: String?) -> Bool {
            guard let component else { return false }
            return touchExploration && services.contains(component)
        }
    }

    static func package(of component: String) -> String {
        String(component.prefix { $0 != "/" })
    }

    /// The list line, then the touch exploration line; nil when either is missing or the list holds text no component name has.
    static func parseState(_ output: String) -> State? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 2, let touch = parseFlag(lines[1]) else { return nil }
        let services = lines[0] == "null" ? [] : lines[0].split(separator: ":").map(String.init)
        guard services.allSatisfy(isComponent) else { return nil }
        return State(services: services, touchExploration: touch)
    }

    static func parseFlag(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0", "null": return false
        default: return nil
        }
    }

    /// `package/class`, in the letters Android allows, so a list read from a device can go back into a shell command.
    static func isComponent(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._$".contains($0)) }
        }
    }

    /// The first known TalkBack whose package `installedScript` printed.
    static func installed(_ output: String) -> String? {
        let packages = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return components.first { packages.contains(package(of: $0)) }
    }

    /// Writes the list, or deletes the key when it is empty, which is how Android ships it.
    static func writeScript(services: [String]) -> String {
        services.isEmpty
            ? "settings delete secure enabled_accessibility_services"
            : "settings put secure enabled_accessibility_services '\(services.joined(separator: ":"))'"
    }

    static func grantedScript(component: String) -> String {
        "dumpsys package \(package(of: component)) | grep -m 1 -F '\(notifications): granted='"
    }

    /// Nil when Android lists no such permission for the app, as before Android 13.
    static func parseGranted(_ output: String) -> Bool? {
        if output.contains("granted=true") { return true }
        return output.contains("granted=false") ? false : nil
    }

    static func permissionScript(grant: Bool, component: String) -> String {
        "pm \(grant ? "grant" : "revoke") \(package(of: component)) \(notifications)"
    }
}

extension EmulatorDiscovery {
    /// Whether the emulator was started with `-no-audio`, as `offsider boot` starts it, so nothing on it can speak on the Mac.
    var isSilent: Bool {
        values["cmdline"]?.contains(EmulatorArguments.noAudio) ?? false
    }
}
