import AppKit
import CoreGraphics
import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

struct DoctorTimeoutError: LocalizedError {
    let operation: String
    let seconds: TimeInterval

    var errorDescription: String? {
        "\(operation) did not finish within \(Int(seconds)) s"
    }
}

/// Thin host, process and simulator probes; every verdict comes from `DoctorRules`.
@MainActor
enum DoctorProbes {
    static let simulatorAppBundleIdentifier = "com.apple.iphonesimulator"
    static let dtuhidActiveNotification = "com.apple.coredevice.dtuhidd.active"

    // MARK: Xcode

    static func developerDirectory(environment: [String: String]) -> Result<(path: String, source: String), Error> {
        do {
            let path = try FBXcodeDirectory.resolveDeveloperDirectory()
            var isDirectory: ObjCBool = false
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(CLIError(errorDescription: "No developer directory was found"))
            }
            let fromEnvironment = !(environment["DEVELOPER_DIR"] ?? "").isEmpty
            return .success((path, fromEnvironment ? "DEVELOPER_DIR" : "xcode-select"))
        } catch {
            return .failure(error)
        }
    }

    static func xcodeVersion(developerDirectory: String) -> (version: String?, build: String?) {
        let plistPath = URL(fileURLWithPath: developerDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("version.plist")
        guard let plist = NSDictionary(contentsOf: plistPath) else { return (nil, nil) }
        return (plist["CFBundleShortVersionString"] as? String, plist["ProductBuildVersion"] as? String)
    }

    static func loadFrameworks(logger: OffsiderLogger) -> Error? {
        do {
            try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
            try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            return nil
        } catch {
            return error
        }
    }

    static func coreSimulatorVersion() -> String? {
        guard let simDevice = NSClassFromString("SimDevice") else { return nil }
        return Bundle(for: simDevice).infoDictionary?["CFBundleVersion"] as? String
    }

    // MARK: Host

    static func isSimulatorAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: simulatorAppBundleIdentifier).isEmpty
    }

    static func deviceHubAppPath(developerDirectory: String) -> String {
        URL(fileURLWithPath: developerDirectory)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/Applications/DeviceHub.app")
            .path
    }

    static func deviceHubState(appPath: String) -> (state: DeviceHubState, processIdentifier: pid_t?) {
        guard FileManager.default.fileExists(atPath: appPath) else { return (.missing, nil) }
        let processes = FBProcessFetcher().processes(withProcessName: "DeviceHub")
        if let own = processes.first(where: { $0.launchPath.hasPrefix(appPath + "/") }) {
            return (.running, own.processIdentifier)
        }
        if let other = processes.first {
            let otherApp = other.launchPath.components(separatedBy: "/Contents/MacOS/").first ?? other.launchPath
            return (.runningFromOtherXcode(path: otherApp), other.processIdentifier)
        }
        return (.notRunning, nil)
    }

    static func brokerDirectoryState(path: String) -> BrokerDirectoryState {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .absent : .unsafe(reason: String(cString: strerror(errno)), ownedByCurrentUser: false)
        }
        let owned = info.st_uid == getuid()
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return .unsafe(reason: BrokerDirectoryState.notADirectoryReason, ownedByCurrentUser: owned)
        }
        guard owned else {
            return .unsafe(reason: "owned by uid \(info.st_uid)", ownedByCurrentUser: false)
        }
        guard info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            return .unsafe(reason: "group or other users can access it", ownedByCurrentUser: true)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return .unsafe(reason: "cannot be listed", ownedByCurrentUser: true)
        }
        var live = 0
        var stale = 0
        for entry in entries where entry.hasSuffix(".\(BrokerEndpointNaming.socketExtension)") {
            switch HIDBroker.liveness(endpoint: (path as NSString).appendingPathComponent(entry)) {
            case .alive: live += 1
            case .stale: stale += 1
            case .absent: break
            }
        }
        let unexpected = entries.filter { !BrokerEndpointNaming.isBrokerOwnedEntry($0) }.sorted()
        return .healthy(live: live, stale: stale, unexpectedEntries: unexpected)
    }

    // MARK: Simulators

    static func simulators(logger: OffsiderLogger) async throws -> [FBSimulator] {
        try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared).allSimulators
    }

    static func bootedSimulator(_ simulator: FBSimulator) -> BootedSimulator {
        BootedSimulator(
            udid: simulator.udid,
            name: simulator.name,
            osVersion: simulator.osVersion.name.rawValue,
            deviceType: simulator.deviceType.model.rawValue
        )
    }

    static func bootUptime(udid: String, now: Date = Date()) -> (identity: HIDBrokerBootIdentity, seconds: TimeInterval)? {
        guard let identity = try? HIDBroker.currentBootIdentity(simulatorUDID: udid) else { return nil }
        let start = TimeInterval(identity.startSeconds) + TimeInterval(identity.startMicroseconds) / 1_000_000
        return (identity, max(0, now.timeIntervalSince1970 - start))
    }

    static func deviceWindowState(deviceHubProcessIdentifier: pid_t?, simulatorName: String) -> DeviceWindowState {
        guard let deviceHubProcessIdentifier else { return .deviceHubNotRunning }
        guard CGPreflightScreenCaptureAccess() else { return .titlesUnavailable }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let titles = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == deviceHubProcessIdentifier }
            .compactMap { $0[kCGWindowName as String] as? String }
        return titles.contains { $0.contains(simulatorName) } ? .found : .notFound
    }

    static func resizeMode(udid: String) async -> DoctorRules.Verdict {
        do {
            let result = try await ProcessCapture.run(
                executable: "/usr/bin/xcrun",
                arguments: ["devicectl", "device", "info", "appResize", "--device", udid],
                timeout: 15
            )
            return DoctorRules.resizeMode(exitStatus: result.status, output: result.stdout + result.stderr, udid: udid)
        } catch {
            return DoctorRules.resizeMode(exitStatus: -1, output: error.localizedDescription, udid: udid)
        }
    }

    static func dtuhiddProcessIdentifier(bootIdentity: HIDBrokerBootIdentity) -> pid_t? {
        let pid = FBProcessFetcher().subprocess(of: bootIdentity.processIdentifier, withName: "dtuhidd")
        return HIDBroker.isDTUHIDSelected(processIdentifier: pid) ? pid : nil
    }

    static func dtuhidActiveFlag(udid: String) async -> Int? {
        guard let result = try? await ProcessCapture.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "spawn", udid, "notifyutil", "-g", dtuhidActiveNotification],
            timeout: 5
        ), result.status == 0 else { return nil }
        return DoctorRules.parseNotifyFlag(result.stdout)
    }

    /// Uses the default transport selection only: forcing DTUHID would attach dtuhidd for the rest of the boot.
    static func hidTransport(simulator: FBSimulator) async -> (verdict: DoctorRules.Verdict, transport: String?) {
        do {
            let hid = try await withTimeout(5, operation: "Connecting to simulator HID") {
                try await simulator.connectToHID()
            }
            defer { hid.disconnect() }
            let transport: String
            switch hid.transportType {
            case .dtuhid: transport = "dtuhid"
            case .indigo: transport = "indigo"
            @unknown default: transport = String(describing: hid.transportType)
            }
            return ((.pass, transport, nil), transport)
        } catch {
            return ((.fail, error.localizedDescription, hidTransportHint(for: error)), nil)
        }
    }

    static func hidTransportHint(for error: Error) -> String? {
        nil
    }

    static func accessibility(udid: String, logger: OffsiderLogger) async -> AccessibilityProbeState {
        do {
            let data = try await withTimeout(20, operation: "Reading the accessibility tree") {
                try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
                    for: udid,
                    logger: logger,
                    recoveryDependencies: reportOnlyAccessibilityRecovery
                )
            }
            return hasAccessibilityDescendant(data) ? .known : .emptyRoot
        } catch let error as UserFacingError {
            return .failed(error.userFacingDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Doctor reports a broken testmanagerd instead of restarting it.
    static let reportOnlyAccessibilityRecovery = AccessibilityRecoveryDependencies(
        runProcess: { _, _, _ in
            throw CLIError(errorDescription: "The accessibility channel to testmanagerd is disconnected; describe-ui restarts it, or reboot the simulator")
        },
        wait: { _ in }
    )

    static func hasAccessibilityDescendant(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let roots = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        return roots.contains { !(($0["children"] as? [Any]) ?? []).isEmpty }
    }

    static func withTimeout<T>(
        _ seconds: TimeInterval,
        operation: String,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            let work = Task { @MainActor in
                do {
                    let value = try await body()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: DoctorTimeoutError(operation: operation, seconds: seconds))
                }
            }
        }
    }
}

@MainActor
private final class ResumeGate {
    private var resumed = false

    func claim() -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
