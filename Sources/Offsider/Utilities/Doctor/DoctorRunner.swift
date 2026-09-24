import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

/// Facts from one pass of the checks, kept so fixes can decide what applies.
struct DoctorContext {
    var developerDirectory: String?
    var xcodeMajor: Int?
    var deviceHubAppPath: String?
    var deviceHubState: DeviceHubState?
    var simulatorAppRunning = false
    var brokerRootPath = HIDBroker.brokerRootPath()
    var brokerState: BrokerDirectoryState = .absent
    var simulatorBooted = false
}

struct DoctorRun {
    var checks: [DoctorCheckResult] = []
    var xcode = XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil)
    var booted: [BootedSimulator] = []
    var context = DoctorContext()
}

@MainActor
struct DoctorRunner {
    let udid: String?
    let environment: [String: String]
    let logger: OffsiderLogger

    func run() async -> DoctorRun {
        var run = DoctorRun()
        var developerDirectory: String?
        var version: String?
        var build: String?
        var coreSimulator: String?
        var frameworksLoaded = false

        switch DoctorProbes.developerDirectory(environment: environment) {
        case .success(let resolved):
            developerDirectory = resolved.path
            run.checks.append(DoctorCheckResult(id: .developerDir, status: .pass, detail: "\(resolved.path) (\(resolved.source))"))
        case .failure(let error):
            run.checks.append(DoctorCheckResult(
                id: .developerDir,
                status: .fail,
                detail: error.localizedDescription,
                hint: "Select Xcode with xcode-select -s <path> or set DEVELOPER_DIR."
            ))
        }

        if let developerDirectory {
            (version, build) = DoctorProbes.xcodeVersion(developerDirectory: developerDirectory)
            run.checks.append(DoctorCheckResult(id: .xcodeVersion, verdict: DoctorRules.xcodeVersion(version, build: build)))
            if let error = DoctorProbes.loadFrameworks(logger: logger) {
                run.checks.append(DoctorCheckResult(
                    id: .frameworks,
                    status: .fail,
                    detail: error.localizedDescription,
                    hint: "Run xcodebuild -runFirstLaunch for the selected Xcode."
                ))
            } else {
                frameworksLoaded = true
                run.checks.append(DoctorCheckResult(id: .frameworks, status: .pass, detail: "CoreSimulator and SimulatorKit loaded"))
            }
        } else {
            run.checks.append(.skipped(.xcodeVersion, "requires xcode.developer-dir"))
            run.checks.append(.skipped(.frameworks, "requires xcode.developer-dir"))
        }

        let xcodeMajor = DoctorRules.majorVersion(version)
        if frameworksLoaded {
            coreSimulator = DoctorProbes.coreSimulatorVersion()
            run.checks.append(DoctorCheckResult(id: .coreSimulator, verdict: DoctorRules.coreSimulator(version: coreSimulator, xcodeMajor: xcodeMajor)))
        } else {
            run.checks.append(.skipped(.coreSimulator, "requires xcode.frameworks"))
        }

        var deviceHubProcessIdentifier: pid_t?
        if let developerDirectory, xcodeMajor != nil {
            let simulatorAppRunning = DoctorProbes.isSimulatorAppRunning()
            run.context.simulatorAppRunning = simulatorAppRunning
            run.checks.append(DoctorCheckResult(id: .simulatorApp, verdict: DoctorRules.simulatorApp(isRunning: simulatorAppRunning, xcodeMajor: xcodeMajor)))

            let appPath = DoctorProbes.deviceHubAppPath(developerDirectory: developerDirectory)
            let hub = DoctorProbes.deviceHubState(appPath: appPath)
            deviceHubProcessIdentifier = hub.state == .running ? hub.processIdentifier : nil
            run.context.deviceHubAppPath = appPath
            run.context.deviceHubState = hub.state
            run.checks.append(DoctorCheckResult(
                id: .deviceHub,
                verdict: DoctorRules.deviceHub(hub.state, appPath: appPath, xcodeMajor: xcodeMajor),
                fixable: DoctorRules.isDeviceHubFixable(hub.state, xcodeMajor: xcodeMajor)
            ))
        } else {
            run.checks.append(.skipped(.simulatorApp, "requires xcode.version"))
            run.checks.append(.skipped(.deviceHub, "requires xcode.version"))
        }

        run.checks.append(DoctorCheckResult(
            id: .stabilization,
            verdict: DoctorRules.stabilization(environmentValue: environment[HIDStabilization.environmentKey])
        ))

        let brokerPath = run.context.brokerRootPath
        let brokerState = DoctorProbes.brokerDirectoryState(path: brokerPath)
        run.context.brokerState = brokerState
        run.checks.append(DoctorCheckResult(
            id: .brokerDirectory,
            verdict: DoctorRules.brokerDirectory(brokerState, path: brokerPath),
            fixable: DoctorRules.isBrokerDirectoryFixable(brokerState)
        ))

        var simulators: [FBSimulator] = []
        var simulatorsListed = false
        if frameworksLoaded {
            do {
                simulators = try await DoctorProbes.simulators(logger: logger)
                simulatorsListed = true
                let booted = simulators.filter { $0.state == .booted }
                run.booted = booted.map(DoctorProbes.bootedSimulator).sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
                run.checks.append(DoctorCheckResult(id: .bootedSimulators, verdict: DoctorRules.bootedSimulators(count: booted.count)))
            } catch {
                run.checks.append(DoctorCheckResult(
                    id: .bootedSimulators,
                    status: .fail,
                    detail: "Could not list simulators: \(error.localizedDescription)",
                    hint: "Run xcodebuild -runFirstLaunch for the selected Xcode."
                ))
            }
        } else {
            run.checks.append(.skipped(.bootedSimulators, "requires xcode.frameworks"))
        }

        run.xcode = XcodeSummary(developerDir: developerDirectory, version: version, build: build, coreSimulator: coreSimulator)
        run.context.developerDirectory = developerDirectory
        run.context.xcodeMajor = xcodeMajor

        if let udid {
            let perSimulator = await simulatorChecks(
                udid: udid,
                simulators: simulatorsListed ? simulators : nil,
                unavailableReason: frameworksLoaded ? "requires simulators.booted" : "requires xcode.frameworks",
                xcodeMajor: xcodeMajor,
                dtuhidEra: DoctorRules.isDTUHIDEra(coreSimulatorVersion: coreSimulator),
                deviceHubProcessIdentifier: deviceHubProcessIdentifier,
                context: &run.context
            )
            run.checks.append(contentsOf: perSimulator)
        }
        return run
    }

