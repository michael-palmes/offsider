import Foundation
import OffsiderCore

public struct EmulatorBootRequest: Sendable {
    public let avdName: String
    public let headless: Bool
    public let timeout: Duration
    public let memoryMB: Int?
    public let noSnapshotLoad: Bool
    /// Checked by `EmulatorArguments.refusal(in:)` before the request is made.
    public let extraArguments: [String]

    public init(avdName: String, headless: Bool, timeout: Duration, memoryMB: Int? = nil, noSnapshotLoad: Bool = false, extraArguments: [String] = []) {
        self.avdName = avdName
        self.headless = headless
        self.timeout = timeout
        self.memoryMB = memoryMB
        self.noSnapshotLoad = noSnapshotLoad
        self.extraArguments = extraArguments
    }

    /// The launch options a running emulator cannot take, as the user wrote them.
    var launchOnlyOptions: [String] {
        (headless ? ["--headless"] : []) + (memoryMB != nil ? ["--memory"] : []) + (noSnapshotLoad ? ["--no-snapshot-load"] : [])
            + (extraArguments.isEmpty ? [] : ["--emulator-arg"])
    }
}

public struct EmulatorBootResult: Equatable, Sendable {
    public let serial: String
    public let alreadyRunning: Bool
    public let hasGRPC: Bool
    /// Nil when Offsider did not start the emulator.
    public let logPath: String?
    /// Launch options left unused because the AVD was already running or starting.
    public var ignored: [String] = []
}

/// Starts the emulator so it outlives the command; a protocol so tests never start one.
protocol EmulatorLaunching: Sendable {
    func launch(executable: URL, arguments: [String], environment: [String: String], logPath: String) throws -> Int32
    /// The exit status once the launched process has exited (128 plus the signal when killed), else nil.
    func exitStatus(of pid: Int32) -> Int32?
}

extension DetachedProcess: EmulatorLaunching {}

/// `offsider boot`: finds the AVD running or starts it detached, then waits for Android and the gRPC endpoint.
@MainActor
public struct EmulatorBooter {
    static let serialPoll: Duration = .milliseconds(250)
    static let bootPoll: Duration = .seconds(1)
    /// How long to wait for a discovery file before looking for the new serial in adb instead.
    static let discoveryGrace: Duration = .seconds(30)

    let host: AndroidHost
    let log: AndroidLog

    public init(host: AndroidHost, log: @escaping AndroidLog) {
        self.host = host
        self.log = log
    }

    /// Never `-port`, `-ports` or any `-grpc` flag: a plain launch serves token and JWT auth on loopback only.
    static func launchArguments(avdName: String, headless: Bool) -> [String] {
        launchArguments(EmulatorBootRequest(avdName: avdName, headless: headless, timeout: .zero))
    }

    static func launchArguments(_ request: EmulatorBootRequest) -> [String] {
        ["-avd", request.avdName, "-no-metrics"]
            + (request.headless ? ["-no-window"] : [])
            + (request.memoryMB.map { ["-memory", String($0)] } ?? [])
            + (request.noSnapshotLoad ? ["-no-snapshot-load"] : [])
            + request.extraArguments
    }

    static func ignoredLine(_ options: [String], avdName: String, starting: Bool) -> String? {
        guard !options.isEmpty else { return nil }
        let list = options.count == 1 ? options[0] : options.dropLast().joined(separator: ", ") + " and " + options.last!
        return "\(list) ignored: \(avdName) is already \(starting ? "starting" : "running")."
    }

