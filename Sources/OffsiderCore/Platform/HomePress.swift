import Foundation

/// The resumed activity and the launcher Android would start for HOME, as `package/Class` components.
public struct ForegroundActivities: Equatable, Sendable {
    public let top: String?
    public let home: String?

    public init(top: String?, home: String?) {
        self.top = top
        self.home = home
    }
}

/// Reads the foreground activity and starts the HOME intent; Android only.
public protocol ForegroundReading: DeviceBackend {
    func foreground(on id: DeviceID) async throws -> ForegroundActivities
    func startHomeIntent(on id: DeviceID) async throws
}

/// What `button home` did on Android: the key, or the HOME intent after the key was ignored.
public struct HomePressOutcome: Equatable, Sendable {
    public enum Via: String, Sendable {
        case key
        case intent
    }

    public let reached: Bool
    /// Nil when the launcher never came to the front.
    public let via: Via?
    public let before: ForegroundActivities
    public let after: ForegroundActivities
}

/// Some emulator images drop KEYCODE_HOME while an app is in front; the HOME intent reaches the launcher instead.
public enum HomePress {
    public static let poll: Duration = .milliseconds(250)
    public static let window: Duration = .seconds(2)

    public static func run(
        read: () async throws -> ForegroundActivities,
        sendKey: () async throws -> Void,
        sendIntent: () async throws -> Void,
        sleep: (Duration) async throws -> Void,
        window: Duration = window
    ) async throws -> HomePressOutcome {
        let before = try await read()
        try await sendKey()
        var after = try await settle(read: read, sleep: sleep, window: window, isHome: { isHome($0, before: before) })
        if isHome(after, before: before) {
            return HomePressOutcome(reached: true, via: .key, before: before, after: after)
        }
        guard after.top == before.top else {
            return HomePressOutcome(reached: false, via: nil, before: before, after: after)
        }
        try await sendIntent()
        after = try await settle(read: read, sleep: sleep, window: window, isHome: { isHome($0, before: before) })
        let reached = isHome(after, before: before)
        return HomePressOutcome(reached: reached, via: reached ? .intent : nil, before: before, after: after)
    }

    /// The launcher is on top; when the launcher is unknown, any change of activity counts.
    static func isHome(_ reading: ForegroundActivities, before: ForegroundActivities) -> Bool {
        guard let top = reading.top else { return false }
        if let home = reading.home ?? before.home { return top == home }
        return top != before.top
    }

    private static func settle(
        read: () async throws -> ForegroundActivities,
        sleep: (Duration) async throws -> Void,
        window: Duration,
        isHome: (ForegroundActivities) -> Bool
    ) async throws -> ForegroundActivities {
        var reading = try await read()
        var waited = Duration.zero
        while !isHome(reading), waited < window {
            try await sleep(poll)
            waited += poll
            reading = try await read()
        }
        return reading
    }
}
