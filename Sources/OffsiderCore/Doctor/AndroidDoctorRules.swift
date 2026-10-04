import Foundation

/// Pure verdicts for the Android checks, and the order and dependency skips they report in.
public enum AndroidDoctorRules {
    public typealias Verdict = DoctorRules.Verdict

    public static let supportedABI = "arm64-v8a"
    public static let metroPort = 8742

    // MARK: Host

    public static func sdk(_ fact: AndroidSDKFact, deviceNamed: Bool) -> Verdict {
        switch fact {
        case .found(let root, let source, _):
            return (.pass, "\(root) (\(source))", nil)
        case .variableWithoutAdb(let variable, let message):
            return (.fail, message, "Point \(variable) at an SDK with Platform-Tools installed, or unset it.")
        case .notFound where deviceNamed:
            return (.fail, "Android SDK not found", "Set ANDROID_HOME to your SDK (Android Studio installs it in ~/Library/Android/sdk), or put adb on PATH.")
        case .notFound:
            return (.skip, "not installed", nil)
        }
    }

    public static func adb(_ binary: AdbBinaryFact, server: AdbServerFact?) -> Verdict {
        switch binary {
        case .failed(let message):
            return (.fail, "adb could not run: \(message)", "Reinstall Platform-Tools with the Android SDK Manager.")
        case .version(let version, let binaryProtocol):
            guard case .answering(_, let serverProtocol)? = server else {
                return (.pass, "adb \(version)", nil)
            }
            if let binaryProtocol, binaryProtocol != serverProtocol {
                return (
                    .warn,
                    "adb \(version) speaks protocol \(binaryProtocol), but the running server speaks \(serverProtocol), so another SDK started it",
                    "Offsider never restarts a running server. Use one SDK: when nothing else needs it, stop the other server with that SDK's adb kill-server."
                )
            }
            return (.pass, "adb \(version), server protocol \(serverProtocol)", nil)
        }
    }

    /// An idle Mac without an adb server is normal, so it only warns when an Android device was named.
    public static func adbServer(_ fact: AdbServerFact, deviceNamed: Bool = true) -> Verdict {
        switch fact {
        case .answering(let endpoint, _):
            return (.pass, "Answering on \(endpoint)", nil)
        case .notRunning(let endpoint) where !deviceNamed:
            return (.skip, "no adb server on \(endpoint); Android commands start one with ADB_MDNS=0", nil)
        case .notRunning(let endpoint):
            return (.warn, "No adb server on \(endpoint)", "Any Offsider Android command, or offsider doctor --fix, starts it with ADB_MDNS=0.")
        case .noAnswer(let endpoint, let detail):
            return (.fail, "\(endpoint) did not answer: \(detail)", "Check what holds that port; Offsider never kills it.")
        case .badSetting(let message):
            return (.fail, message, nil)
        }
    }

    public static func isAdbServerFixable(_ fact: AdbServerFact?) -> Bool {
        if case .notRunning? = fact { return true }
        return false
    }

    /// Anything other than a clear answer is a skip, since the wording differs between Platform-Tools releases.
    public static func mdnsFact(fromCheckReply reply: String) -> AdbMDNSFact {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("discovery disabled") {
            return .disabled(text)
        }
        if lower.hasPrefix("mdns daemon version") {
            return .active(text)
        }
        return .unknown(text.isEmpty ? "an empty reply" : text)
    }

    public static func mdns(_ fact: AdbMDNSFact) -> Verdict {
        switch fact {
        case .disabled:
            return (.pass, "mDNS discovery is off", nil)
        case .active(let reply):
            return (
                .warn,
                "mDNS discovery is on (\(reply)), so this server was started without ADB_MDNS=0 and sends multicast on the LAN",
                "When nothing else needs adb, run adb kill-server (it disconnects Android Studio and other adb users); the next Offsider command starts it again with ADB_MDNS=0."
            )
        case .unknown(let reply):
            return (.skip, "could not tell from host:mdns:check (\(reply))", nil)
        }
    }

    public static func emulator(revision: String?) -> Verdict {
        guard let revision else {
            return (.warn, "The Android Emulator package is not installed; only offsider boot needs it", "Install it with the Android SDK Manager.")
        }
        return (.pass, "Emulator \(revision)", nil)
    }

