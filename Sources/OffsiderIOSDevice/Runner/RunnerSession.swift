import Darwin
import Foundation
import OffsiderCore

/// Which process a session's pid named when it was recorded, so a recycled pid is never mistaken for the runner.
public struct RunnerProcessIdentity: Codable, Equatable, Sendable {
    /// Microseconds since 1970, from the kernel's process start time.
    public var startTime: UInt64
    public var executable: String

    public init(startTime: UInt64, executable: String) {
        self.startTime = startTime
        self.executable = executable
    }

    /// The live process's identity, or nil once it has exited or is a zombie.
    public static func of(pid: Int32) -> RunnerProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let start = info.kp_proc.p_starttime
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return RunnerProcessIdentity(startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec), executable: name)
    }

    /// The same start time and executable; `xcrun` execs `xcodebuild` in place, so that change still matches.
    public func matches(_ current: RunnerProcessIdentity) -> Bool {
        startTime == current.startTime && (executable == current.executable || (executable == "xcrun" && current.executable == "xcodebuild"))
    }
}

/// `runner.json`: the detached `xcodebuild test-without-building` serving one device, and how to reach it.
public struct RunnerSessionRecord: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable {
        case usbmux
        case loopback
    }

    /// `starting` is written as soon as xcodebuild is spawned, so an interrupted start can still be found and stopped.
    public enum State: String, Codable, Sendable {
        case starting
        case running
    }

    public var udid: String
    public var pid: Int32
    public var port: UInt16
    public var token: String
    public var startedAt: Date
    public var lastUsed: Date
    public var buildKey: String
    public var version: String
    public var transport: Transport
    /// Nil in a record that predates it, which is then never signalled.
    public var process: RunnerProcessIdentity?
    public var state: State

    public init(
        udid: String, pid: Int32, port: UInt16, token: String, startedAt: Date, lastUsed: Date, buildKey: String, version: String, transport: Transport,
        process: RunnerProcessIdentity?, state: State = .running
    ) {
        self.udid = udid
        self.pid = pid
        self.port = port
        self.token = token
        self.startedAt = startedAt
        self.lastUsed = lastUsed
        self.buildKey = buildKey
        self.version = version
        self.transport = transport
        self.process = process
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        pid = try container.decode(Int32.self, forKey: .pid)
        port = try container.decode(UInt16.self, forKey: .port)
        token = try container.decode(String.self, forKey: .token)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        buildKey = try container.decode(String.self, forKey: .buildKey)
        version = try container.decode(String.self, forKey: .version)
        transport = try container.decode(Transport.self, forKey: .transport)
        process = try container.decodeIfPresent(RunnerProcessIdentity.self, forKey: .process)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .running
    }
}


/// Session files under `<private>/ios-devices/<udid>/`, written atomically 0600.
public struct RunnerSessionStore: Sendable {
    static let fileName = "runner.json"
    static let logName = "runner.log"
    static let lockName = "runner.lock"

    public let root: String

    public init(root: String) {
        self.root = root
    }

    public func read(udid: String) throws -> RunnerSessionRecord? {
        let directory = try IOSDevicePaths.device(udid, root: root)
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: directory, maxBytes: 64 * 1024) else { return nil }
        return try? Self.decoder.decode(RunnerSessionRecord.self, from: data)
    }

    public func write(_ record: RunnerSessionRecord) throws {
        let directory = try IOSDevicePaths.device(record.udid, root: root)
        try OffsiderPrivateDirectory.writeAtomically(try Self.encoder.encode(record), named: Self.fileName, in: directory)
    }

    public func remove(udid: String) {
        guard let directory = try? IOSDevicePaths.device(udid, root: root) else { return }
        OffsiderPrivateDirectory.removeFile(named: Self.fileName, in: directory)
    }

    /// Every device with a session file, without creating directories for others.
    public func all() -> [RunnerSessionRecord] {
        IOSDevicePaths.knownDevices(root: root).compactMap { try? read(udid: $0) }
    }

    public func logPath(udid: String) throws -> String {
        (try IOSDevicePaths.device(udid, root: root) as NSString).appendingPathComponent(Self.logName)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}


/// Processes the session starts and stops; tests replace it so nothing is spawned.
public protocol RunnerProcessControlling: Sendable {
    func launch(arguments: [String], environment: [String: String], logPath: String) throws -> Int32
    /// Nil once the process has exited.
    func identity(of pid: Int32) -> RunnerProcessIdentity?
    /// Signals `pid` only while it is still the process `identity` names.
    func terminate(_ pid: Int32, identity: RunnerProcessIdentity)
}

