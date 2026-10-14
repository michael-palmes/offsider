import Foundation

public enum PermissionAction: String, CaseIterable, Sendable {
    case grant
    case revoke
    case reset
}

/// One name for an app permission on both platforms: a `simctl privacy` service on iOS, runtime permissions on Android.
public enum PermissionService: String, CaseIterable, Sendable {
    case all
    case calendar
    case camera
    case contacts
    case contactsLimited = "contacts-limited"
    case location
    case locationAlways = "location-always"
    case mediaLibrary = "media-library"
    case microphone
    case motion
    case notifications
    case photos
    case photosAdd = "photos-add"
    case reminders
    case siri
    case bluetooth
    case phone
    case sms
    case bodySensors = "body-sensors"

    /// The `simctl privacy` service, or nil when iOS simulators do not offer one.
    public var iosName: String? {
        switch self {
        case .camera, .notifications, .bluetooth, .phone, .sms, .bodySensors: return nil
        default: return rawValue
        }
    }

    /// Android runtime permissions, nil when Android has none; `all` is empty and means every runtime permission the app requests.
    public var androidPermissions: [String]? {
        let names: [String]?
        switch self {
        case .all: names = []
        case .calendar: names = ["READ_CALENDAR", "WRITE_CALENDAR"]
        case .camera: names = ["CAMERA"]
        case .contacts: names = ["READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS"]
        case .location: names = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"]
        case .locationAlways: names = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"]
        case .mediaLibrary: names = ["READ_MEDIA_AUDIO"]
        case .microphone: names = ["RECORD_AUDIO"]
        case .motion: names = ["ACTIVITY_RECOGNITION"]
        case .notifications: names = ["POST_NOTIFICATIONS"]
        case .photos: names = ["READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_VISUAL_USER_SELECTED"]
        case .bluetooth: names = ["BLUETOOTH_SCAN", "BLUETOOTH_CONNECT", "BLUETOOTH_ADVERTISE"]
        case .phone: names = ["READ_PHONE_STATE", "CALL_PHONE", "READ_CALL_LOG", "WRITE_CALL_LOG"]
        case .sms: names = ["SEND_SMS", "RECEIVE_SMS", "READ_SMS"]
        case .bodySensors: names = ["BODY_SENSORS"]
        case .contactsLimited, .photosAdd, .reminders, .siri: names = nil
        }
        return names?.map { "android.permission.\($0)" }
    }

    public func isOffered(on platform: DevicePlatform) -> Bool {
        platform == .ios ? iosName != nil : androidPermissions != nil
    }

    public static func offered(on platform: DevicePlatform) -> [PermissionService] {
        allCases.filter { $0.isOffered(on: platform) }
    }
}

/// A service from the shared vocabulary, or (Android only) a literal `android.permission.NAME`.
public enum PermissionTarget: Equatable, Sendable {
    case service(PermissionService)
    case androidPermission(String)

    public var name: String {
        switch self {
        case .service(let service): return service.rawValue
        case .androidPermission(let permission): return permission
        }
    }

    /// Nil platform (an ID the classifier cannot place) accepts anything either platform offers.
    public static func parse(_ text: String, platform: DevicePlatform?) throws -> PermissionTarget {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^android\.permission\.[A-Z0-9_]+$"#, options: .regularExpression) != nil {
            if platform == .ios {
                throw DeviceSettingsError("\(trimmed) is an Android permission. On iOS use a service: \(names(.ios)).")
            }
            return .androidPermission(trimmed)
        }
        guard let service = PermissionService(rawValue: trimmed.lowercased()) else {
            throw DeviceSettingsError("Unknown permission service '\(text)'. Run `offsider permission services` to list them.")
        }
        if let platform, !service.isOffered(on: platform) {
            let label = platform == .ios ? "iOS simulators (simctl privacy has no \(service.rawValue) service)" : "Android"
            throw DeviceSettingsError("\(service.rawValue) is not offered on \(label). Services on \(platform == .ios ? "iOS" : "Android"): \(names(platform)).")
        }
        return .service(service)
    }

    static func names(_ platform: DevicePlatform) -> String {
        PermissionService.offered(on: platform).map(\.rawValue).joined(separator: ", ")
    }
}

public enum PermissionState: String, Sendable {
    case granted
    case denied
    /// Reset: denied, and the app asks again on next use.
    case notDetermined = "not-determined"
}

public struct PermissionEntry: Equatable, Sendable {
    public let name: String
    public let previous: PermissionState?
    public let current: PermissionState
    /// Nil when the platform cannot read the earlier value.
    public let changed: Bool?

    public init(name: String, previous: PermissionState?, current: PermissionState, changed: Bool?) {
        self.name = name
        self.previous = previous
        self.current = current
        self.changed = changed
    }
}

public struct PermissionTargetChange: Equatable, Sendable {
    public let target: String
    public let permissions: [PermissionEntry]

