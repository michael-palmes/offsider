import Foundation

/// Optional capability: reading, launching, stopping and sending a link to one installed app, and nothing else on the device.
@MainActor
public protocol AppLifecycleControlling: DeviceBackend {
    func appInfo(_ app: String, on id: DeviceID) async throws -> AppInfo
    func launchApp(_ app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch
    func terminateApp(_ app: String, on id: DeviceID) async throws -> AppStop
    /// Delivers `url` to `app` alone, never to a chooser or the device's default handler, except on an iOS simulator.
    func openLink(_ url: String, in app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch
}

/// What one installed app reports about itself; nil wherever the platform does not say.
public struct AppInfo: Equatable, Sendable {
    public var app: String
    public var name: String?
    public var version: String?
    public var build: String?
    /// Android's installer package, or `developer` for an iPhone app built and installed by a developer.
    public var installer: String?
    public var firstInstalled: Date?
    public var lastUpdated: Date?
    /// Android 13 and later: whether the app may post notifications.
    public var notifications: Bool?
    public var debuggable: Bool?

    public init(
        app: String, name: String? = nil, version: String? = nil, build: String? = nil, installer: String? = nil,
        firstInstalled: Date? = nil, lastUpdated: Date? = nil, notifications: Bool? = nil, debuggable: Bool? = nil
    ) {
        self.app = app
        self.name = name
        self.version = version
        self.build = build
        self.installer = installer
        self.firstInstalled = firstInstalled
        self.lastUpdated = lastUpdated
        self.notifications = notifications
        self.debuggable = debuggable
    }
}

/// Cold: a new process. Warm: the app was already running and came to the front.
public enum AppStart: String, Equatable, Sendable {
    case cold
    case warm
}

public struct AppLaunch: Equatable, Sendable {
    public var app: String
    public var start: AppStart?
    public var restarted: Bool
    /// Android's `TotalTime` from `am start -W`.
    public var milliseconds: Int?
    public var pid: Int?

    public init(app: String, start: AppStart?, restarted: Bool, milliseconds: Int? = nil, pid: Int? = nil) {
        self.app = app
        self.start = start
        self.restarted = restarted
        self.milliseconds = milliseconds
        self.pid = pid
    }
}

public struct AppStop: Equatable, Sendable {
    public var app: String
    /// Nil when the platform cannot tell.
    public var wasRunning: Bool?

    public init(app: String, wasRunning: Bool?) {
        self.app = app
        self.wasRunning = wasRunning
    }
}

public struct AppLifecycleError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case notInstalled
        case noLauncher
        case linkNotHandled
        case failed
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The links `app open` sends: one line of printable ASCII with a scheme, never one that reaches past the app.
public enum AppLink {
    public static let maximumLength = 4096
    /// `intent:` names another component, `file:` and `content:` reach files and other apps' data, and `javascript:` and `data:` carry code.
    public static let refusedSchemes: Set<String> = ["intent", "file", "content", "javascript", "data"]

    /// The URL, or why it is refused, in one sentence.
    public static func validate(_ url: String) throws -> String {
        guard !url.isEmpty, url.utf8.count <= maximumLength else {
            throw AppLifecycleError(.failed, "The link must be 1 to \(maximumLength) bytes long.")
        }
        guard url.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw AppLifecycleError(.failed, "The link holds a space, a control character or a character outside ASCII; percent-encode it (a space is %20).")
        }
        guard let colon = url.firstIndex(of: ":"),
              url[..<colon].range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil else {
            throw AppLifecycleError(.failed, "The link needs a scheme, such as https://example.com/path or myapp://screen.")
        }
        let scheme = url[..<colon].lowercased()
        guard !refusedSchemes.contains(scheme) else {
            throw AppLifecycleError(.failed, "\(scheme): links are refused: they reach other apps, files or code. Send an https: link or the app's own scheme.")
        }
        return url
    }
}

/// The JSON objects the `app` commands print with `--json`, in schema order.
public enum AppReport {
    static func header(_ action: String, app: String, device: DeviceID) -> [(String, OrderedJSON)] {
        [("version", .integer(1)), ("action", .string(action)), ("device", .string(device.rawValue)), ("platform", .string(device.platform.rawValue)), ("app", .string(app))]
    }

    static let infoUntrusted = ["name", "appVersion", "build", "installer"]

    public static func info(_ info: AppInfo, on device: DeviceID) -> String {
        let date: (Date?) -> OrderedJSON = { value in .optional(value) { .string(ProcessStamp.timestamp($0)) } }
        let document = OrderedJSON.object(header("info", app: info.app, device: device) + [
            ("name", .optional(info.name) { .string($0) }),
            ("appVersion", .optional(info.version) { .string($0) }),
            ("build", .optional(info.build) { .string($0) }),
            ("installer", .optional(info.installer) { .string($0) }),
            ("firstInstalled", date(info.firstInstalled)),
            ("lastUpdated", date(info.lastUpdated)),
            ("notifications", .optional(info.notifications) { .string($0 ? "granted" : "denied") }),
            ("debuggable", .optional(info.debuggable) { .bool($0) }),
        ])
        return UntrustedPaths.marked(document, infoUntrusted).rendered(compact: true)
    }

    public static func launch(_ launch: AppLaunch, action: String, url: String? = nil, on device: DeviceID) -> String {
        var members = header(action, app: launch.app, device: device)
        if let url { members.append(("url", .string(url))) }
        members += [
            ("start", .optional(launch.start) { .string($0.rawValue) }),
            ("restarted", .bool(launch.restarted)),
            ("milliseconds", .optional(launch.milliseconds) { .integer($0) }),
            ("pid", .optional(launch.pid) { .integer($0) }),
        ]
        return OrderedJSON.object(members).rendered(compact: true)
    }

    public static func stop(_ stop: AppStop, on device: DeviceID) -> String {
        OrderedJSON.object(header("stop", app: stop.app, device: device) + [
            ("wasRunning", .optional(stop.wasRunning) { .bool($0) }),
        ]).rendered(compact: true)
    }
}
