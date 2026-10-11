import Foundation
import OffsiderCore

extension AndroidBackend: AppLivenessReading {
    /// One `pidof -s` over the open adb connection; the tree and `mayList` add nothing on Android.
    public func appLiveness(_ appID: String, seen: AppProcess?, tree: UITree?, mayList: Bool, on id: DeviceID) async -> AppLiveness {
        guard let package = try? ExpoDevClient.validate(appID: appID),
              (try? await prepare()) != nil,
              let client = try? requireClient(),
              let result = try? await client.shell(LogcatCommand.pidScript(for: package), on: id.rawValue, label: "pidof") else { return .unknown }
        return Self.liveness(pidofOutput: result.stdoutText, status: result.status)
    }

    /// `pidof -s` prints one pid, or nothing with status 1 when no process has the name.
    static func liveness(pidofOutput: String, status: Int32) -> AppLiveness {
        let text = pidofOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, let pid = Int(text), pid > 0 { return .running(AppProcess(pid: pid)) }
        return status == 1 && text.isEmpty ? .notRunning : .unknown
    }

    public func crashReport(_ appID: String, process: AppProcess, since: Date, on id: DeviceID) async -> AppCrashReport? {
        guard let client = try? requireClient(),
              let result = try? await client.shell(CrashBufferParser.command(pid: process.pid), on: id.rawValue, label: "logcat -b crash") else { return nil }
        return CrashBufferParser.cause(in: result.stdoutText).map(AppCrashReport.cause)
    }
}