    private func simulatorChecks(
        udid: String,
        simulators: [FBSimulator]?,
        unavailableReason: String,
        xcodeMajor: Int?,
        dtuhidEra: Bool,
        deviceHubProcessIdentifier: pid_t?,
        context: inout DoctorContext
    ) async -> [DoctorCheckResult] {
        let dependents: [DoctorCheckID] = [.deviceWindow, .resizeMode, .dtuhidd, .dtuhidActiveFlag, .hidTransport, .accessibility]
        guard let simulators else {
            return ([.simulatorState] + dependents).map { .skipped($0, unavailableReason) }
        }
        guard let simulator = simulators.first(where: { $0.udid == udid }) else {
            return [DoctorCheckResult(
                id: .simulatorState,
                status: .fail,
                detail: CLIError.simulatorNotFound(udid: udid).userFacingDescription,
                hint: "Check the UDID with offsider list-simulators."
            )] + dependents.map { .skipped($0, "requires simulator.state") }
        }
        guard simulator.state == .booted else {
            return [DoctorCheckResult(
                id: .simulatorState,
                status: .fail,
                detail: "\(simulator.name) is not booted (\(FBiOSTargetStateStringFromState(simulator.state)))",
                hint: "Boot it: xcrun simctl boot \(udid)"
            )] + dependents.map { .skipped($0, "requires simulator.state") }
        }
        context.simulatorBooted = true

        var checks: [DoctorCheckResult] = []
        let summary = "\(simulator.name), \(simulator.osVersion.name.rawValue)"
        let uptime = DoctorProbes.bootUptime(udid: udid)
        if let uptime {
            let verdict = DoctorRules.bootUptime(seconds: uptime.seconds)
            checks.append(DoctorCheckResult(id: .simulatorState, status: verdict.status, detail: "\(summary), \(verdict.detail)", hint: verdict.hint))
        } else {
            checks.append(DoctorCheckResult(
                id: .simulatorState,
                status: .warn,
                detail: "\(summary), still starting (launchd_sim not found); HID checks skipped",
                hint: "Wait a few seconds and run doctor again."
            ))
        }

        if DoctorRules.isDeviceHubEra(xcodeMajor: xcodeMajor) {
            let window = DoctorProbes.deviceWindowState(deviceHubProcessIdentifier: deviceHubProcessIdentifier, simulatorName: simulator.name)
            checks.append(DoctorCheckResult(
                id: .deviceWindow,
                verdict: DoctorRules.deviceWindow(window, udid: udid),
                fixable: window == .notFound
            ))
            checks.append(DoctorCheckResult(id: .resizeMode, verdict: await DoctorProbes.resizeMode(udid: udid)))
        } else {
            checks.append(.skipped(.deviceWindow, "Only checked with Xcode 27 or later"))
            checks.append(.skipped(.resizeMode, "Only checked with Xcode 27 or later"))
        }

        // The flag verdict depends on the selected transport, so probe it first and report it in id order.
        let transportCheck: DoctorCheckResult
        var selectedTransport: String?
        if let uptime, uptime.seconds >= DoctorRules.minimumBootUptime {
            let probe = await DoctorProbes.hidTransport(simulator: simulator)
            selectedTransport = probe.transport
            transportCheck = DoctorCheckResult(id: .hidTransport, verdict: probe.verdict)
        } else {
            let age = uptime.map { "simulator booted \(Int($0.seconds)) s ago" } ?? "simulator is still starting"
            transportCheck = .skipped(.hidTransport, age)
        }

        if !dtuhidEra {
            checks.append(.skipped(.dtuhidd, "Only used from CoreSimulator \(DoctorRules.dtuhidCoreSimulatorVersion)"))
            checks.append(.skipped(.dtuhidActiveFlag, "Only used from CoreSimulator \(DoctorRules.dtuhidCoreSimulatorVersion)"))
        } else if let uptime {
            let dtuhiddPid = DoctorProbes.dtuhiddProcessIdentifier(bootIdentity: uptime.identity)
            checks.append(DoctorCheckResult(id: .dtuhidd, verdict: DoctorRules.dtuhidd(processIdentifier: dtuhiddPid)))
            let flag = await DoctorProbes.dtuhidActiveFlag(udid: udid)
            checks.append(DoctorCheckResult(
                id: .dtuhidActiveFlag,
                verdict: DoctorRules.dtuhidState(flag: flag, dtuhiddRunning: dtuhiddPid != nil, dtuhidEra: true, selectedTransport: selectedTransport, udid: udid)
            ))
        } else {
            checks.append(.skipped(.dtuhidd, "launchd_sim not found"))
            checks.append(.skipped(.dtuhidActiveFlag, "launchd_sim not found"))
        }

        checks.append(transportCheck)

        let accessibility = await DoctorProbes.accessibility(udid: udid, logger: logger)
        checks.append(DoctorCheckResult(id: .accessibility, verdict: DoctorRules.accessibility(accessibility)))
        return checks
    }
}