    public init(target: String, permissions: [PermissionEntry]) {
        self.target = target
        self.permissions = permissions
    }
}

public struct PermissionChange: Equatable, Sendable {
    public let action: PermissionAction
    public let targets: [PermissionTargetChange]
    public let notes: [String]
    /// Android stops an app when one of its runtime permissions is revoked.
    public let appStopped: Bool

    public init(action: PermissionAction, targets: [PermissionTargetChange], notes: [String], appStopped: Bool) {
        self.action = action
        self.targets = targets
        self.notes = notes
        self.appStopped = appStopped
    }
}

/// An Android app's runtime permissions from `dumpsys package`, in dumpsys order (requested order before Android 10).
public struct AndroidPackagePermissions: Equatable, Sendable {
    /// From Android 10 (API 29) dumpsys lists every requested runtime permission; before, only those with saved state.
    public static let listsEveryRuntimePermission = 29
    /// `pm clear-permission-flags` arrived in Android 13 (API 33).
    public static let clearsPermissionFlags = 33

    public let requested: [String]
    public let runtime: [(name: String, granted: Bool)]
    /// Runtime permissions with the user-fixed flag: the user chose "Don't ask again".
    public let userFixed: Set<String>
    /// Nil when `getprop ro.build.version.sdk` answered nothing.
    public let apiLevel: Int?

    public var clearsFlags: Bool { (apiLevel ?? Self.clearsPermissionFlags) >= Self.clearsPermissionFlags }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requested == rhs.requested && lhs.runtime.map(\.name) == rhs.runtime.map(\.name) && lhs.runtime.map(\.granted) == rhs.runtime.map(\.granted)
            && lhs.userFixed == rhs.userFixed && lhs.apiLevel == rhs.apiLevel
    }

    public init(requested: [String], runtime: [(name: String, granted: Bool)], userFixed: Set<String> = [], apiLevel: Int? = nil) {
        self.requested = requested
        self.runtime = runtime
        self.userFixed = userFixed
        self.apiLevel = apiLevel
    }

    public func isGranted(_ permission: String) -> Bool? {
        runtime.first { $0.name == permission }?.granted
    }

    /// Whether the read must also list the device's dangerous permissions to find the runtime ones dumpsys leaves out.
    public static func needsDangerousList(apiLevel: Int?) -> Bool {
        apiLevel.map { $0 < listsEveryRuntimePermission } ?? false
    }

    /// The first `requested permissions:` and `runtime permissions:` blocks (user 0); with `dangerous`, a requested one missing from the runtime block is denied.
    public static func parse(dumpsysPackage output: String, apiLevel: Int? = nil, dangerous: Set<String>? = nil) -> AndroidPackagePermissions {
        let lines = output.components(separatedBy: .newlines)
        let requested = block(named: "requested permissions:", in: lines).map { line in
            String(line.prefix { $0 != ":" && $0 != "," && !$0.isWhitespace })
        }
        let listed: [(name: String, granted: Bool, flags: String)] = block(named: "runtime permissions:", in: lines).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].contains("granted=true"), String(parts[1]))
        }
        let userFixed = Set(listed.filter { $0.flags.contains("USER_FIXED") }.map(\.name))
        guard let dangerous else {
            return AndroidPackagePermissions(requested: requested, runtime: listed.map { ($0.name, $0.granted) }, userFixed: userFixed, apiLevel: apiLevel)
        }
        let granted = Dictionary(listed.map { ($0.name, $0.granted) }, uniquingKeysWith: { first, _ in first })
        let runtime = requested.compactMap { name in granted[name].map { (name, $0) } ?? (dangerous.contains(name) ? (name, false) : nil) }
            + listed.filter { !requested.contains($0.name) }.map { ($0.name, $0.granted) }
        return AndroidPackagePermissions(requested: requested, runtime: runtime, userFixed: userFixed, apiLevel: apiLevel)
    }

    /// `pm list permissions -g -d`'s permission names; nil without its `Dangerous Permissions:` header.
    public static func parseDangerous(_ output: String) -> Set<String>? {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.firstIndex(of: "Dangerous Permissions:") else { return nil }
        return Set(lines[header...].compactMap { $0.hasPrefix("permission:") ? String($0.dropFirst("permission:".count)) : nil })
    }

    /// The read script's stdout split into the API level on its first line and the dump after it.
    public static func splitRead(_ output: String) -> (apiLevel: Int?, dump: Substring) {
        guard let newline = output.firstIndex(where: \.isNewline) else { return (Int(output.trimmingCharacters(in: .whitespaces)), output[...]) }
        let level = Int(output[..<newline].trimmingCharacters(in: .whitespaces))
        return (level, level == nil ? output[...] : output[output.index(after: newline)...])
    }

    private static func block(named header: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return [] }
        let indent = lines[start].prefix { $0 == " " }.count
        var entries: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || line.prefix(while: { $0 == " " }).count <= indent { break }
            entries.append(trimmed)
        }
        return entries
    }
}

