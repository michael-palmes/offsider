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

    /// The application's pid, and its bundle id while the process still runs: one `proc_pidpath` and its `Info.plist`.
    func shownApp(in tree: UITree) -> ShownApp? {
        guard let pid = SimulatorAppLiveness.applicationPID(in: tree) else { return nil }
        let bundle = Int32(exactly: pid).flatMap(ProcessPath.of(pid:)).flatMap(ForegroundApp.bundleIdentifier(atExecutable:))
        return ShownApp(pid: pid, appID: bundle)
    }

    func crashReport(_ appID: String, process: AppProcess, since: Date, on id: DeviceID) async -> AppCrashReport? {
        await SimulatorCrashReports.awaitReport(for: appID, pid: process.pid, udid: id.rawValue, since: since, directory: DoctorProbes.diagnosticReportsPath)
    }
}