    public static func helperBundle(_ fact: HelperBundleFact) -> Verdict {
        switch fact {
        case .ok(let version, let protocolVersion):
            return (.pass, "Helper \(version), protocol \(protocolVersion)", nil)
        case .problem(let message):
            return (.fail, message, "Reinstall Offsider.")
        }
    }

    public static func devices(_ rows: [AndroidDeviceRow]) -> Verdict {
        guard !rows.isEmpty else { return (.pass, "No devices connected", nil) }
        let emulators = rows.filter { $0.kind == "emulator" }
        let others = rows.count - emulators.count
        var parts: [String] = []
        if !emulators.isEmpty {
            let online = emulators.filter { $0.state != "Offline" && $0.state != "Unauthorised" }.count
            parts.append("\(DoctorRules.plural(emulators.count, "emulator")) (\(online) online)")
        }
        if others > 0 {
            parts.append(DoctorRules.plural(others, "other device"))
        }
        return (.pass, parts.joined(separator: ", "), nil)
    }

    // MARK: Device

    public static func deviceState(_ facts: AndroidDeviceFacts) -> Verdict {
        let serial = facts.serial ?? facts.id
        let name = (facts.avdName ?? facts.model).map { "\($0) (\(serial))" } ?? serial
        if facts.isPhysical {
            switch facts.state {
            case .booted: return (.pass, "\(name), a phone connected over USB", nil)
            case .offline: return (.fail, "\(name) is offline", "Reconnect the cable and unlock the phone, then run doctor again.")
            case .unauthorised: return (.fail, "\(name) is unauthorised", "Unlock the phone and accept the \"Allow USB debugging?\" prompt.")
            default: break
            }
        }
        switch facts.state {
        case .booted:
            return (.pass, "\(name), booted", nil)
        case .booting:
            return (.warn, "\(name), still booting", "Wait for it to finish booting, then run doctor again.")
        case .offline:
            return (.fail, "\(name) is offline", "Wait a moment; if it stays offline, restart the emulator.")
        case .unauthorised:
            return (.fail, "\(name) is unauthorised", "Accept the USB debugging prompt on the device.")
        case .other(let state):
            return (.fail, "adb reports \(name) as \(state)", nil)
        case .notFound(let message):
            return (.fail, message, "Check the ID with offsider list-devices.")
        }
    }

    public static func image(apiLevel: Int?, release: String?, abi: String?) -> Verdict {
        var parts: [String] = []
        if let release { parts.append("Android \(release)") }
        if let apiLevel { parts.append("API \(apiLevel)") }
        parts.append(abi ?? "unknown ABI")
        let detail = parts.joined(separator: ", ")
        guard abi == supportedABI else {
            return (.warn, detail, "Offsider ships and tests \(supportedABI) images only; use an \(supportedABI) system image.")
        }
        return (.pass, detail, nil)
    }

    public static func grpc(_ fact: EmulatorGrpcFact) -> Verdict {
        let fallback = "commands use adb (slower screenshots, ASCII-only type)"
        let bootHint = "Start the emulator with offsider boot <AVD> so it has a gRPC endpoint."
        let forcedHint = "\(bootHint) Or unset OFFSIDER_ANDROID_TRANSPORT."
        switch fact {
        case .forcedAdb:
            return (.skip, "OFFSIDER_ANDROID_TRANSPORT is adb", nil)
        case .noDiscoveryFile(let forced):
            return forced
                ? (.fail, "OFFSIDER_ANDROID_TRANSPORT is grpc, but this emulator has no discovery file", forcedHint)
                : (.warn, "No discovery file for this emulator, so \(fallback)", bootHint)
        case .noGrpcPort(let forced):
            return forced
                ? (.fail, "OFFSIDER_ANDROID_TRANSPORT is grpc, but the discovery file lists no gRPC port", forcedHint)
                : (.warn, "Its discovery file lists no gRPC port, so \(fallback)", bootHint)
        case .connected(let endpoint, let auth, let milliseconds, let booted):
            let state = booted ? "" : "; the emulator reports it has not finished booting"
            return (.pass, "\(endpoint), \(auth) auth, getStatus \(milliseconds) ms; commands use gRPC\(state)", nil)
        case .failed(let message, let forced):
            let hint = "Restart the emulator with offsider boot <AVD>, or try OFFSIDER_ANDROID_GRPC_AUTH=jwt."
            return forced
                ? (.fail, "OFFSIDER_ANDROID_TRANSPORT is grpc, but gRPC failed: \(message)", hint)
                : (.warn, "gRPC failed (\(message)), so \(fallback)", hint)
        }
    }

