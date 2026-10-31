import Foundation
import OffsiderCore

extension AndroidBackend: PostedNotificationReading {
    public func notifications(of app: String, on id: DeviceID) async throws -> NotificationSnapshot {
        let package = try ExpoDevClient.validate(appID: app)
        try await prepare()
        let result = try await requireClient().shell(AndroidNotifications.script(package: package, checksInstalled: !notificationAppsSeen.contains(package)), on: id.rawValue, timeout: .seconds(20), label: "cmd notification")
        if AndroidNotifications.notInstalled(result.stdoutText) {
            throw AndroidError.appNotInstalled(package, serial: id.rawValue, adb: adbPath)
        }
        guard let snapshot = AndroidNotifications.parse(result.stdoutText, package: package) else {
            let detail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText).split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidError.adbCommandFailed(serial: id.rawValue, command: "cmd notification list", detail: detail)
        }
        // Once is enough: a --wait polls each second, and a failed `pm` read must not end it.
        notificationAppsSeen.insert(package)
        return snapshot
    }
}
