import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the host and, with --device, a simulator, Android emulator or USB phone for problems that stop Offsider input or screen reads."
    )

    @OptionGroup
    var deviceOption: OptionalDeviceOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @Flag(name: .customLong("fix"), help: "Apply safe, repeatable fixes, then check again.")
    var fix = false

    func run() async throws {
        let label = deviceOption.id.map { "Checking \($0)" } ?? "Checking this Mac"
        let report = await Console.current.progress(label) { await makeReport(host: .cli()) }
        try Self.write(report, json: json)
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    /// The policy gate runs before any probe, so a refused device gets no adb server and no device read.
    func makeReport(host: AndroidHost) async -> DoctorReport {
        var report: DoctorReport
        var target: (platform: DevicePlatform, key: String)?
        if let id = deviceOption.id {
            target = await Self.physicalTarget(
                id,
                isListedPhone: { await AndroidPhoneListing.isListedPhone(serial: $0, host: host) },
                isDefinedAVD: { AndroidPhoneListing.isDefinedAVD(name: $0, host: host) }
            )
        }
        let policy = target.map { target in
            DoctorPolicy(
                platform: target.platform, key: target.key,
                decision: Self.decision(platform: target.platform, key: target.key, fromEnvironment: deviceOption.source == .environment),
                managed: DevicePolicyGate.current.policy().managed.present
            )
        }
        if let target, let policy, !policy.allowed {
            report = Self.policyReport(policy, target: target, source: deviceOption.source)
        } else if let id = deviceOption.id, case .androidSerial(let port) = DeviceIDClassifier.classify(id),
                  let refused = await Self.emulatorSerialReport("emulator-\(port)", source: deviceOption.source, isUSBRow: { try await Self.liveUSBRow($0, host: host) }) {
            report = refused
        } else if let id = deviceOption.id, case .iosDevice(let udid) = DeviceIDClassifier.classify(id) {
            report = await iosDeviceReport(udid)
        } else if let id = deviceOption.id, DeviceIDClassifier.classify(id).platform == .android {
            report = await androidReport(id, host: host)
        } else {
            report = await hostAndSimulatorReport(host: host)
        }
        if let policy, policy.allowed {
            report = Self.withPolicy(report, policy)
        }
        return Self.withHost(report, HostProbe.live.facts())
    }

    /// Xcode, simulator and HID checks, then Android host checks (skipped when no SDK is installed).
    private func hostAndSimulatorReport(host: AndroidHost) async -> DoctorReport {
        let udid = deviceOption.id.map(Self.canonicalUDID)
        let runner = DoctorRunner(
            udid: udid,
            environment: ProcessInfo.processInfo.environment,
            logger: OffsiderLogger()
        )
        let android = AndroidDoctorProbe(host: host)
        var result = await runner.run()
        var facts = await android.run(deviceID: nil).host
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = await DoctorFixes.apply(after: result, udid: udid)
            // A named simulator needs no adb server, so only a host-wide fix starts one.
            if udid == nil, case .found = facts.sdk {
                fixes.append(await android.startAdbServerIfAbsent())
            }
            result = await runner.run()
            facts = await android.run(deviceID: nil).host
        }
        let device = udid.map { udid in
            DoctorDevice(id: udid, platform: "ios", name: result.booted.first { $0.udid == udid }?.name, kind: "simulator", source: deviceOption.source?.rawValue)
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: udid,
            device: device,
            xcode: result.xcode,
            booted: result.booted,
            android: AndroidDoctorRules.summary(facts, device: nil),
            checks: result.checks + AndroidDoctorRules.hostChecks(facts, deviceNamed: false) + (udid.map { [Self.leaseCheck(platform: .ios, key: $0.uppercased(), lockID: $0)] } ?? []),
            fixes: fixes
        )
    }

    /// Android host and device checks only: Xcode and simulator state cannot affect an Android session.
    private func androidReport(_ id: String, host: AndroidHost) async -> DoctorReport {
        let probe = AndroidDoctorProbe(host: host)
        var facts = await probe.run(deviceID: id)
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = [await probe.startAdbServerIfAbsent()]
            facts = await probe.run(deviceID: id)
        }
        facts.device = facts.device.map { Self.withUnlockCode($0, store: KeychainUnlockCodeStore(), ledger: UnlockAttemptLedger()) }
        let serial = facts.device?.serial ?? id
        let kind: String? = facts.device.flatMap { device in
            device.isPhysical ? "physical" : device.serial.map { DeviceIDClassifier.classify($0).platform == .android ? "emulator" : "other" }
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: nil,
            device: DoctorDevice(
                id: serial, platform: "android", name: facts.device?.avdName ?? facts.device?.model, kind: kind,
                source: deviceOption.source?.rawValue, lock: facts.device?.lockReport
            ),
            xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil),
            booted: [],
            android: AndroidDoctorRules.summary(facts.host, device: facts.device),
            checks: AndroidDoctorRules.hostChecks(facts.host, deviceNamed: true)
                + AndroidDoctorRules.deviceChecks(facts.device, hostBlocker: AndroidDoctorRules.hostBlocker(facts.host))
                + [Self.leaseCheck(platform: .android, key: Self.leaseKey(facts.device, id: id), lockID: serial)],
            fixes: fixes
        )
    }

    /// Host checks for a physical iPhone or iPad; simulator and Android state cannot affect it.
    @MainActor
    private func iosDeviceReport(_ udid: String) async -> DoctorReport {
        var team: String?
        if case .allowed(let allowance) = DevicePolicyGate.current.decision(platform: .ios, key: udid.uppercased()) { team = allowance.team }
        let probe = IOSDeviceDoctorProbe(allowanceTeam: team)
        var result = await probe.run(udid: udid)
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = [await probe.mountDDI(udid: udid, facts: result.facts)]
            result = await probe.run(udid: udid)
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: nil,
            device: DoctorDevice(id: udid, platform: "ios", name: result.facts.row?.label, kind: "physical", source: deviceOption.source?.rawValue),
            xcode: XcodeSummary(developerDir: result.xcode?.developerDirectory, version: result.xcode?.version, build: result.xcode?.build, coreSimulator: nil),
            booted: [],
            android: nil,
            checks: IOSDeviceDoctorRules.checks(result.facts) + [Self.leaseCheck(platform: .ios, key: udid.uppercased(), lockID: udid)],
            fixes: fixes
        )
    }

    /// Host facts and checks join every report, after its own checks.
    static func withHost(_ report: DoctorReport, _ host: HostFacts) -> DoctorReport {
        DoctorReport(
            offsiderVersion: report.offsiderVersion, udid: report.udid, device: report.device, xcode: report.xcode, booted: report.booted,
            android: report.android, checks: report.checks + HostDoctorRules.checks(host) + [BundleIntegrity.doctorCheck(), Init.doctorCheck(), DoctorCheckResult(id: .installRules, verdict: Init.rulesDoctorVerdict())], fixes: report.fixes, host: host, policy: report.policy
        )
    }

    /// A physical device's platform and stable key: any iPhone or iPad UDID, and any Android name that is not an AVD on this Mac, even when no adb server answers. Only the host-side device list and AVD folder are read.
    static func physicalTarget(
        _ id: String,
        isListedPhone: (String) async -> Bool,
        isDefinedAVD: (String) -> Bool
    ) async -> (platform: DevicePlatform, key: String)? {
        switch DeviceIDClassifier.classify(id) {
        case .iosDevice(let udid): return (.ios, udid.uppercased())
        case .androidName(let name):
            if await isListedPhone(name) { return (.android, name) }
            return isDefinedAVD(name) ? nil : (.android, name)
        default: return nil
        }
    }

    /// The router's check for an `emulator-N` serial: a USB row, or a device list that cannot be read, fails `device.policy` and no device check runs.
    static func emulatorSerialReport(_ serial: String, source: DeviceSource?, isUSBRow: (String) async throws -> Bool) async -> DoctorReport? {
        do {
            try await DeviceRouter.requireEmulator(serial, isUSBRow: isUSBRow)
            return nil
        } catch let setup where setup is PlatformUnavailable || setup is AndroidError {
            // No SDK or no usable adb server: the Android checks report it, and no device probe runs without one.
            return nil
        } catch {
            let payload = ErrorReporter.payload(for: error)
            return DoctorReport(
                offsiderVersion: VERSION,
                udid: nil,
                device: DoctorDevice(id: serial, platform: "android", name: nil, kind: nil, source: source?.rawValue),
                xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil),
                booted: [],
                checks: [DoctorCheckResult(id: .devicePolicy, status: .fail, detail: OffsiderCommand.message(for: error), hint: payload.hint)]
            )
        }
    }

    @MainActor
    private static func liveUSBRow(_ serial: String, host: AndroidHost) async throws -> Bool {
        let backend = AndroidBackend.make(logger: OffsiderLogger(), host: host)
        do {
            let usb = try await backend.isUSBRow(serial: serial)
            await backend.close()
            return usb
        } catch {
            await backend.close()
            throw error
        }
    }

    /// The gate's decision, with a device named only by `OFFSIDER_DEVICE` refused as the router refuses it.
    static func decision(platform: DevicePlatform, key: String, fromEnvironment: Bool) -> DeviceDecision {
        let decision = DevicePolicyGate.current.decision(platform: platform, key: key)
        guard fromEnvironment, case .allowed = decision else { return decision }
        return .refused(.notAllowed)
    }

    /// One failing `device.policy` check and nothing else: no device probe runs, and `--fix` touches nothing.
    static func policyReport(_ policy: DoctorPolicy, target: (platform: DevicePlatform, key: String), source: DeviceSource?) -> DoctorReport {
        var check = policy.check
        if source == .environment, policy.refusal == "not_allowed" {
            check = DoctorCheckResult(
                id: .devicePolicy, status: .fail,
                detail: "\(target.key) is a physical device named only by OFFSIDER_DEVICE; a physical device must be named with --device, and no device checks ran",
                hint: "offsider doctor --device \(target.key)"
            )
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: nil,
            device: DoctorDevice(id: target.key, platform: target.platform.rawValue, name: nil, kind: "physical", source: source?.rawValue),
            xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil),
            booted: [],
            checks: [check],
            policy: policy
        )
    }

    static func withPolicy(_ report: DoctorReport, _ policy: DoctorPolicy) -> DoctorReport {
        DoctorReport(
            offsiderVersion: report.offsiderVersion, udid: report.udid, device: report.device, xcode: report.xcode, booted: report.booted,
            android: report.android, checks: [policy.check] + report.checks, fixes: report.fixes, host: report.host, policy: policy
        )
    }

    /// An emulator's lease is kept under its AVD name, a phone's under its serial.
    static func leaseKey(_ facts: AndroidDeviceFacts?, id: String) -> String {
        guard let facts else { return StableDeviceKey.of(id: id)?.key ?? id }
        return facts.isPhysical ? (facts.serial ?? id) : (facts.avdName ?? facts.serial ?? id)
    }

    static func leaseCheck(
        platform: DevicePlatform, key: String, lockID: String,
        store: DeviceLeaseStore = DeviceLeaseStore(),
        sessionLabel: String? = ProcessInfo.processInfo.environment[DeviceLeaseRules.sessionVariable],
        processes: ProcessTable = .live,
        selfPID: Int32 = getpid(),
        now: Date = Date(),
        holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) }
    ) -> DoctorCheckResult {
        let verdict = DeviceLeaseRules.lease(
            store.lease(platform: platform, key: key, now: now), device: key, sessionLabel: sessionLabel,
            ancestors: ProcessAncestry.ancestors(of: selfPID, in: processes), processes: processes,
            holder: holder(DeviceLockKey(platform: platform, id: lockID))
        )
        return DoctorCheckResult(id: .deviceLease, verdict: verdict)
    }

    /// The Keychain is read (attributes only) only for a device with a credential; an emulator's code is saved under its AVD name.
    static func withUnlockCode(_ facts: AndroidDeviceFacts, store: any UnlockCodeStoring, ledger: UnlockAttemptLedger) -> AndroidDeviceFacts {
        guard facts.awake?.hasCredential == true else { return facts }
        let key = facts.isPhysical ? (facts.serial ?? facts.id) : (facts.avdName ?? facts.serial ?? facts.id)
        var facts = facts
        facts.unlockCode = UnlockCodeFact(saved: (try? store.hasCode(for: key)) ?? false, lastAttemptFailed: ledger.hasFailed(key))
        return facts
    }

    private static func canonicalUDID(_ raw: String) -> String {
        if case .iosSimulator(let udid) = DeviceIDClassifier.classify(raw) {
            return udid
        }
        return raw
    }

    /// `JSONEncoder` escapes C0 only, so every other hazard is escaped after; `untrusted` names the text a device or adb reported.
    static func jsonText(_ report: DoctorReport) throws -> String {
        var paths = ["checks[].detail"]
        if report.device?.name != nil { paths.append("device.name") }
        if !report.booted.isEmpty { paths.append("booted[].name") }
        let encoded = String(decoding: try report.jsonData(), as: UTF8.self)
        return UntrustedPaths.appending(report.checks.isEmpty ? Array(paths.dropFirst()) : paths, to: TerminalText.escapingJSONHazards(encoded))
    }

    /// An agent's text, also stderr's under --json; a person's checklist and next step otherwise.
    static func write(_ report: DoctorReport, json: Bool, console: Console = .current) throws {
        let agent = DoctorRenderer.render(report) + (report.nextStep.map { "\($0)\n" } ?? "")
        if json {
            console.data(agent, to: .err)
            console.data(try Self.jsonText(report) + "\n")
        } else if console.out.profile == .person {
            let next = console.err.profile == .person ? report.nextCommand : nil
            console.data(DoctorRenderer.person(report, canvas: console.out.canvas) + (next == nil ? "" : "\n"))
            if let next { console.notice(.next(next)) }
        } else {
            console.data(agent)
        }
    }
}