    public static func uiAutomation(_ fact: UiAutomationFact) -> Verdict {
        if !fact.offsiderHelperPids.isEmpty {
            let pids = fact.offsiderHelperPids.map(String.init).joined(separator: ", ")
            return (.warn, "An Offsider helper is running (pid \(pids)): another command, or one exiting within 10 s", "Wait for the other command to finish, then run doctor again.")
        }
        if !fact.enabledServices.isEmpty {
            return (
                .warn,
                "Accessibility services are enabled (\(fact.enabledServices.joined(separator: ", "))); TalkBack and similar services change how taps work",
                "Turn them off in Settings > Accessibility while Offsider drives the device."
            )
        }
        return (.pass, "Free; no accessibility service enabled", nil)
    }

    public static func helper(_ fact: HelperProbeFact) -> Verdict {
        switch fact {
        case .ready(let launch, let pushed, let hello, let ping, let protocolVersion, let sdkInt):
            return (.pass, "Ready in \(launch) ms (pushed: \(pushed ? "yes" : "no")), hello \(hello) ms, ping \(ping) ms, protocol \(protocolVersion), API \(sdkInt)", nil)
        case .busy(let detail):
            return (
                .fail,
                "Another UiAutomation client holds the slot: \(detail)",
                "Stop the other client (Appium, Maestro, uiautomator or Layout Inspector), then retry."
            )
        case .unavailable(let reason):
            return (.warn, "Unavailable: \(reason); screen reads fall back to uiautomator, about 2 s each", "Reinstall Offsider if its bundle is damaged.")
        case .forcedOff:
            return (.skip, "OFFSIDER_ANDROID_TREE is uiautomator", nil)
        }
    }

