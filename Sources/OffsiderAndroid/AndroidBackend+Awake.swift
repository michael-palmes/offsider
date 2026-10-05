import Foundation
import OffsiderCore

extension AndroidBackend: AwakeControlling {
    static let awakePollInterval: Duration = .milliseconds(200)
    /// About 3 s on a phone, where each read takes about 0.2 s.
    static let wakePolls = 8
    /// A PIN, pattern or password lock screen stays up, so `wake` stops waiting once the screen has been on this many polls.
    static let securePolls = 3
    static let codePolls = 10

    public func awakeState(on id: DeviceID) async throws -> AwakeReading {
        let output = try await settingsShell(AndroidAwakeState.readScript, on: id.rawValue)
        guard let reading = AndroidAwakeState.parse(output) else {
            throw AndroidError.awakeStateUnreadable(id.rawValue, output: output)
        }
        return reading
    }

    /// One round trip: the reading, the setting written, then read back.
    public func setStayAwake(_ on: Bool, on id: DeviceID) async throws -> (previous: AwakeReading, current: AwakeReading) {
        let output = try await settingsShell(AndroidAwakeState.setScript(on), on: id.rawValue, timeout: .seconds(15))
        guard let (before, after) = AndroidAwakeState.parseSet(output) else {
            throw AndroidError.awakeStateUnreadable(id.rawValue, output: output)
        }
        var current = before
        current.stayAwake = after
        return (before, current)
    }

    /// Sends nothing when the screen is on and unlocked; otherwise wakes it, dismisses the lock screen and waits for the result.
    public func wake(on id: DeviceID) async throws -> WakeOutcome {
        let serial = id.rawValue
        let before = try await awakeState(on: id)
        guard let (script, firstSent) = AndroidAwakeState.wakeScript(screenOn: before.screen == .on, lockScreen: before.lockScreen) else {
            return WakeOutcome(previous: before, current: before, sent: [])
        }
        var sent = firstSent
        _ = try await settingsShell(script, on: serial)
        var current = before
        var securePolls = 0
        for _ in 0..<Self.wakePolls {
            try await host.sleep(Self.awakePollInterval)
            current = try await awakeState(on: id)
            if current.isUsable { break }
            guard current.screen == .on else { continue }
            // A lock screen can appear only once the screen is on.
            if current.lockScreen != .hidden, !sent.contains("dismiss-keyguard") {
                _ = try await settingsShell("wm dismiss-keyguard", on: serial)
                sent.append("dismiss-keyguard")
            }
            if current.lockScreen == .secure {
                securePolls += 1
                if securePolls >= Self.securePolls { break }
            }
        }
        return WakeOutcome(previous: before, current: current, sent: sent)
    }

    /// Types nothing unless the lock screen is up with its PIN or password field focused, read again just before typing.
    public func enterUnlockCode(_ code: UnlockCode, on id: DeviceID) async throws -> AwakeReading {
        let serial = id.rawValue
        guard try await codeFieldShowing(id) else { throw AndroidError.codeFieldMissing(serial) }
        let state = try await awakeState(on: id)
        guard state.screen == .on, state.lockScreen == .secure else { return state }
        let result = try await requireClient().shell(AndroidAwakeState.codeScript(code), on: serial, timeout: .seconds(15), label: AndroidAwakeState.codeLabel)
        guard result.status == 0 else {
            throw AndroidError.adbCommandFailed(serial: serial, command: AndroidAwakeState.codeLabel, detail: "exit status \(result.status)")
        }
        var current = state
        for _ in 0..<Self.codePolls {
            try await host.sleep(Self.awakePollInterval)
            current = try await awakeState(on: id)
            if current.lockScreen != .secure { break }
        }
        return current
    }

    /// Up to three tree reads, asking for the code field between them: a fingerprint bouncer shows none.
    private func codeFieldShowing(_ id: DeviceID) async throws -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 {
                _ = try await settingsShell("wm dismiss-keyguard", on: id.rawValue)
                try await host.sleep(.milliseconds(600))
            }
            do {
                let roots = try await accessibilityTree(for: id, point: nil).roots
                if AndroidAwakeState.lockScreenCodeField(in: roots) != nil { return true }
            } catch let error as AndroidError where error.kind == .noWindow {
                continue
            }
        }
        return false
    }
}
