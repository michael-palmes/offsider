import Foundation
import OffsiderCore

extension IOSBackend: SimulatorLockReading {
    func lockScreen(on id: DeviceID) async throws -> SimulatorLockScreen {
        try await Self.lockScreen(of: id)
    }

    /// Needs no backend, so `button lock` can wait for the lock screen without opening one.
    nonisolated static func lockScreen(of id: DeviceID) async throws -> SimulatorLockScreen {
        let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: SimulatorLockScreen.readArguments(udid: id.rawValue), timeout: 5)
        guard result.status == 0, let reading = SimulatorLockScreen.parse(result.stdout) else {
            let detail = result.stderr.split(whereSeparator: \.isNewline).first.map { TerminalText.line(String($0), cap: 200) } ?? "no lock state"
            throw CLIError(
                errorDescription: "Offsider could not read the lock screen of simulator \(id.rawValue) (\(detail)), so it pressed nothing. Run `offsider doctor --device \(id.rawValue)`.",
                reason: .commandFailed, hint: "offsider doctor --device \(id.rawValue)"
            )
        }
        return reading
    }
}
