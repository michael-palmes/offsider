import Foundation
import OffsiderCore

/// What `sleep` or `wake` found and did on an iPhone or iPad.
public struct IOSDeviceScreenChange: Equatable, Sendable {
    public let wasOn: Bool
    public let wasLocked: Bool
    /// Presses sent; 0 when the screen was already as asked.
    public let presses: Int

    public init(wasOn: Bool, wasLocked: Bool, presses: Int) {
        self.wasOn = wasOn
        self.wasLocked = wasLocked
        self.presses = presses
    }
}

extension IOSDeviceBackend: ScreenSleeping {
    public func sleepScreen(on id: DeviceID) async throws -> ScreenSleepOutcome {
        let change = try await sleepScreen(id)
        return ScreenSleepOutcome(wasOn: change.wasOn, sent: change.presses > 0)
    }
}

extension IOSDeviceBackend {
    /// A press registers within about a second; a second Home sooner reads as a double press.
    static let screenPollInterval: Duration = .milliseconds(100)
    static let screenSettle: Duration = .seconds(2)
    /// One wakes the screen, one clears a lock screen with no passcode; a passcode stays up.
    static let maximumHomePresses = 2

    private func waitForScreen(_ client: RunnerClient, until done: (RunnerScreen) -> Bool) async throws -> RunnerScreen {
        var screen = try await client.screen()
        let clock = ContinuousClock()
        let deadline = clock.now + Self.screenSettle
        while !done(screen), clock.now < deadline {
            try await Task.sleep(for: Self.screenPollInterval)
            screen = try await client.screen()
        }
        return screen
    }

    /// Reads first, as pressing lock on a dark screen would light it. Reads nothing from the screen itself and needs no app in front.
    public func sleepScreen(_ id: DeviceID) async throws -> IOSDeviceScreenChange {
        try await requireWired(id)
        let client = try await runner(for: id)
        let before = try await client.screen()
        var presses = 0
        // The first press may only close a sheet such as Siri's, so one more is allowed.
        var screen = before
        while screen.on, presses < 2 {
            try await client.pressLock()
            presses += 1
            screen = try await waitForScreen(client) { !$0.on }
        }
        guard !screen.on else {
            throw IOSDeviceError(.stateNotReached, "The screen of \(id.rawValue) stayed on after two lock presses. Check the device, then retry.")
        }
        if state.drivesWhole { sessionStore.markAsleep(udid: id.rawValue) }
        return IOSDeviceScreenChange(wasOn: before.on, wasLocked: before.locked, presses: presses)
    }

    /// Sends nothing to a screen already on and unlocked; otherwise presses Home until the lock screen clears, leaving a passcode for a person.
    public func wakeScreen(_ id: DeviceID) async throws -> IOSDeviceScreenChange {
        try await requireWired(id)
        let client = try await runner(for: id)
        let before = try await client.screen()
        var screen = before
        var presses = 0
        while screen.locked || !screen.on, presses < Self.maximumHomePresses {
            let last = screen
            try await client.home()
            presses += 1
            screen = try await waitForScreen(client) { $0 != last }
            if screen.locked || !screen.on { try await Task.sleep(for: .milliseconds(600)) }
        }
        sessionStore.clearAsleep(udid: id.rawValue)
        guard !screen.locked, screen.on else {
            throw IOSDeviceError(.locked, "The screen of \(id.rawValue) is on, but its passcode is up. Unlock it by hand; Offsider never types a passcode.")
        }
        return IOSDeviceScreenChange(wasOn: before.on, wasLocked: before.locked, presses: presses)
    }

    /// Wakes a screen Offsider put to sleep, and tells the broker a command came even when it needs nothing from it, so its idle sleep waits for the last one.
    func prepareWholeDevice(_ id: DeviceID) async throws {
        let udid = id.rawValue
        if state.awakeChecked.insert(udid).inserted, sessionStore.isMarkedAsleep(udid: udid) {
            _ = try await wakeScreen(id)
        }
        guard hostHasHID, sessionsAvailable else { return }
        let now = Date()
        if let last = state.brokerNudged[udid], now.timeIntervalSince(last) < 60 { return }
        state.brokerNudged[udid] = now
        _ = try? await session(for: id).ping()
    }

    var sessionStore: DeviceSessionStore { DeviceSessionStore(root: host.privateRoot) }
}