    static func logPath(avdName: String, host: AndroidHost) -> String {
        ((host.variable("TMPDIR") ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("offsider-boot-\(avdName).log")
    }

    public func boot(_ request: EmulatorBootRequest, progress: (String) -> Void) async throws -> EmulatorBootResult {
        let deadline = host.uptime() + request.timeout
        let name = request.avdName
        let sdk = try AndroidSDK.locate(host: host)
        let catalog = AVDCatalog(host: host)
        let client = AdbClient(endpoint: try LoopbackEndpoint.adbServer(environment: host.environment), connector: host.adbConnector, timing: host.timing)
        guard let avd = catalog.info(named: name) else {
            // Only an already-running server is asked, so a mistyped name never starts adb.
            if let rows = try? await client.devices(), rows.contains(where: { $0.serial == name && $0.consolePort == nil }) {
                throw AndroidError.bootPhone(name)
            }
            throw AndroidError.noAVDNamed(name, available: catalog.all().map(\.name))
        }
        try await AdbServerLauncher(adb: sdk.adb).ensureRunning(client: client, host: host)
        let wait = BootWait(host: host, log: log, client: client, avdName: name, deadline: deadline, timeout: request.timeout)

        let running = try await AndroidDeviceDirectory(client: client, host: host).runningEmulators(detailed: false).filter { $0.avdName == name }
        if running.count > 1 {
            throw AndroidError.avdRunningTwice(name, serials: running.map(\.serial))
        }
        let ignored = request.launchOnlyOptions
        if let existing = running.first {
            if let line = Self.ignoredLine(ignored, avdName: name, starting: false) { progress(line) }
            let emulator = try await AndroidDeviceDirectory(client: client, host: host).runningEmulator(serial: existing.serial)
            if let emulator, emulator.state == .device, emulator.bootCompleted {
                let hasGRPC = wait.discovery(for: existing.serial)?.grpcPort != nil
                progress("\(name) is already running as \(existing.serial)" + (hasGRPC ? "." : " without gRPC; commands will use adb."))
                return EmulatorBootResult(serial: existing.serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil, ignored: ignored)
            }
            progress("\(name) is already starting as \(existing.serial).")
            let hasGRPC = try await wait.untilBooted(existing.serial, logPath: nil, progress: progress)
            return EmulatorBootResult(serial: existing.serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil, ignored: ignored)
        }

        let knownFiles = Set(EmulatorDiscovery.live(host: host).map(\.path))
        let knownSerials = Set(try await client.devices().map(\.serial))
        if let holder = instanceLockHolder(avd) {
            if let line = Self.ignoredLine(ignored, avdName: name, starting: true) { progress(line) }
            progress("\(name) is already starting (pid \(holder)); waiting for it.")
            let serial = try await wait.serial(pid: holder, knownFiles: knownFiles, knownSerials: knownSerials, launched: nil, logPath: nil)
            let hasGRPC = try await wait.untilBooted(serial, logPath: nil, progress: progress)
            return EmulatorBootResult(serial: serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil, ignored: ignored)
        }

        guard host.files.isExecutableFile(atPath: sdk.emulator.path) else {
            throw AndroidError.emulatorMissing(sdkRoot: sdk.root.path)
        }
        let staleLocks = removeStaleLocks(avd)
        if !staleLocks.isEmpty {
            progress("Removed \(staleLocks.joined(separator: " and ")) left by an emulator that is no longer running.")
        }
        let logPath = Self.logPath(avdName: name, host: host)
        var environment = host.environment
        environment["ADB_MDNS"] = "0"
        let pid: Int32
        do {
            pid = try host.launcher.launch(
                executable: sdk.emulator,
                arguments: Self.launchArguments(request),
                environment: environment,
                logPath: logPath
            )
        } catch let failure as DetachedProcessError {
            throw AndroidError.emulatorLaunchFailed(path: failure.path, detail: failure.detail).namingStaleLocks(staleLocks, in: avd.directory.path)
        }
        log(.debug, "Started \(sdk.emulator.path) as pid \(pid); its output goes to \(logPath)")
        progress("Starting \(name)...")
        do {
            let serial = try await wait.serial(pid: pid, knownFiles: knownFiles, knownSerials: knownSerials, launched: pid, logPath: logPath)
            let hasGRPC = try await wait.untilBooted(serial, logPath: logPath, progress: progress)
            return EmulatorBootResult(serial: serial, alreadyRunning: false, hasGRPC: hasGRPC, logPath: logPath)
        } catch let error as AndroidError where error.kind == .emulatorExited {
            throw error.namingStaleLocks(staleLocks, in: avd.directory.path)
        }
    }

    /// The emulator process serving `serial`, from its discovery file; nil when it has none.
    public func bootedBy(serial: String) -> ProcessStamp? {
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial),
              let discovery = EmulatorDiscovery.live(host: host).first(where: { $0.consolePort == port }),
              let started = host.processStartTime(discovery.pid) else { return nil }
        return ProcessStamp(pid: discovery.pid, startedAt: started)
    }

    static let unlockPoll: Duration = .milliseconds(500)
    static let unlockGrace: Duration = .seconds(10)

    /// Screen, lock screen, first unlock and RAM in one round trip; nil when unreadable.
    public func readState(serial: String) async -> AwakeReading? {
        guard let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return nil }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        let script = AndroidAwakeState.readScript + AndroidAwakeState.userStateScript
        guard let result = try? await client.shell(script, on: serial, timeout: .seconds(5), label: "dumpsys power; am get-started-user-state") else { return nil }
        return AndroidAwakeState.parse(result.stdoutText)
    }

    /// A device with no credential reads as unlocking for a moment after boot, so it is read again until it settles, for up to 10 s.
    public func settledState(serial: String) async -> AwakeReading? {
        let deadline = host.uptime() + Self.unlockGrace
        var reading = await readState(serial: serial)
        while let current = reading, !current.hasCredential, current.userUnlocked == false, host.uptime() < deadline {
            try? await host.sleep(Self.unlockPoll)
            reading = await readState(serial: serial) ?? current
        }
        return reading
    }

    static let instanceLockName = "hardware-qemu.ini.lock"

    /// Deletes `hardware-qemu.ini.lock` when its pid is gone (or is no longer an emulator); returns the names removed.
    /// `multiinstance.lock` is left alone: it is an flock that dies with its holder, so it never blocks a launch.
    func removeStaleLocks(_ avd: AVDInfo) -> [String] {
        let lock = avd.directory.appendingPathComponent(Self.instanceLockName)
        guard let pid = lockPID(lock), !isLiveEmulator(pid), (try? host.files.removeItem(atPath: lock.path)) != nil else { return [] }
        return [Self.instanceLockName]
    }

    private func lockPID(_ lock: URL) -> Int32? {
        host.files.contents(atPath: lock.path).flatMap(Self.lockPID)
    }

    /// The emulator writes its pid followed by a NUL, so only the leading digits count.
    static func lockPID(_ data: Data) -> Int32? {
        let digits = data.prefix { (0x30...0x39).contains($0) }
        guard let pid = Int32(String(decoding: digits, as: UTF8.self)), pid > 0 else { return nil }
        return pid
    }

    private func isLiveEmulator(_ pid: Int32) -> Bool {
        host.isProcessAlive(pid) && host.processPath(pid).map(EmulatorDiscovery.isEmulatorExecutable) == true
    }

    /// The emulator's own instance lock (`hardware-qemu.ini.lock` holds its pid), when a live emulator holds it.
    func instanceLockHolder(_ avd: AVDInfo) -> Int32? {
        guard let pid = lockPID(avd.directory.appendingPathComponent(Self.instanceLockName)), isLiveEmulator(pid) else { return nil }
        return pid
    }
}