/// The shell scripts and per-permission report for one Android permission action, from the app's current state.
public struct AndroidPermissionPlan: Equatable, Sendable {
    public let script: String?
    public let change: PermissionChange

    /// Grant and revoke skip permissions already in place; reset also clears the user-set flags so the app asks again.
    public static func make(_ action: PermissionAction, _ targets: [PermissionTarget], package: String, state: AndroidPackagePermissions) throws -> AndroidPermissionPlan {
        var notes: [String] = []
        var changes: [PermissionTargetChange] = []
        var commands: [String] = []
        var handled: Set<String> = []
        var revoked = false
        for target in targets {
            let mapped: [String]
            switch target {
            case .service(.all):
                mapped = state.runtime.map(\.name)
                if mapped.isEmpty { notes.append("\(package) requests no runtime permissions, so there was nothing to \(action.rawValue).") }
            case .service(let service):
                mapped = service.androidPermissions ?? []
            case .androidPermission(let permission):
                mapped = [permission]
            }
            let present = mapped.filter { state.isGranted($0) != nil }
            if present.isEmpty, !mapped.isEmpty {
                let declared = mapped.filter(state.requested.contains)
                if !declared.isEmpty {
                    throw DeviceSettingsError("\(declared.joined(separator: ", ")) is not a runtime permission of \(package), so it cannot be granted or revoked.")
                }
                let entries = mapped.map { "<uses-permission android:name=\"\($0)\" />" }.joined(separator: ", ")
                throw DeviceSettingsError("\(package) requests none of \(target.name)'s permissions. Its manifest needs \(entries).")
            }
            let missing = mapped.filter { state.isGranted($0) == nil }
            if !missing.isEmpty, case .service(let service) = target, service != .all {
                notes.append("\(package) does not request \(missing.joined(separator: ", ")); \(action.rawValue) applied to \(present.joined(separator: ", ")).")
            }
            var entries: [PermissionEntry] = []
            for permission in present {
                let granted = state.isGranted(permission) == true
                let previous: PermissionState = granted ? .granted : .denied
                let first = handled.insert(permission).inserted
                switch action {
                case .grant:
                    if !granted, first { commands.append("pm grant \(package) \(permission)") }
                    entries.append(PermissionEntry(name: permission, previous: previous, current: .granted, changed: !granted))
                case .revoke:
                    if granted, first { commands.append("pm revoke \(package) \(permission)"); revoked = true }
                    entries.append(PermissionEntry(name: permission, previous: previous, current: .denied, changed: granted))
                case .reset:
                    let staysFixed = !state.clearsFlags && state.userFixed.contains(permission)
                    if first {
                        commands.append(state.clearsFlags
                            ? "pm revoke \(package) \(permission) && pm clear-permission-flags \(package) \(permission) user-set user-fixed"
                            : "pm revoke \(package) \(permission)")
                        if staysFixed {
                            notes.append("Android 12 and earlier cannot clear \(permission)'s user-fixed flag from the shell, so \(package) will not ask for it again until it is reinstalled.")
                        }
                    }
                    revoked = revoked || granted
                    entries.append(PermissionEntry(name: permission, previous: previous, current: staysFixed ? .denied : .notDetermined, changed: granted ? true : nil))
                }
            }
            changes.append(PermissionTargetChange(target: target.name, permissions: entries))
        }
        if action == .reset, targets.contains(.service(.all)) {
            commands.append("appops reset \(package)")
        }
        return AndroidPermissionPlan(
            script: commands.isEmpty ? nil : commands.joined(separator: " && "),
            change: PermissionChange(action: action, targets: changes, notes: notes, appStopped: revoked)
        )
    }

    /// The API level on the first line, then the dump; the script's status is dumpsys's.
    public static func readScript(package: String) -> String {
        "getprop ro.build.version.sdk; dumpsys package \(package)"
    }

    public static let dangerousScript = "pm list permissions -g -d"
}

public enum IOSPermissionArguments {
    public static func arguments(_ action: PermissionAction, service: PermissionService, udid: String, bundleID: String) -> [String] {
        ["simctl", "privacy", udid, action.rawValue, service.iosName ?? service.rawValue, bundleID]
    }

    /// No read exists on iOS, so the previous value is unknown.
    public static func change(_ action: PermissionAction, services: [PermissionService]) -> PermissionChange {
        let current: PermissionState = action == .grant ? .granted : action == .revoke ? .denied : .notDetermined
        return PermissionChange(
            action: action,
            targets: services.map { PermissionTargetChange(target: $0.rawValue, permissions: [PermissionEntry(name: $0.iosName ?? $0.rawValue, previous: nil, current: current, changed: nil)]) },
            notes: [],
            appStopped: false
        )
    }
}
