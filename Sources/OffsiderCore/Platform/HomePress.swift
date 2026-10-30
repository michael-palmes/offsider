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
    /// Nil when the foreground could not be read.
    public let before: ForegroundActivities?
    public let after: ForegroundActivities?
    /// Why the launcher could not be checked; the key was still sent.
    public var unreadable: String? = nil
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
        let before: ForegroundActivities
        do {
            before = try await read()
        } catch let error where !(error is CancellationError) {
            try await sendKey()
            return HomePressOutcome(reached: false, via: nil, before: nil, after: nil, unreadable: describe(error))
        }
        try await sendKey()
        do {
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
        } catch let error where !(error is CancellationError) {
            return HomePressOutcome(reached: false, via: nil, before: before, after: nil, unreadable: describe(error))
        }
    }

    /// An app of the launcher's package is on top (its HOME entry may be an alias of another class); when the launcher is unknown, any change of activity counts.
    static func isHome(_ reading: ForegroundActivities, before: ForegroundActivities) -> Bool {
        guard let top = reading.top else { return false }
        if let home = reading.home ?? before.home { return package(of: top) == package(of: home) }
        return top != before.top
    }

    static func package(of component: String) -> Substring {
        component.split(separator: "/", maxSplits: 1).first ?? ""
    }

    private static func describe(_ error: any Error) -> String {
        (error as? any OffsiderFailure)?.failureMessage ?? error.localizedDescription
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

/// iOS simulator `button home --verify`: what answers at the screen's centre, which takes a fraction of a tree read, tells SpringBoard from an app.
public enum SimulatorHomePress {
    public static let poll: Duration = .milliseconds(100)
    public static let window: TimeInterval = 5

    public enum Outcome: Equatable, Sendable {
        case reached(presses: Int)
        case notReached(presses: Int)
        /// No read answered, so Offsider cannot say where the press went.
        case unreadable(presses: Int)
    }

    /// Presses, then reads until SpringBoard answers; a second press only after a whole `window` with no sign of it. SpringBoard hosts alerts over an app as well as the home screen, so an answer before the press proves nothing. `isHome` is nil for a read that failed.
    public static func run(
        isHome: () async -> Bool?,
        press: () async throws -> Void,
        sleep: (Duration) async throws -> Void,
        now: () -> TimeInterval,
        attempts: Int,
        window: TimeInterval = window
    ) async throws -> Outcome {
        var presses = 0
        var readable = false
        for _ in 0..<max(1, attempts) {
            try await press()
            presses += 1
            let deadline = now() + window
            repeat {
                let home = await isHome()
                if home == true { return .reached(presses: presses) }
                readable = readable || home != nil
                try await sleep(poll)
            } while now() < deadline
        }
        return readable ? .notReached(presses: presses) : .unreadable(presses: presses)
    }

    /// The process path idb's point read gave belongs to SpringBoard.
    public static func isSpringBoard(path: String) -> Bool {
        path.hasSuffix("/SpringBoard")
    }
}
