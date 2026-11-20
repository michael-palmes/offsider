import Foundation

/// An iOS simulator's lock screen, from SpringBoard's own notify state.
public struct SimulatorLockScreen: Equatable, Sendable {
    /// `com.apple.springboard.lockstate`: the lock screen is up, lit or not.
    public let locked: Bool
    /// `com.apple.springboard.hasBlankedScreen`: the display is dark, as after `button lock`.
    public let blanked: Bool

    public init(locked: Bool, blanked: Bool) {
        self.locked = locked
        self.blanked = blanked
    }

    public static let lockKey = "com.apple.springboard.lockstate"
    public static let blankKey = "com.apple.springboard.hasBlankedScreen"

    /// Both flags in one spawn, about 0.15 s.
    public static func readArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, "notifyutil", "-g", lockKey, "-g", blankKey]
    }

    /// Nil unless `notifyutil -g` printed both flags as `<key> <number>`.
    public static func parse(_ output: String) -> SimulatorLockScreen? {
        var flags: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count == 2, let value = Int(tokens[1]) else { continue }
            flags[String(tokens[0])] = value != 0
        }
        guard let locked = flags[lockKey], let blanked = flags[blankKey] else { return nil }
        return SimulatorLockScreen(locked: locked, blanked: blanked)
    }
}

/// Reads and clears an iOS simulator's lock screen. A swipe up can freeze the display while the tree moves on, so this presses Home only.
@MainActor
public protocol SimulatorLockReading: DeviceBackend {
    func lockScreen(on id: DeviceID) async throws -> SimulatorLockScreen
}

/// `wake` on an iOS simulator: Home at most twice, the first to light a dark display, stopping once the lock screen has gone.
public enum SimulatorWake {
    public static let maximumPresses = 2
    public static let poll: Duration = .milliseconds(100)
    /// How long each press has to clear the lock screen before the next.
    public static let window: TimeInterval = 1.5
    /// Two presses closer than this are a double press, which opens Wallet or the app switcher instead.
    public static let gap: TimeInterval = 0.5

    /// SpringBoard raises the lock state up to a second after the lock button, so `button lock` waits this long for it.
    public static let lockRise: TimeInterval = 1.5

    /// True once the lock screen reads as up, within `limit`; a `wake` sent before that would find nothing to clear.
    public static func awaitLocked(
        read: () async throws -> SimulatorLockScreen, sleep: (Duration) async throws -> Void, now: () -> TimeInterval, limit: TimeInterval = lockRise
    ) async -> Bool {
        let deadline = now() + limit
        while true {
            if (try? await read())?.locked == true { return true }
            guard now() < deadline, (try? await sleep(poll)) != nil else { return false }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case alreadyUnlocked(SimulatorLockScreen)
        case unlocked(before: SimulatorLockScreen, presses: Int)
        case stillLocked(before: SimulatorLockScreen, presses: Int)
        /// No read answered after the presses, so Offsider cannot say whether they worked.
        case unconfirmed(before: SimulatorLockScreen, presses: Int)
    }

    /// A first read that fails throws with nothing pressed. A read that fails after a press counts as no answer and the wait goes on.
    public static func run(
        read: () async throws -> SimulatorLockScreen,
        press: () async throws -> Void,
        sleep: (Duration) async throws -> Void,
        now: () -> TimeInterval,
        window: TimeInterval = window,
        gap: TimeInterval = gap
    ) async throws -> Outcome {
        let before = try await read()
        guard before.locked else { return .alreadyUnlocked(before) }
        var latest = before
        var answered = false
        var pressedAt = now()
        for presses in 1...maximumPresses {
            if presses > 1 {
                let wait = pressedAt + gap - now()
                if wait > 0 { try await sleep(.milliseconds(Int((wait * 1000).rounded(.up)))) }
            }
            let dark = latest.blanked
            try await press()
            pressedAt = now()
            answered = false
            let deadline = pressedAt + window
            repeat {
                try await sleep(poll)
                guard let reading = try? await read() else { continue }
                (latest, answered) = (reading, true)
                if !reading.locked { return .unlocked(before: before, presses: presses) }
                // This press only lit the display, so the next can follow once a double press is ruled out.
                if dark, !reading.blanked, presses < maximumPresses { break }
            } while now() < deadline
        }
        return answered ? .stillLocked(before: before, presses: maximumPresses) : .unconfirmed(before: before, presses: maximumPresses)
    }
}