extension RunnerProcessControlling {
    /// True only while the recorded pid is still the process the record names.
    public func isRunning(_ record: RunnerSessionRecord) -> Bool {
        guard let expected = record.process, let current = identity(of: record.pid) else { return false }
        return expected.matches(current)
    }
}

/// `xcrun xcodebuild` in its own session through `DetachedProcess`.
public struct XcodebuildProcesses: RunnerProcessControlling {
    public init() {}

    public func launch(arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        try DetachedProcess().launch(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild"] + arguments, environment: environment, logPath: logPath)
    }

    /// A child that exited is reaped first, so a zombie never reads as alive.
    public func identity(of pid: Int32) -> RunnerProcessIdentity? {
        guard pid > 0, DetachedProcess().exitStatus(of: pid) == nil else { return nil }
        return RunnerProcessIdentity.of(pid: pid)
    }

    /// The whole process group when the runner leads it, so the test runner xcodebuild started goes too.
    public func terminate(_ pid: Int32, identity: RunnerProcessIdentity) {
        guard let current = self.identity(of: pid), identity.matches(current) else { return }
        if getpgid(pid) == pid {
            kill(-pid, SIGTERM)
        } else {
            kill(pid, SIGTERM)
        }
    }
}

/// Reuses a live session or starts one; every client it returns belongs to a runner of the expected build.
@MainActor
public final class RunnerSessionManager {
    public static let idleVariable = "OFFSIDER_IOS_RUNNER_IDLE"
    static let pollInterval: TimeInterval = 0.25
    /// How much of the log an exited xcodebuild left unread is still searched for the unlock prompt.
    static let exitedLogLimit = 1024 * 1024
    /// A snapshot can hold the runner's main thread for seconds, so a slow ping means busy, not gone.
    static let reuseTimeout: TimeInterval = 5

    let store: RunnerSessionStore
    let builder: any RunnerBuilding
    let processes: any RunnerProcessControlling
    let environment: [String: String]
    let developerDirectory: String?
    let transport: @Sendable (RunnerDestination, UInt16) -> any RunnerTransport
    let log: IOSDeviceLog
    let now: @Sendable () -> Date
    let startTimeout: TimeInterval
    let lockTimeout: TimeInterval
    /// The only way to a device's runner, so a device it stops listing fails the start instead of the timeout.
    let usbmux: any UsbmuxListing
    let usbmuxCheckInterval: TimeInterval
    /// How long a starting runner's device may be missing from usbmuxd, which can drop it briefly while xcodebuild installs and launches.
    let usbmuxGrace: TimeInterval

    public init(
        store: RunnerSessionStore,
        builder: any RunnerBuilding,
        processes: any RunnerProcessControlling = XcodebuildProcesses(),
        environment: [String: String],
        developerDirectory: String?,
        transport: @escaping @Sendable (RunnerDestination, UInt16) -> any RunnerTransport = RunnerSessionManager.defaultTransport,
        log: @escaping IOSDeviceLog,
        now: @escaping @Sendable () -> Date = { Date() },
        startTimeout: TimeInterval = 150,
        lockTimeout: TimeInterval = 180,
        usbmux: any UsbmuxListing = UsbmuxClient(),
        usbmuxCheckInterval: TimeInterval = 2,
        usbmuxGrace: TimeInterval = 10
    ) {
        self.store = store
        self.builder = builder
        self.processes = processes
        self.environment = environment
        self.developerDirectory = developerDirectory
        self.transport = transport
        self.log = log
        self.now = now
        self.startTimeout = startTimeout
        self.lockTimeout = lockTimeout
        self.usbmux = usbmux
        self.usbmuxCheckInterval = usbmuxCheckInterval
        self.usbmuxGrace = usbmuxGrace
    }

    public nonisolated static func defaultTransport(_ destination: RunnerDestination, _ port: UInt16) -> any RunnerTransport {
        switch destination {
        case .device(let udid): return UsbmuxRunnerTransport(udid: udid, port: port)
        case .simulator: return LoopbackRunnerTransport(port: port)
        }
    }

    var idleSeconds: Int {
        environment[Self.idleVariable].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 300
    }

