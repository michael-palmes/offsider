import AppKit
import Darwin
import Foundation
import OffsiderCore

/// The only changes `doctor --fix` makes; each one is safe to repeat.
@MainActor
enum DoctorFixes {
    static func apply(after run: DoctorRun, udid: String?) async -> [DoctorFixResult] {
        var results: [DoctorFixResult] = []
        results.append(await openDeviceHub(run.context))
        results.append(removeStaleBrokerDirectory(run.context))
        results.append(await openDeviceWindow(run, udid: udid))
        return results
    }

    private static func openDeviceHub(_ context: DoctorContext) async -> DoctorFixResult {
        let action = "Open Device Hub"
        func result(_ outcome: DoctorFixResult.Outcome, _ detail: String) -> DoctorFixResult {
            DoctorFixResult(id: .deviceHub, action: action, outcome: outcome, detail: detail)
        }
        guard DoctorRules.isDeviceHubEra(xcodeMajor: context.xcodeMajor), let appPath = context.deviceHubAppPath else {
            return result(.skipped, "Only applies to Xcode 27 or later")
        }
        guard !DoctorProbes.isSimulatorAppRunning() else {
            return result(.skipped, "Quit Simulator.app first")
        }
        switch DoctorProbes.deviceHubState(appPath: appPath).state {
        case .missing:
            return result(.skipped, "Device Hub is missing at \(appPath)")
        case .running:
            return result(.skipped, "Device Hub is already running")
        case .runningFromOtherXcode(let path):
            return result(.skipped, "Device Hub is running from another Xcode: \(path)")
        case .notRunning:
            break
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: configuration)
        } catch {
            return result(.failed, error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if DoctorProbes.deviceHubState(appPath: appPath).state == .running {
                return result(.applied, "Opened Device Hub")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return result(.failed, "Device Hub did not start within 5 s")
    }

    static func removeStaleBrokerDirectory(_ context: DoctorContext) -> DoctorFixResult {
        let path = context.brokerRootPath
        func result(_ outcome: DoctorFixResult.Outcome, _ detail: String) -> DoctorFixResult {
            DoctorFixResult(id: .brokerDirectory, action: "Remove the stale broker directory", outcome: outcome, detail: detail)
        }
        let state = DoctorProbes.brokerDirectoryState(path: path)
        guard DoctorRules.isBrokerDirectoryFixable(state) else {
            switch state {
            case .absent:
                return result(.skipped, "Nothing to remove")
            case .unsafe(let reason, _) where reason == BrokerDirectoryState.notADirectoryReason:
                return result(.skipped, "Not a directory; Offsider did not create it")
            case .unsafe:
                return result(.skipped, "Owned by another user; remove it as that user")
            case .healthy(let live, _, let unexpected) where !unexpected.isEmpty || live > 0:
                return result(.skipped, unexpected.isEmpty ? "A live broker is using it" : "Contains entries Offsider did not create")
            case .healthy:
                return result(.skipped, "Nothing stale to remove")
            }
        }
        if let blocker = removalBlocker(path: path) {
            return result(.skipped, blocker)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return result(.applied, "Removed \(path); the next input command recreates it")
        } catch {
            return result(.failed, error.localizedDescription)
        }
    }

    /// Re-checks right before removal: only an owned directory holding broker files may go.
    private static func removalBlocker(path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "Nothing to remove" }
        guard info.st_uid == getuid() else { return "Owned by another user; remove it as that user" }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return "Not a directory; Offsider did not create it" }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "Cannot list its entries"
        }
        if entries.contains(where: { !BrokerEndpointNaming.isBrokerOwnedEntry($0) }) {
            return "Contains entries Offsider did not create"
        }
        let sockets = entries.filter { $0.hasSuffix(".\(BrokerEndpointNaming.socketExtension)") }
        if sockets.contains(where: { HIDBroker.liveness(endpoint: (path as NSString).appendingPathComponent($0)) == .alive }) {
            return "A live broker is using it"
        }
        return nil
    }

    private static func openDeviceWindow(_ run: DoctorRun, udid: String?) async -> DoctorFixResult {
        func result(_ outcome: DoctorFixResult.Outcome, _ detail: String) -> DoctorFixResult {
            DoctorFixResult(id: .deviceWindow, action: "Open the device window", outcome: outcome, detail: detail)
        }
        guard let udid else {
            return result(.skipped, "Requires --udid")
        }
        guard DoctorRules.isDeviceHubEra(xcodeMajor: run.context.xcodeMajor), let appPath = run.context.deviceHubAppPath else {
            return result(.skipped, "Only applies to Xcode 27 or later")
        }
        guard run.context.simulatorBooted else {
            return result(.skipped, "Requires a booted simulator")
        }
        guard DoctorProbes.deviceHubState(appPath: appPath).state == .running else {
            return result(.skipped, "Device Hub is not running")
        }
        if run.checks.first(where: { $0.id == .deviceWindow })?.status == .pass {
            return result(.skipped, "The device window is already open")
        }
        do {
            let opened = try await ProcessCapture.run(
                executable: "/usr/bin/open",
                arguments: ["devices://device/open?id=\(udid)"],
                timeout: 10
            )
            guard opened.status == 0 else {
                let message = opened.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return result(.failed, message.isEmpty ? "open exited with status \(opened.status)" : message)
            }
            // Opening the window can attach dtuhidd; give it a moment before the checks run again.
            try? await Task.sleep(for: .seconds(2))
            return result(.applied, "Opened or focused the device window")
        } catch {
            return result(.failed, error.localizedDescription)
        }
    }
}