    /// Information only: Offsider never sets or removes a reverse.
    public static func metroReverse(_ lines: [String]?) -> Verdict {
        guard let lines else { return (.pass, "Could not read the reverse list", nil) }
        let pairs = lines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let remote = fields[fields.count - 2]
            let local = fields[fields.count - 1]
            let metro = remote == "tcp:\(metroPort)" ? " (Metro)" : ""
            return "\(remote) to \(local)\(metro)"
        }
        return (.pass, pairs.isEmpty ? "none" : pairs.joined(separator: ", "), nil)
    }

    // MARK: Composition

    public static func hostChecks(_ facts: AndroidHostFacts, deviceNamed: Bool) -> [DoctorCheckResult] {
        var checks = [DoctorCheckResult(id: .androidSDK, verdict: sdk(facts.sdk, deviceNamed: deviceNamed))]
        guard case .found = facts.sdk else {
            let dependents: [DoctorCheckID] = [.androidAdb, .androidAdbServer, .androidAdbMDNS, .androidEmulator]
            checks += dependents.map { .skipped($0, "requires android.sdk") }
            checks.append(DoctorCheckResult(id: .androidHelperBundle, verdict: helperBundle(facts.helperBundle)))
            checks.append(.skipped(.androidDevices, "requires android.sdk"))
            return checks
        }
        if let binary = facts.adb {
            checks.append(DoctorCheckResult(id: .androidAdb, verdict: adb(binary, server: facts.server)))
        } else {
            checks.append(.skipped(.androidAdb, "requires android.sdk"))
        }
        if let server = facts.server {
            let verdict = adbServer(server, deviceNamed: deviceNamed)
            checks.append(DoctorCheckResult(id: .androidAdbServer, verdict: verdict, fixable: verdict.status == .warn && isAdbServerFixable(server)))
        } else {
            checks.append(.skipped(.androidAdbServer, "requires android.sdk"))
        }
        if let mdns = facts.mdns {
            checks.append(DoctorCheckResult(id: .androidAdbMDNS, verdict: self.mdns(mdns)))
        } else {
            checks.append(.skipped(.androidAdbMDNS, "requires android.adb-server"))
        }
        checks.append(DoctorCheckResult(id: .androidEmulator, verdict: emulator(revision: facts.emulatorRevision)))
        checks.append(DoctorCheckResult(id: .androidHelperBundle, verdict: helperBundle(facts.helperBundle)))
        if let rows = facts.devices {
            checks.append(DoctorCheckResult(id: .androidDevices, verdict: devices(rows)))
        } else {
            checks.append(.skipped(.androidDevices, "requires android.adb-server"))
        }
        return checks
    }

    static let deviceDependents: [DoctorCheckID] = [
        .androidDeviceImage, .androidDeviceGrpc, .androidDeviceUiAutomation, .androidDeviceHelper, .androidDeviceMetroReverse,
    ]

    /// `hostBlocker` names the failed host check the device checks need, such as `android.sdk`.
    public static func deviceChecks(_ facts: AndroidDeviceFacts?, hostBlocker: DoctorCheckID?) -> [DoctorCheckResult] {
        guard let facts, hostBlocker == nil else {
            let reason = "requires \((hostBlocker ?? .androidAdbServer).rawValue)"
            return ([.androidDeviceState] + deviceDependents).map { .skipped($0, reason) }
        }
        var checks = [DoctorCheckResult(id: .androidDeviceState, verdict: deviceState(facts))]
        guard facts.state == .booted else {
            return checks + deviceDependents.map { .skipped($0, "requires android-device.state") }
        }
        checks.append(DoctorCheckResult(id: .androidDeviceImage, verdict: image(apiLevel: facts.apiLevel, release: facts.release, abi: facts.abi)))
        if let grpc = facts.grpc {
            checks.append(DoctorCheckResult(id: .androidDeviceGrpc, verdict: self.grpc(grpc)))
        } else {
            checks.append(.skipped(.androidDeviceGrpc, facts.isPhysical ? "a physical device has no emulator gRPC endpoint" : "not an emulator"))
        }
        if let uiAutomation = facts.uiAutomation {
            checks.append(DoctorCheckResult(id: .androidDeviceUiAutomation, verdict: self.uiAutomation(uiAutomation)))
        } else {
            checks.append(.skipped(.androidDeviceUiAutomation, "could not read the accessibility settings"))
        }
        if let helper = facts.helper {
            checks.append(DoctorCheckResult(id: .androidDeviceHelper, verdict: self.helper(helper)))
        } else if facts.uiAutomation?.offsiderHelperPids.isEmpty == false {
            checks.append(.skipped(.androidDeviceHelper, "an Offsider helper is already running"))
        } else {
            checks.append(.skipped(.androidDeviceHelper, "requires android-device.uiautomation"))
        }
        checks.append(DoctorCheckResult(id: .androidDeviceMetroReverse, verdict: metroReverse(facts.reverses)))
        return checks
    }

    /// The host check that stops device checks, if any.
    public static func hostBlocker(_ facts: AndroidHostFacts) -> DoctorCheckID? {
        guard case .found = facts.sdk else { return .androidSDK }
        guard case .answering? = facts.server else { return .androidAdbServer }
        return nil
    }

    public static func summary(_ facts: AndroidHostFacts, device: AndroidDeviceFacts?) -> AndroidSummary? {
        guard case .found(let root, let source, let adbPath) = facts.sdk else { return nil }
        var adbVersion: String?
        if case .version(let version, _)? = facts.adb { adbVersion = version }
        var endpoint: String?
        var serverVersion: Int?
        switch facts.server {
        case .answering(let answering, let version)?:
            endpoint = answering
            serverVersion = version
        case .notRunning(let address)?, .noAnswer(let address, _)?:
            endpoint = address
        case .badSetting?, nil:
            break
        }
        let rows = (facts.devices ?? []).map { row -> AndroidDeviceRow in
            guard let device, row.serial == device.serial else { return row }
            let state: String
            switch device.state {
            case .booted: state = "Booted"
            case .booting: state = "Booting"
            default: state = row.state
            }
            return AndroidDeviceRow(serial: row.serial, kind: row.kind, state: state, avd: device.avdName ?? row.avd, apiLevel: device.apiLevel ?? row.apiLevel)
        }
        return AndroidSummary(
            sdkRoot: root,
            sdkSource: source,
            adbPath: adbPath,
            adbVersion: adbVersion,
            adbServer: endpoint,
            adbServerVersion: serverVersion,
            emulatorRevision: facts.emulatorRevision,
            devices: rows
        )
    }
}