    public func connect(_ destination: RunnerDestination, deviceName: String) async throws -> RunnerClient {
        let build = try await builder.build(for: destination, deviceName: deviceName)
        if let client = try await reuse(destination, deviceName: deviceName, build: build, holdingLock: false) { return client }
        let lock = try await acquireStartLock(udid: destination.udid)
        defer { lock.release() }
        if let client = try await reuse(destination, deviceName: deviceName, build: build, holdingLock: true) { return client }
        return try await start(destination, deviceName: deviceName, build: build)
    }

    /// The recorded session while it is still the recorded process and its socket accepts; one whose process is gone is forgotten, never signalled.
    func reuse(_ destination: RunnerDestination, deviceName: String, build: RunnerBuild, holdingLock: Bool) async throws -> RunnerClient? {
        guard var record = try store.read(udid: destination.udid) else { return nil }
        guard processes.isRunning(record) else {
            log(.debug, "Forgetting the Offsider runner session on \(destination.udid): its process has exited")
            store.remove(udid: destination.udid)
            return nil
        }
        // Without the lock, a starting session may belong to a command still waiting for it.
        if record.state == .starting, !holdingLock { return nil }
        if record.version == RunnerClient.protocolVersion, record.buildKey == build.key {
            switch await client(for: record).probe(timeout: Self.reuseTimeout) {
            case .answered(let ping) where ping.version == record.version && ping.buildKey == record.buildKey:
                return keep(&record)
            case .busy:
                log(.debug, "The Offsider runner on \(destination.udid) is busy; queueing behind it")
                return keep(&record)
            case .unreachable:
                // A restart could not reach the runner either; the session is kept for when usbmuxd lists the device again.
                if let failure = await usbmuxFailure(destination, deviceName: deviceName) { throw failure }
            case .answered:
                break
            }
        }
        log(.debug, "Restarting the Offsider runner on \(destination.udid): its session is stale")
        await stop(record)
        return nil
    }

    private func keep(_ record: inout RunnerSessionRecord) -> RunnerClient {
        record.lastUsed = now()
        record.state = .running
        if let current = processes.identity(of: record.pid) { record.process = current }
        try? store.write(record)
        return client(for: record)
    }

    func start(_ destination: RunnerDestination, deviceName: String, build: RunnerBuild) async throws -> RunnerClient {
        let udid = destination.udid
        if let failure = await usbmuxFailure(destination, deviceName: deviceName) { throw failure }
        let directory = try IOSDevicePaths.device(udid, root: store.root)
        Self.removeResultBundles(in: directory)
        let logPath = try store.logPath(udid: udid)
        unlink(logPath)
        let token = Self.makeToken()
        let port = UInt16.random(in: 20000...59999)
        var childEnvironment = environment
        if let developerDirectory { childEnvironment["DEVELOPER_DIR"] = developerDirectory }
        childEnvironment["TEST_RUNNER_OFFSIDER_RUNNER_PORT"] = String(port)
        childEnvironment["TEST_RUNNER_OFFSIDER_RUNNER_TOKEN"] = token
        childEnvironment["TEST_RUNNER_OFFSIDER_RUNNER_IDLE_SECONDS"] = String(idleSeconds)
        childEnvironment["TEST_RUNNER_OFFSIDER_RUNNER_BUILD_KEY"] = build.key
        let arguments = [
            "test-without-building",
            "-xctestrun", build.xctestrun.path,
            "-destination", "id=\(udid)",
            "-resultBundlePath", (directory as NSString).appendingPathComponent("result-\(UUID().uuidString).xcresult"),
        ]
        let pid: Int32
        do {
            pid = try processes.launch(arguments: arguments, environment: childEnvironment, logPath: logPath)
        } catch {
            throw IOSDeviceError(.runnerUnavailable, "Offsider could not start xcodebuild for the runner on \(udid): \(error.localizedDescription). Run `offsider doctor --device \(udid)`.")
        }
        let started = now()
        var record = RunnerSessionRecord(
            udid: udid, pid: pid, port: port, token: token, startedAt: started, lastUsed: started,
            buildKey: build.key, version: RunnerClient.protocolVersion, transport: destination.isSimulator ? .loopback : .usbmux,
            process: processes.identity(of: pid), state: .starting
        )
        if record.process != nil { try store.write(record) }
        let client = RunnerClient(udid: udid, token: token, transport: transport(destination, port))
        let deadline = Date().addingTimeInterval(startTimeout)
        var nextUsbmuxCheck = now().addingTimeInterval(usbmuxCheckInterval)
        var missingSince: Date?
        var watch = RunnerLogWatch(path: logPath)
        while Date() < deadline {
            guard processes.isRunning(record) else { break }
            if let ping = try? await client.ping(timeout: 1), ping.buildKey == build.key {
                _ = keep(&record)
                return client
            }
            if let finding = watch.check() {
                abandon(record)
                throw Self.error(for: finding, deviceName: deviceName)
            }
            if now() >= nextUsbmuxCheck {
                nextUsbmuxCheck = now().addingTimeInterval(usbmuxCheckInterval)
                if let failure = await usbmuxFailure(destination, deviceName: deviceName) {
                    if missingSince == nil {
                        missingSince = now()
                        log(.debug, "usbmuxd does not list \(udid) on USB; waiting up to \(Int(usbmuxGrace)) s for it to return")
                    }
                    if let since = missingSince, now().timeIntervalSince(since) >= usbmuxGrace {
                        abandon(record)
                        throw failure
                    }
                } else {
                    missingSince = nil
                }
            }
            try await Task.sleep(for: .seconds(Self.pollInterval))
        }
        let exited = !processes.isRunning(record)
        abandon(record)
        if exited, let finding = watch.check(maxBytes: Self.exitedLogLimit) { throw Self.error(for: finding, deviceName: deviceName) }
        let outcome = exited
            ? "xcodebuild exited before the Offsider runner on \(udid) answered."
            : "The Offsider runner on \(udid) did not start within \(Int(startTimeout)) seconds."
        throw IOSDeviceError(
            .runnerUnavailable,
            "\(outcome) Unlock the device, check Settings > Developer > Enable UI Automation, then retry.\(Self.logTail(logPath))",
            hint: "See \(logPath)"
        )
    }

