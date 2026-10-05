import Foundation

/// Power sources as Android's `BatteryManager.BATTERY_PLUGGED_*` bits.
public struct PowerSources: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let ac = PowerSources(rawValue: 1)
    public static let usb = PowerSources(rawValue: 2)
    public static let wireless = PowerSources(rawValue: 4)
    public static let dock = PowerSources(rawValue: 8)

    /// `ac`, `usb`, `wireless` and `dock` in bit order; unknown bits are left out.
    public var names: [String] {
        [(PowerSources.ac, "ac"), (.usb, "usb"), (.wireless, "wireless"), (.dock, "dock")].filter { contains($0.0) }.map(\.1)
    }

    /// `AC, USB, wireless and dock` for text output.
    public var summary: String {
        let words = names.map { $0.count <= 3 ? $0.uppercased() : $0 }
        guard words.count > 1 else { return words.first ?? "none" }
        return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }
}

/// Android's `mWakefulness`: input reaches apps only while the screen is on.
public enum ScreenPower: String, Equatable, Sendable {
    case on
    case off
    /// Always-on display.
    case dozing
    /// A screen saver.
    case dreaming
}

/// The lock screen in front of apps; an app shown over it (occluding it) counts as hidden.
public enum LockScreen: Equatable, Sendable {
    case hidden
    /// Dismissed by `wm dismiss-keyguard`.
    case swipe
    /// A PIN, pattern or password.
    case secure

    public var name: String {
        switch self {
        case .hidden: return "hidden"
        case .swipe: return "swipe"
        case .secure: return "secure"
        }
    }
}

/// Screen, lock screen and stay-awake state from one adb round trip.
public struct AwakeReading: Equatable, Sendable {
    public var screen: ScreenPower
    public var lockScreen: LockScreen
    /// `pin`, `pattern` or `password` when a credential is set and lock settings name it.
    public var credential: String?
    /// The stay-awake setting: the sources that keep the screen on while charging.
    public var stayAwake: PowerSources
    /// Empty when not charging.
    public var charging: PowerSources
    public var screenTimeoutMilliseconds: Int?
    /// A device policy caps the screen timeout, which makes Android ignore stay awake.
    public var timeoutCappedByPolicy: Bool
    /// `ro.product.manufacturer`, read in the same round trip, for naming a phone.
    public var maker: String?

    public init(
        screen: ScreenPower,
        lockScreen: LockScreen,
        credential: String? = nil,
        stayAwake: PowerSources = [],
        charging: PowerSources = [],
        screenTimeoutMilliseconds: Int? = nil,
        timeoutCappedByPolicy: Bool = false,
        maker: String? = nil
    ) {
        self.screen = screen
        self.lockScreen = lockScreen
        self.credential = credential
        self.stayAwake = stayAwake
        self.charging = charging
        self.screenTimeoutMilliseconds = screenTimeoutMilliseconds
        self.timeoutCappedByPolicy = timeoutCappedByPolicy
        self.maker = maker
    }

    /// Input reaches the app in front.
    public var isUsable: Bool { screen == .on && lockScreen == .hidden }

    /// Stay awake keeps the screen on right now: a chosen source is charging and no policy overrides it.
    public var staysAwake: Bool { !stayAwake.intersection(charging).isEmpty && !timeoutCappedByPolicy }

    /// `PIN`, `pattern` or `password`, else `PIN, pattern or password`.
    public var credentialName: String {
        switch credential {
        case "pin": return "PIN"
        case let name?: return name
        case nil: return "PIN, pattern or password"
        }
    }

    /// `30 min`, `15 s`, `never`; nil when unknown.
    public var screenTimeoutSummary: String? {
        guard let milliseconds = screenTimeoutMilliseconds else { return nil }
        if milliseconds >= Int(Int32.max) { return "never" }
        let seconds = milliseconds / 1000
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    /// One phrase for the screen and lock screen: `on and unlocked`, `off, PIN lock screen`.
    public var screenSummary: String {
        let screen: String
        switch self.screen {
        case .on: screen = "on"
        case .off: screen = "off"
        case .dozing: screen = "off (always-on display)"
        case .dreaming: screen = "showing a screen saver"
        }
        switch lockScreen {
        case .hidden: return "\(screen) and unlocked"
        case .swipe: return "\(screen), swipe lock screen showing"
        case .secure: return "\(screen), \(credentialName) lock screen showing"
        }
    }
}

/// What typing a saved code did.
public struct UnlockAttempt: Equatable, Sendable {
    /// False when the screen turned off or the lock screen went before typing, so nothing was sent.
    public let typed: Bool
    public let reading: AwakeReading

    public init(typed: Bool, reading: AwakeReading) {
        self.typed = typed
        self.reading = reading
    }
}

/// What `wake` did and found.
public struct WakeOutcome: Equatable, Sendable {
    public let previous: AwakeReading
    public let current: AwakeReading
    /// `KEYCODE_WAKEUP`, `dismiss-keyguard` and `code` (never the code itself), in the order sent.
    public let sent: [String]

    public init(previous: AwakeReading, current: AwakeReading, sent: [String]) {
        self.previous = previous
        self.current = current
        self.sent = sent
    }
}

extension DeviceStateReport {
    static func screen(_ reading: AwakeReading) -> OrderedJSON {
        .object([
            ("screen", .string(reading.screen.rawValue)),
            ("lockScreen", .string(reading.lockScreen.name)),
            ("credential", .optional(reading.credential) { .string($0) }),
        ])
    }

    public static func stayAwake(_ action: String, current: AwakeReading, previous: AwakeReading?, on device: DeviceID) -> String {
        OrderedJSON.object(header(action, device: device) + [
            ("stayAwake", .bool(!current.stayAwake.isEmpty)),
            ("previous", .optional(previous) { .bool(!$0.stayAwake.isEmpty) }),
            ("sources", .array(current.stayAwake.names.map { .string($0) })),
            ("charging", .array(current.charging.names.map { .string($0) })),
            ("effective", .bool(current.staysAwake)),
            ("timeoutCappedByPolicy", .bool(current.timeoutCappedByPolicy)),
            ("screenTimeoutMs", .optional(current.screenTimeoutMilliseconds) { .integer($0) }),
            ("current", screen(current)),
        ]).rendered(compact: true)
    }

    public static func wake(_ outcome: WakeOutcome, on device: DeviceID) -> String {
        OrderedJSON.object(header("wake", device: device) + [
            ("sent", .array(outcome.sent.map { .string($0) })),
            ("previous", screen(outcome.previous)),
            ("current", screen(outcome.current)),
        ]).rendered(compact: true)
    }

    /// `unlock-code`: whether a code is saved, never the code.
    public static func unlockCode(_ action: String, device: String, saved: Bool, lastAttemptFailed: Bool) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("action", .string(action)),
            ("device", .string(device)),
            ("saved", .bool(saved)),
            ("lastAttemptFailed", .bool(lastAttemptFailed)),
        ]).rendered(compact: true)
    }
}
