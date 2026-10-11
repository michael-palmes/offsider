import Foundation
import OffsiderCore

extension IOSBackend: AppLivenessReading {
    func appLiveness(_ appID: String, seen: AppProcess?, tree: UITree?, mayList: Bool, on id: DeviceID) async -> AppLiveness {
        await SimulatorAppLiveness.read(
            appID, seen: seen, tree: tree, mayList: mayList,
            bundleOf: { pid in
                guard let pid = Int32(exactly: pid), let path = ProcessPath.of(pid: pid) else { return nil }
                return ForegroundApp.bundleIdentifier(atExecutable: path)
            },
            startOf: { pid in Int32(exactly: pid).flatMap { ProcessTable.live.lookup($0)?.identity.startTime } },
            listing: {
                let result = try? await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "spawn", id.rawValue, "launchctl", "list"], timeout: 5)
                return result.flatMap { $0.status == 0 ? $0.stdout : nil }
            }
        )
    }

    /// ReportCrash writes the report a moment after the process dies, so this looks for up to 5 s.
    func crashReport(_ appID: String, process: AppProcess, since: Date, on id: DeviceID) async -> AppCrashReport? {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            let files = SimulatorCrashReports.scan(directory: DoctorProbes.diagnosticReportsPath, modifiedSince: since)
            if let file = SimulatorCrashReports.report(for: appID, pid: process.pid, udid: id.rawValue, in: files) {
                return .file(file.path)
            }
        }
        return nil
    }
}
