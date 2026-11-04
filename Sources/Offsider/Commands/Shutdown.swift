import ArgumentParser
import Darwin
import FBSimulatorControl
import Foundation
import OffsiderAndroid
import OffsiderCore

struct Shutdown: AsyncParsableCommand, JSONReportingCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a simulator or emulator named on the command, and wait until it has gone.",
        discussion: """
        The pair to `boot`. Takes a simulator's name or UDID, an AVD name, or an emulator's serial, and never reads \
        OFFSIDER_DEVICE. A phone, iPhone or iPad is refused. A device another session leases exits 8 (device_leased), and \
        one a command holds exits 8 (device_busy), naming the holder. Its sessions stop first, as `session stop` stops \
        them. A device already off is not a failure.

        Examples:
          offsider shutdown Offsider_E2E
          offsider shutdown "iPhone 17 Pro"
          offsider shutdown emulator-5554 --json
        """
    )

    @Argument(help: ArgumentHelp("The simulator's name or UDID, the AVD name, or the emulator's serial, from `offsider devices`.", valueName: "name"))
    var name: String

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the device to go (default: 120).")
    var timeout: Double = 120

    @Option(name: .customLong("label"), help: ArgumentHelp("The lease label that counts as this session's (else OFFSIDER_LEASE).", valueName: "text"))
    var label: String?

    @Option(name: .customLong("wait-lock"), help: ArgumentHelp("Seconds to wait for a device another Offsider command holds (default: OFFSIDER_WAIT_LOCK, else 0).", valueName: "seconds"))
    var waitLock: Double?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    var wantsJSON: Bool { json }

    static let allowedTimeout = 5.0...600.0

    func validate() throws {
        if DeviceIDClassifier.classify(name) == .empty {
            throw ValidationError("shutdown needs a simulator or AVD name; run `offsider devices` to see them.")
        }
        guard timeout.isFinite, Self.allowedTimeout.contains(timeout) else {
            throw ValidationError("--timeout must be between 5 and 600 seconds.")
        }
        if let waitLock, !(waitLock.isFinite && (0...DeviceClaims.maximumWait).contains(waitLock)) {
            throw ValidationError("--wait-lock must be from 0 to \(Int(DeviceClaims.maximumWait)) seconds.")
        }
        if let label, DeviceLease.validLabel(label) == nil {
            throw ValidationError("--label must be 1 to 80 printable characters.")
        }
    }

    /// The refusal for a name that can only be a phone, from its shape alone.
    static func phoneRefusal(_ name: String) -> CLIError? {
        switch DeviceIDClassifier.classify(name) {
        case .iosDevice(let udid):
            return CLIError(errorDescription: "shutdown stops simulators and emulators, and \(udid) is a physical iPhone or iPad. Nothing was sent to it.", reason: .deviceNotAllowed)
        case .androidNetworkSerial(let serial):
            return CLIError(errorDescription: "shutdown stops simulators and emulators, and \(serial) is a network adb connection. Nothing was sent to it.", reason: .deviceNotAllowed)
        default:
            return nil
        }
    }

    /// What `name` names; the phone and ambiguity checks run before anything can stop.
    enum Target {
        case emulator(EmulatorStopTarget)
        case simulator(FBSimulator)
        case off(platform: DevicePlatform, name: String, id: String?)
    }

    @MainActor
    func run() async throws {
        if let refusal = Self.phoneRefusal(name) { throw refusal }
        let console = Console.current
        let logger = OffsiderLogger()
        let limit = Duration.milliseconds(Int((timeout * 1000).rounded()))
        let stopper = EmulatorStopper(host: .cli(), log: AndroidBackend.logBridge(logger: logger))
        let booter = SimulatorBooter(logger: logger)
        let report = try await console.progress("Finding \(name)") {
            let target = try await Self.resolve(name, stopper: stopper, booter: booter)
            console.relabel("Stopping \(target.shownName)")
            return try await Self.stop(
                target.step, label: label, timeout: limit, claims: .current, store: DeviceLeaseStore(), environment: ProcessInfo.processInfo.environment,
                stopSessions: { device in await SessionStop.stopSessions(device: device) },
                stopDevice: {
                    switch target {
                    case .emulator(let emulator): _ = try await stopper.stop(emulator, timeout: limit)
                    case .simulator(let simulator): _ = try await booter.shutdown(simulator, timeout: limit)
                    case .off: break
                    }
                }
            )
        }
        for sentence in report.notRemoved { console.notice(.warning(sentence)) }
        guard !json else { return console.data(report.jsonLine() + "\n") }
        console.show(StartPersonView.shutDown(report))
    }

    /// A name both an AVD and a simulator have stops neither, so it never guesses.
    @MainActor
    static func resolve(_ name: String, stopper: EmulatorStopper, booter: SimulatorBooter) async throws -> Target {
        let id = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = DeviceIDClassifier.classify(id)
        var unreadable: (any Error)?
        var lookup = EmulatorStopLookup.unknown
        switch kind {
        case .androidSerial:
            lookup = try await stopper.find(id)
        case .androidName:
            do {
                lookup = try await stopper.find(id)
            } catch let error as PlatformUnavailable {
                unreadable = error
            }
        default:
            break
        }
        if case .androidSerial = kind {
            guard case .running(let target) = lookup else { return .off(platform: .android, name: id, id: nil) }
            return .emulator(target)
        }
        let simulator: FBSimulator?
        do {
            simulator = try await booter.find(id, command: "shutdown")
        } catch let error as CLIError where error.reason == .deviceAmbiguous {
            throw error
        } catch {
            if case .iosSimulator = kind { throw error }
            simulator = nil
            unreadable = unreadable ?? error
        }
        switch (lookup, simulator) {
        case (.unknown, nil):
            if let unreadable { throw unreadable }
            throw CLIError(errorDescription: "No simulator or AVD is named \(id). Nothing was stopped.", reason: .deviceNotFound, hint: "offsider devices")
        case (.unknown, let simulator?):
            return try Self.simulatorTarget(simulator)
        case (.running(let emulator), nil):
            return .emulator(emulator)
        case (.off(let avd), nil):
            return .off(platform: .android, name: avd, id: nil)
        case (.running, let simulator?), (.off, let simulator?):
            throw CLIError(
                errorDescription: "\(id) names both an AVD and the simulator \(simulator.udid), so Offsider stopped nothing. Pass the simulator's UDID, or the emulator's serial from `offsider devices`.",
                reason: .deviceAmbiguous, hint: "offsider devices"
            )
        }
    }

    private static func simulatorTarget(_ simulator: FBSimulator) throws -> Target {
        SimulatorShutdownStep.step(for: FBiOSTargetStateStringFromState(simulator.state).rawValue) == .alreadyOff
            ? .off(platform: .ios, name: simulator.name, id: simulator.udid)
            : .simulator(simulator)
    }

    /// One device's stop, in the order that keeps a refusal from changing anything: holders first, then its sessions, then the device.
    struct Step: Equatable {
        let platform: DevicePlatform
        let name: String
        /// The serial or UDID; nil for an AVD that is off.
        let id: String?
        /// What a lease is kept under: the AVD name or the uppercased UDID.
        let leaseKey: String
        let running: Bool
    }

    @MainActor
    static func stop(
        _ step: Step, label: String?, timeout: Duration, claims: DeviceClaims, store: DeviceLeaseStore, environment: [String: String],
        now: () -> Date = Date.init, selfPID: Int32 = getpid(), processes: ProcessTable = .live,
        stopSessions: (String) async -> (stopped: [DeviceSessionRow.Stopped], left: [DeviceSessionRow.Left], recordingKept: Notice?),
        stopDevice: () async throws -> Void
    ) async throws -> ShutdownReport {
        guard step.running, let id = step.id else {
            return ShutdownReport(platform: step.platform, name: step.name, id: step.id, alreadyOff: true)
        }
        let target = (platform: step.platform, key: step.leaseKey)
        let sessionLabel = label.flatMap(DeviceLease.validLabel) ?? environment[DeviceLeaseRules.sessionVariable]
        func refuseLease() throws {
            if let failure = LeaseCommand.check(target, label: sessionLabel, json: false, store: store, now: now(), selfPID: selfPID, processes: processes).failure { throw failure }
        }
        try refuseLease()
        try await claims.claim(DeviceLockKey(platform: step.platform, id: id))
        // A wait for the lock can outlast a lease set meanwhile.
        try refuseLease()
        let sessions = await stopSessions(id)
        if let kept = sessions.recordingKept {
            throw CLIError(errorDescription: "A recording on \(step.name) would not stop, so Offsider left the device running. \(kept.agentText ?? kept.text)", reason: .deviceBusy, hint: "offsider session stop --device \(id)")
        }
        try await stopDevice()
        return ShutdownReport(platform: step.platform, name: step.name, id: id, alreadyOff: false, sessions: sessions.stopped.flatMap(\.parts), notRemoved: sessions.left.map(\.sentence))
    }
}

extension Shutdown.Target {
    var shownName: String { step.name }

    var step: Shutdown.Step {
        switch self {
        case .emulator(let target):
            return Shutdown.Step(platform: .android, name: target.avd, id: target.serial, leaseKey: target.avd, running: true)
        case .simulator(let simulator):
            return Shutdown.Step(platform: .ios, name: simulator.name, id: simulator.udid.uppercased(), leaseKey: simulator.udid.uppercased(), running: true)
        case .off(let platform, let name, let id):
            return Shutdown.Step(platform: platform, name: name, id: id, leaseKey: id?.uppercased() ?? name, running: false)
        }
    }
}
