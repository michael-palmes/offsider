import Darwin
import Foundation
import OffsiderCore

/// `runner.json`: the detached `xcodebuild test-without-building` serving one device, and how to reach it.
public struct RunnerSessionRecord: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable {
        case usbmux
        case loopback
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

    public init(udid: String, pid: Int32, port: UInt16, token: String, startedAt: Date, lastUsed: Date, buildKey: String, version: String, transport: Transport) {
        self.udid = udid
        self.pid = pid
        self.port = port
        self.token = token
        self.startedAt = startedAt
        self.lastUsed = lastUsed
        self.buildKey = buildKey
        self.version = version
        self.transport = transport
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
    func isAlive(_ pid: Int32) -> Bool
    func terminate(_ pid: Int32)
}

/// `xcrun xcodebuild` in its own session through `DetachedProcess`.
public struct XcodebuildProcesses: RunnerProcessControlling {
    public init() {}

    public func launch(arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        try DetachedProcess().launch(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild"] + arguments, environment: environment, logPath: logPath)
    }

    /// A child that exited is reaped first, so a zombie never reads as alive.
    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0, DetachedProcess().exitStatus(of: pid) == nil else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The whole process group, so the test runner xcodebuild started goes too.
    public func terminate(_ pid: Int32) {
        guard pid > 0 else { return }
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
    }
}

/// Reuses a live session or starts one; every client it returns has answered `/ping` with the expected build.
@MainActor
public final class RunnerSessionManager {
    public static let idleVariable = "OFFSIDER_IOS_RUNNER_IDLE"
    static let pollInterval: TimeInterval = 0.25
    static let reconnectTimeout: TimeInterval = 0.3
    static let lockStale: TimeInterval = 180

    let store: RunnerSessionStore
    let builder: any RunnerBuilding
    let processes: any RunnerProcessControlling
    let environment: [String: String]
    let developerDirectory: String?
    let transport: @Sendable (RunnerDestination, UInt16) -> any RunnerTransport
    let log: IOSDeviceLog
    let now: @Sendable () -> Date
    let startTimeout: TimeInterval

    public init(
        store: RunnerSessionStore,
        builder: any RunnerBuilding,
        processes: any RunnerProcessControlling = XcodebuildProcesses(),
        environment: [String: String],
        developerDirectory: String?,
        transport: @escaping @Sendable (RunnerDestination, UInt16) -> any RunnerTransport = RunnerSessionManager.defaultTransport,
        log: @escaping IOSDeviceLog,
        now: @escaping @Sendable () -> Date = { Date() },
        startTimeout: TimeInterval = 60
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
        if let client = try await reuse(destination, build: build) { return client }
        let lock = try await acquireStartLock(udid: destination.udid)
        defer { unlink(lock) }
        if let client = try await reuse(destination, build: build) { return client }
        return try await start(destination, build: build)
    }

    /// The recorded session when its process lives and `/ping` answers quickly with this build; a stale one is stopped.
    func reuse(_ destination: RunnerDestination, build: RunnerBuild) async throws -> RunnerClient? {
        guard var record = try store.read(udid: destination.udid) else { return nil }
        if record.version == RunnerClient.protocolVersion, record.buildKey == build.key, processes.isAlive(record.pid),
           let ping = try? await client(for: record).ping(timeout: Self.reconnectTimeout),
           ping.version == record.version, ping.buildKey == record.buildKey {
            record.lastUsed = now()
            try? store.write(record)
            return client(for: record)
        }
        log(.debug, "Restarting the Offsider runner on \(destination.udid): its session is stale")
        await stop(record)
        return nil
    }

    func start(_ destination: RunnerDestination, build: RunnerBuild) async throws -> RunnerClient {
        let udid = destination.udid
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
        let record = RunnerSessionRecord(
            udid: udid, pid: pid, port: port, token: token, startedAt: started, lastUsed: started,
            buildKey: build.key, version: RunnerClient.protocolVersion, transport: destination.isSimulator ? .loopback : .usbmux
        )
        let client = RunnerClient(udid: udid, token: token, transport: transport(destination, port))
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            guard processes.isAlive(pid) else { break }
            if let ping = try? await client.ping(timeout: 1), ping.buildKey == build.key {
                try store.write(record)
                return client
            }
            try await Task.sleep(for: .seconds(Self.pollInterval))
        }
        processes.terminate(pid)
        throw IOSDeviceError(
            .runnerUnavailable,
            "The Offsider runner on \(udid) did not start within \(Int(startTimeout)) seconds. Unlock the device, check Settings > Developer > Enable UI Automation, then retry.\(Self.logTail(logPath))",
            hint: "See \(logPath)"
        )
    }

    /// Asks the runner to stop, waits up to 2 seconds, then signals its process group and removes the session file.
    public func stop(_ record: RunnerSessionRecord) async {
        if processes.isAlive(record.pid) {
            try? await client(for: record).stop()
            let deadline = Date().addingTimeInterval(2)
            while processes.isAlive(record.pid), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if processes.isAlive(record.pid) { processes.terminate(record.pid) }
        }
        store.remove(udid: record.udid)
    }

    func client(for record: RunnerSessionRecord) -> RunnerClient {
        let destination: RunnerDestination = record.transport == .loopback ? .simulator(udid: record.udid) : .device(udid: record.udid)
        return RunnerClient(udid: record.udid, token: record.token, transport: transport(destination, record.port))
    }

    /// `runner.lock`, created with `O_EXCL`; another command's lock is waited for, and one older than three minutes is taken over.
    func acquireStartLock(udid: String) async throws -> String {
        let path = (try IOSDevicePaths.device(udid, root: store.root) as NSString).appendingPathComponent(RunnerSessionStore.lockName)
        let deadline = Date().addingTimeInterval(Self.lockStale)
        while true {
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if descriptor >= 0 {
                close(descriptor)
                return path
            }
            guard errno == EEXIST else {
                throw PrivateDirectoryError(.system(operation: "open", code: errno), path: path)
            }
            if let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > Self.lockStale {
                unlink(path)
                continue
            }
            guard Date() < deadline else {
                throw IOSDeviceError(.runnerUnavailable, "Another Offsider command is still starting the runner on \(udid). Retry in a minute.")
            }
            try await Task.sleep(for: .seconds(Self.pollInterval))
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
