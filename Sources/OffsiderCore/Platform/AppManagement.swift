import Foundation

/// Optional capability: installing and removing one app, reading its preference names and sending a broadcast to it. Android only.
@MainActor
public protocol AppManaging: DeviceBackend {
    /// Streams the APK with `app` as the package it must declare, which the device enforces too.
    func installApp(_ file: ApkFile, as app: String, on id: DeviceID) async throws -> AppInstall
    func uninstallApp(_ app: String, on id: DeviceID) async throws -> AppUninstall
    func appPreferences(_ app: String, on id: DeviceID) async throws -> AppPreferences
    func sendBroadcast(_ action: String, receiver: String?, to app: String, on id: DeviceID) async throws -> AppBroadcast
}

public struct AppInstall: Equatable, Sendable {
    public var app: String
    public var replaced: Bool
    public var bytes: Int
    public var milliseconds: Int

    public init(app: String, replaced: Bool, bytes: Int, milliseconds: Int) {
        self.app = app
        self.replaced = replaced
        self.bytes = bytes
        self.milliseconds = milliseconds
    }
}

public struct AppUninstall: Equatable, Sendable {
    public var app: String
    public var wasInstalled: Bool

    public init(app: String, wasInstalled: Bool) {
        self.app = app
        self.wasInstalled = wasInstalled
    }
}

/// One preference file's key names and types. There is deliberately no place here for a value, a length or a hash.
public struct AppPreferenceFile: Equatable, Sendable {
    public struct Key: Equatable, Sendable {
        public var name: String
        public var type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public var name: String
    public var keys: [Key]
    /// Android's binary XML, which `grep` cannot read; its keys stay unlisted.
    public var binary: Bool

    public init(name: String, keys: [Key], binary: Bool = false) {
        self.name = name
        self.keys = keys
        self.binary = binary
    }
}

public struct AppPreferences: Equatable, Sendable {
    public var app: String
    public var files: [AppPreferenceFile]

    public init(app: String, files: [AppPreferenceFile]) {
        self.app = app
        self.files = files
    }

    public var keyCount: Int { files.reduce(0) { $0 + $1.keys.count } }
}

public struct AppBroadcast: Equatable, Sendable {
    public var app: String
    public var action: String
    public var receiver: String?
    /// The receivers the app's manifest lists for this action; empty leaves only one registered while the app runs.
    public var receivers: [String]
    public var resultCode: Int?

    public init(app: String, action: String, receiver: String?, receivers: [String], resultCode: Int?) {
        self.app = app
        self.action = action
        self.receiver = receiver
        self.receivers = receivers
        self.resultCode = resultCode
    }
}

/// Optional capability: Android's airplane mode. A change Offsider made is recorded, so `session stop` undoes that and nothing else.
@MainActor
public protocol AirplaneControlling: DeviceBackend {
    func airplaneMode(on id: DeviceID) async throws -> Bool
    func setAirplaneMode(_ enabled: Bool, on id: DeviceID) async throws -> AirplaneChange
}

public struct AirplaneChange: Equatable, Sendable {
    public var previous: Bool
    public var current: Bool
    /// True when Offsider turned it on, so `session stop` turns it off.
    public var resetBySessionStop: Bool

    public init(previous: Bool, current: Bool, resetBySessionStop: Bool) {
        self.previous = previous
        self.current = current
        self.resetBySessionStop = resetBySessionStop
    }
}

/// The action and receiver names `app broadcast` sends, checked before they reach a shell.
public enum AppBroadcastName {
    public static let maximumLength = 256

    public static func validate(action: String) throws -> String {
        guard !action.isEmpty, action.utf8.count <= maximumLength, action.range(of: #"^[A-Za-z][A-Za-z0-9_.$-]*\z"#, options: .regularExpression) != nil else {
            throw AppLifecycleError(.failed, "The action must be letters, digits, dots, underscores or dashes, at most \(maximumLength) characters, such as com.example.app.action.REFRESH.")
        }
        return action
    }

    /// A class in the app: `.Receiver` or `com.example.app.Receiver`. Never another app's component: the package is always the one allowed.
    public static func validate(receiver: String) throws -> String {
        guard receiver.utf8.count <= maximumLength, receiver.range(of: #"^\.?[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)*\z"#, options: .regularExpression) != nil else {
            throw AppLifecycleError(.failed, "The receiver must be a class in the app, such as .RefreshReceiver or com.example.app.RefreshReceiver.")
        }
        return receiver
    }
}

/// `--json` for `app install`, `uninstall`, `prefs` and `broadcast`, in schema order.
public enum AppManagementReport {
    public static func install(_ install: AppInstall, apk: String, on device: DeviceID) -> String {
        OrderedJSON.object(AppReport.header("install", app: install.app, device: device) + [
            ("apk", .string(apk)),
            ("replaced", .bool(install.replaced)),
            ("bytes", .integer(install.bytes)),
            ("milliseconds", .integer(install.milliseconds)),
        ]).rendered(compact: true)
    }

    public static func uninstall(_ uninstall: AppUninstall, on device: DeviceID) -> String {
        OrderedJSON.object(AppReport.header("uninstall", app: uninstall.app, device: device) + [
            ("wasInstalled", .bool(uninstall.wasInstalled)),
        ]).rendered(compact: true)
    }

    public static func preferences(_ preferences: AppPreferences, on device: DeviceID) -> String {
        let files = preferences.files.map { file -> OrderedJSON in
            .object([
                ("name", .string(file.name)),
                ("binary", .bool(file.binary)),
                ("keys", .array(file.keys.map { .object([("name", .string($0.name)), ("type", .string($0.type))]) })),
            ])
        }
        let document = OrderedJSON.object(AppReport.header("prefs", app: preferences.app, device: device) + [("files", .array(files))])
        return UntrustedPaths.marked(document, ["files[].name", "files[].keys[].name"]).rendered(compact: true)
    }

    public static func broadcast(_ broadcast: AppBroadcast, on device: DeviceID) -> String {
        OrderedJSON.object(AppReport.header("broadcast", app: broadcast.app, device: device) + [
            ("actionName", .string(broadcast.action)),
            ("receiver", .optional(broadcast.receiver) { .string($0) }),
            ("receivers", .array(broadcast.receivers.map { .string($0) })),
            ("resultCode", .optional(broadcast.resultCode) { .integer($0) }),
        ]).rendered(compact: true)
    }

    public static func airplane(_ action: String, current: Bool, previous: Bool?, resetBySessionStop: Bool, on device: DeviceID) -> String {
        let word: (Bool) -> OrderedJSON = { .string($0 ? "on" : "off") }
        return OrderedJSON.object([
            ("version", .integer(1)), ("action", .string(action)), ("device", .string(device.rawValue)), ("platform", .string(device.platform.rawValue)),
            ("airplane", word(current)),
            ("previous", .optional(previous, word)),
            ("resetBySessionStop", .bool(resetBySessionStop)),
        ]).rendered(compact: true)
    }
}