    /// Ends a start that never answered, signalling xcodebuild only while it is still the recorded process.
    private func abandon(_ record: RunnerSessionRecord) {
        if let identity = record.process { processes.terminate(record.pid, identity: identity) }
        store.remove(udid: record.udid)
    }

    /// Nil while usbmuxd lists a device on USB, or for a simulator; otherwise the error to report.
    func usbmuxFailure(_ destination: RunnerDestination, deviceName: String) async -> IOSDeviceError? {
        guard case .device(let udid) = destination else { return nil }
        let usbmux = usbmux
        do {
            return try await Task.detached { try usbmux.listsOnUSB(udid) }.value ? nil : .notOnUsbmux(deviceName)
        } catch let error as UsbmuxError {
            return .usbmux(error, udid: udid)
        } catch {
            return .usbmux(.malformed(error.localizedDescription), udid: udid)
        }
    }

    /// Asks the runner to stop, waits up to 2 seconds, signals it only while it is still the recorded process, then removes the session file.
    public func stop(_ record: RunnerSessionRecord) async {
        if processes.isRunning(record), let identity = record.process {
            try? await client(for: record).stop()
            let deadline = Date().addingTimeInterval(2)
            while processes.isRunning(record), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if processes.isRunning(record) { processes.terminate(record.pid, identity: identity) }
        }
        store.remove(udid: record.udid)
    }

    func client(for record: RunnerSessionRecord) -> RunnerClient {
        let destination: RunnerDestination = record.transport == .loopback ? .simulator(udid: record.udid) : .device(udid: record.udid)
        return RunnerClient(udid: record.udid, token: record.token, transport: transport(destination, record.port))
    }

    /// `runner.lock`, waited for while another command starts this device's runner.
    func acquireStartLock(udid: String) async throws -> IOSDeviceStartLock {
        let path = (try IOSDevicePaths.device(udid, root: store.root) as NSString).appendingPathComponent(RunnerSessionStore.lockName)
        return try await IOSDeviceStartLock.acquire(path, timeout: lockTimeout, poll: .seconds(Self.pollInterval)) {
            IOSDeviceError(.runnerUnavailable, "Another Offsider command is still starting the runner on \(udid). Retry in a minute.")
        }
    }

    nonisolated static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    nonisolated static func removeResultBundles(in directory: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix("result-") && name.hasSuffix(".xcresult") {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }

    static func error(for finding: RunnerLogWatch.Finding, deviceName: String) -> IOSDeviceError {
        switch finding {
        case .deviceLocked: return .runnerLocked(deviceName)
        case .automationNotEnabled: return .runnerAutomationBlocked(deviceName)
        }
    }

    nonisolated static func logTail(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n").suffix(10).joined(separator: "\n")
        return tail.isEmpty ? "" : "\n\(tail)"
    }
}

extension RunnerDestination {
    var isSimulator: Bool {
        if case .simulator = self { return true }
        return false
    }
}
