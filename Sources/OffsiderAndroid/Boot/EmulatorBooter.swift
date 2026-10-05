import Foundation
import OffsiderCore

public struct EmulatorBootRequest: Sendable {
    public let avdName: String
    public let headless: Bool
    public let timeout: Duration

    public init(avdName: String, headless: Bool, timeout: Duration) {
        self.avdName = avdName
        self.headless = headless
        self.timeout = timeout
    }
}

public struct EmulatorBootResult: Equatable, Sendable {
    public let serial: String
    public let alreadyRunning: Bool
    public let hasGRPC: Bool
    /// Nil when Offsider did not start the emulator.
    public let logPath: String?
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
        ["-avd", avdName, "-no-metrics"] + (headless ? ["-no-window"] : [])
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
        if let existing = running.first {
            if request.headless { progress("--headless ignored: \(name) is already running.") }
            let emulator = try await AndroidDeviceDirectory(client: client, host: host).runningEmulator(serial: existing.serial)
            if let emulator, emulator.state == .device, emulator.bootCompleted {
                let hasGRPC = wait.discovery(for: existing.serial)?.grpcPort != nil
                progress("\(name) is already running as \(existing.serial)" + (hasGRPC ? "." : " without gRPC; commands will use adb."))
                return EmulatorBootResult(serial: existing.serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil)
            }
            progress("\(name) is already starting as \(existing.serial).")
            let hasGRPC = try await wait.untilBooted(existing.serial, logPath: nil, progress: progress)
            return EmulatorBootResult(serial: existing.serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil)
        }

        let knownFiles = Set(EmulatorDiscovery.live(host: host).map(\.path))
        let knownSerials = Set(try await client.devices().map(\.serial))
        if let holder = instanceLockHolder(avd) {
            if request.headless { progress("--headless ignored: \(name) is already starting.") }
            progress("\(name) is already starting (pid \(holder)); waiting for it.")
            let serial = try await wait.serial(pid: holder, knownFiles: knownFiles, knownSerials: knownSerials, launched: nil, logPath: nil)
            let hasGRPC = try await wait.untilBooted(serial, logPath: nil, progress: progress)
            return EmulatorBootResult(serial: serial, alreadyRunning: true, hasGRPC: hasGRPC, logPath: nil)
        }

        guard host.files.isExecutableFile(atPath: sdk.emulator.path) else {
            throw AndroidError.emulatorMissing(sdkRoot: sdk.root.path)
        }
        let logPath = Self.logPath(avdName: name, host: host)
        var environment = host.environment
        environment["ADB_MDNS"] = "0"
        let pid: Int32
        do {
            pid = try host.launcher.launch(
                executable: sdk.emulator,
                arguments: Self.launchArguments(avdName: name, headless: request.headless),
                environment: environment,
                logPath: logPath
            )
        } catch let failure as DetachedProcessError {
            throw AndroidError.emulatorLaunchFailed(path: failure.path, detail: failure.detail)
        }
        log(.debug, "Started \(sdk.emulator.path) as pid \(pid); its output goes to \(logPath)")
        progress("Starting \(name)...")
        let serial = try await wait.serial(pid: pid, knownFiles: knownFiles, knownSerials: knownSerials, launched: pid, logPath: logPath)
        let hasGRPC = try await wait.untilBooted(serial, logPath: logPath, progress: progress)
        return EmulatorBootResult(serial: serial, alreadyRunning: false, hasGRPC: hasGRPC, logPath: logPath)
    }

    /// The emulator's own instance lock (`hardware-qemu.ini.lock` holds its pid), when a live emulator holds it.
    func instanceLockHolder(_ avd: AVDInfo) -> Int32? {
        let lock = avd.directory.appendingPathComponent("hardware-qemu.ini.lock")
        let data = host.files.contents(atPath: lock.path) ?? host.files.contents(atPath: lock.appendingPathComponent("pid").path)
        guard let data,
              let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              host.isProcessAlive(pid),
              let executable = host.processPath(pid),
              EmulatorDiscovery.isEmulatorExecutable(executable) else {
            return nil
        }
        return pid
    }
}
