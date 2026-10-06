import Foundation
import OffsiderCore

extension AndroidBackend: ForegroundReading {
    public func foreground(on id: DeviceID) async throws -> ForegroundActivities {
        try await prepare()
        let result = try await requireClient().shell(AndroidForeground.readScript, on: id.rawValue, timeout: .seconds(5), label: "dumpsys activity activities; cmd package resolve-activity")
        return AndroidForeground.parse(result.stdoutText)
    }

    public func startHomeIntent(on id: DeviceID) async throws {
        _ = try await settingsShell(AndroidForeground.homeIntent, on: id.rawValue)
    }
}
