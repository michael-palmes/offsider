import ArgumentParser
import FBSimulatorControl
import Foundation
import OffsiderAndroid
import OffsiderCore

struct Boot: AsyncParsableCommand, JSONReportingCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an Android emulator (AVD) or an iOS simulator and wait until it has booted; prints its serial or UDID.",
        discussion: """
        A name no AVD has, or a UDID, boots the iOS simulator it names; --timeout and --json apply, the emulator \
        options do not.

        The emulator runs detached with its window (use --headless to hide it) and always with -no-metrics; its output \
        goes to $TMPDIR/offsider-boot-<avd>.log. --memory, --no-snapshot-load and --emulator-arg add to that launch; \
        --emulator-arg takes only \(EmulatorArguments.allowedNames), each value in its own --emulator-arg, and anything \
        else exits 64 before anything starts. An AVD that is \
        already running is not started again: boot prints its serial, waiting first if it is still booting, and says \
        which launch options it ignored. Ctrl+C stops the wait, not the emulator.

        After the boot it reads the lock state once: a device set up with a PIN, pattern or password that has not \
        been unlocked since boot exits 7 (device_locked), since apps cannot start until it is unlocked.

        Examples:
          offsider boot Pixel_9
          DEVICE=$(offsider boot Pixel_9 --headless)
          offsider boot Pixel_9 --memory 4096 --no-snapshot-load --emulator-arg -gpu --emulator-arg host
          offsider boot "iPhone 17 Pro"
        """
    )

    @Argument(help: ArgumentHelp("The AVD name, or a simulator's name or UDID, from `offsider devices`.", valueName: "avd"))
    var avd: String

    @Flag(name: .customLong("headless"), help: "Run the emulator without its window.")
    var headless = false

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the boot to finish (default: 240).")
    var timeout: Double = 240

    @Option(name: .customLong("memory"), help: ArgumentHelp("RAM for the emulator in MB, from 1024 to 16384 (-memory).", valueName: "MB"))
    var memory: Int?

    @Flag(name: .customLong("no-snapshot-load"), help: "Cold boot instead of loading the quick-boot snapshot.")
    var noSnapshotLoad = false

    @Option(
        name: .customLong("emulator-arg"),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp("One more token for the emulator command line, from the allowed flags and their values; repeat for each token, such as --emulator-arg -gpu --emulator-arg host.", valueName: "token")
    )
    var emulatorArguments: [String] = []

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of the serial: the AVD, serial, RAM and lock state.")
    var json = false

    var wantsJSON: Bool { json }

    static let allowedTimeout = 10.0...1800.0
    static let allowedMemory = 1024...16384

    func validate() throws {
        switch DeviceIDClassifier.classify(avd) {
        case .iosSimulator:
            try refuseEmulatorOptions()
        case .iosDevice:
            throw ValidationError("boot starts Android emulators, and \(avd) is a physical iPhone or iPad. Turn it on, unlock it and connect its cable, then run `offsider devices`.")
        case .androidSerial, .androidNetworkSerial:
            throw ValidationError("boot takes an AVD name, not a serial. Run `offsider devices` to see AVD names.")
        case .empty:
            throw ValidationError("boot needs an AVD or simulator name; run `offsider devices` to see them.")
        case .unrecognised:
            try refuseEmulatorOptions()
        case .androidName:
            break
        }
        guard timeout.isFinite, Self.allowedTimeout.contains(timeout) else {
            throw ValidationError("--timeout must be between 10 and 1800 seconds.")
        }
        if let memory, !Self.allowedMemory.contains(memory) {
            throw ValidationError("--memory must be from 1024 to 16384 MB; got \(memory).")
        }
        if let refusal = EmulatorArguments.refusal(in: emulatorArguments) {
            throw ValidationError(refusal)
        }
    }

    /// A simulator UDID or a name no AVD can have takes no emulator options.
    private func refuseEmulatorOptions() throws {
        if memory != nil || noSnapshotLoad || !emulatorArguments.isEmpty {
            throw ValidationError("--memory, --no-snapshot-load and --emulator-arg start emulators only, and '\(avd)' is not an AVD name.")
        }
    }

    @MainActor
    func run() async throws {
        let logger = OffsiderLogger()
        switch DeviceIDClassifier.classify(avd) {
        case .iosSimulator, .unrecognised:
            return try await bootSimulator(logger: logger, otherwise: nil)
        default:
            do {
                try await bootEmulator(logger: logger)
            } catch let error as AndroidError where error.kind == .noAVDNamed {
                try await bootSimulator(logger: logger, otherwise: error)
            } catch let error as PlatformUnavailable {
                try await bootSimulator(logger: logger, otherwise: error)
            }
        }
    }

    /// Boots the simulator `avd` names; when none does, throws `otherwise`, or a not-found error naming devices.
    @MainActor
    private func bootSimulator(logger: OffsiderLogger, otherwise: (any Error)?) async throws {
        let booter = SimulatorBooter(logger: logger)
        let found: FBSimulator?
        do {
            found = try await booter.find(avd)
        } catch let error as CLIError where error.reason == .deviceAmbiguous || otherwise == nil {
            throw error
        } catch {
            throw otherwise ?? error
        }
        guard let simulator = found else {
            if let otherwise { throw otherwise }
            throw CLIError(errorDescription: "No simulator or AVD is named \(avd).", reason: .deviceNotFound, hint: "offsider devices")
        }
        if memory != nil || noSnapshotLoad || !emulatorArguments.isEmpty {
            throw ValidationError("--memory, --no-snapshot-load and --emulator-arg start emulators only, and \(avd) is a simulator.")
        }
        let console = Console.current
        var lines = StartPersonView.Lines(console: console)
        let alreadyRunning = try await console.progress("Starting \(simulator.name)") {
            try await booter.boot(simulator, timeout: .milliseconds(Int((timeout * 1000).rounded()))) { line in
                StartPersonView.bootProgress(line, lines: &lines)
            }
        }
        guard !json else {
            lines.flush()
            return console.data(SimulatorBootReport(udid: simulator.udid, name: simulator.name, alreadyRunning: alreadyRunning).jsonLine() + "\n")
        }
        console.show(StartPersonView.booted(name: simulator.name, id: simulator.udid, alreadyRunning: alreadyRunning, notices: lines.notices))
    }

    @MainActor
    private func bootEmulator(logger: OffsiderLogger) async throws {
        let booter = EmulatorBooter(host: .live(), log: AndroidBackend.logBridge(logger: logger))
        let request = EmulatorBootRequest(
            avdName: avd,
            headless: headless,
            timeout: .milliseconds(Int((timeout * 1000).rounded())),
            memoryMB: memory,
            noSnapshotLoad: noSnapshotLoad,
            extraArguments: emulatorArguments
        )
        let console = Console.current
        var lines = StartPersonView.Lines(console: console)
        let result: EmulatorBootResult
        let reading: AwakeReading?
        do {
            (result, reading) = try await console.progress("Starting \(avd)") {
                let result = try await booter.boot(request) { line in
                    StartPersonView.bootProgress(line, lines: &lines)
                }
                console.relabel("Checking \(avd) is ready")
                return (result, await booter.settledState(serial: result.serial))
            }
        } catch {
            lines.flush()
            throw error
        }
        let lock = Self.lockReport(reading, key: avd, store: KeychainUnlockCodeStore(), ledger: UnlockAttemptLedger())
        var report = BootReport(
            avd: avd, serial: result.serial, alreadyRunning: result.alreadyRunning, grpc: result.hasGRPC, logPath: result.logPath,
            memoryMB: reading?.memTotalKB.map { $0 / 1024 }, ignored: result.ignored, bootedBy: booter.bootedBy(serial: result.serial), lock: lock
        )
        if let notice = BootReport.memoryNotice(avd: avd, reading: reading) {
            lines.add(notice)
        }
        if let failure = BootReport.firstUnlockFailure(avd: avd, serial: result.serial, alreadyRunning: result.alreadyRunning, reading: reading, lock: lock) {
            lines.flush()
            let error = CLIError(errorDescription: failure.message, reason: .deviceLocked, hint: failure.hint)
            guard json else { throw error }
            report.error = ErrorReporter.payload(for: error)
            console.data(report.jsonLine() + "\n")
            throw ReportedFailure(underlying: error, exitCode: report.exitCode)
        }
        if let notice = BootReport.screenNotice(avd: avd, serial: result.serial, reading: reading) {
            lines.add(notice)
        }
        guard !json else {
            lines.flush()
            return console.data(report.jsonLine() + "\n")
        }
        console.show(StartPersonView.booted(name: avd, id: result.serial, alreadyRunning: result.alreadyRunning, notices: lines.notices))
    }

    /// Asks the Keychain (attributes only, never the code) and the ledger only when the device has a credential.
    static func lockReport(_ reading: AwakeReading?, key: String, store: any UnlockCodeStoring, ledger: UnlockAttemptLedger) -> LockReport {
        guard reading?.hasCredential == true else { return LockReport(reading, savedCode: false, lastAttemptFailed: false) }
        return LockReport(reading, savedCode: (try? store.hasCode(for: key)) ?? false, lastAttemptFailed: ledger.hasFailed(key))
    }
}
