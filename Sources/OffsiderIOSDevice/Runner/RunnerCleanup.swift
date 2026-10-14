import Foundation
import OffsiderCore

/// What `--clean` removed for one device, and what it could not.
public struct RunnerCleanupReport: Equatable, Sendable {
    public var udid: String
    public var uninstalled: [String] = []
    /// Bundle id and devicectl's reason, for each app it did not remove.
    public var notUninstalled: [String: String] = [:]
    public var removedBuilds = 0
    public var removedLogs: [String] = []
    public var prefixes: [String] = []

    public init(udid: String) {
        self.udid = udid
    }

    /// What only the Apple developer site removes.
    public var remains: String {
        let ids = prefixes.flatMap { ["\($0).runner", "\($0).runner.uitests"] }.joined(separator: ", ")
        return "Still in your Apple developer team: the runner's provisioning profile, the App IDs \(ids), and this device's UDID registration. Only the Apple developer site (Certificates, Identifiers & Profiles) removes them."
    }
}

/// Removes the runner from a device and its builds and logs from this Mac; the session must already be stopped.
public enum RunnerCleanup {
    static let uninstallTimeout: TimeInterval = 60

    public static func clean(
        udid: String, cacheRoot: URL, environmentPrefix: String, devicectl: any DevicectlRunning, logPaths: [String]
    ) async -> RunnerCleanupReport {
        var report = RunnerCleanupReport(udid: udid)
        let keys = buildDirectories(for: udid, cacheRoot: cacheRoot)
        var prefixes = [environmentPrefix]
        for key in keys {
            if let prefix = (try? RunnerProducts.read(in: key))??.prefix, !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        report.prefixes = prefixes
        for prefix in prefixes {
            for bundleID in XcodeRunnerBuilder.installedBundleIDs(prefix: prefix) {
                let arguments = ["device", "uninstall", "app", "--device", udid, bundleID, "--timeout", "30", "-q"]
                do {
                    let result = try await devicectl.run(arguments, timeout: uninstallTimeout)
                    if result.status == 0 {
                        report.uninstalled.append(bundleID)
                    } else {
                        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).split(separator: "\n").first.map(String.init) ?? "devicectl exited \(result.status)"
                        report.notUninstalled[bundleID] = detail
                    }
                } catch {
                    report.notUninstalled[bundleID] = (error as? IOSDeviceError)?.message ?? error.localizedDescription
                }
            }
        }
        for key in keys {
            if (try? FileManager.default.removeItem(at: key)) != nil { report.removedBuilds += 1 }
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent("\(key.lastPathComponent).lock"))
        }
        for path in logPaths where FileManager.default.fileExists(atPath: path) {
            if (try? FileManager.default.removeItem(atPath: path)) != nil { report.removedLogs.append(path) }
        }
        return report
    }

    /// The cached builds whose `products.json` names this device.
    static func buildDirectories(for udid: String, cacheRoot: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        return names.sorted().compactMap { name in
            let directory = cacheRoot.appendingPathComponent(name, isDirectory: true)
            guard let record = (try? RunnerProducts.read(in: directory)) ?? nil,
                  record.udid.caseInsensitiveCompare(udid) == .orderedSame else { return nil }
            return directory
        }
    }
}
