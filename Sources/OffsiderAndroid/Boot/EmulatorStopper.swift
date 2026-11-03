import Foundation
import OffsiderCore

/// An emulator `offsider shutdown` may stop, pinned to the process that serves its console, as a serial can move to another AVD.
public struct EmulatorStopTarget: Equatable, Sendable {
    public let avd: String
    public let serial: String
    let pid: Int32
    let startedAt: Date?
}

public enum EmulatorStopLookup: Equatable, Sendable {
    case running(EmulatorStopTarget)
    /// An AVD that is not running, or a serial nothing answers on.
    case off(name: String)
    /// No AVD or emulator has this name; a simulator may.
    case unknown
}

/// `offsider shutdown` for an emulator. `adb emu kill` connects to the serial's console port on loopback and sends `~/.emulator_console_auth_token`
/// to whatever answers there, so the port is first matched to a live emulator's discovery file; nothing else is ever sent the token.
@MainActor
public struct EmulatorStopper {
    static let poll: Duration = .milliseconds(250)
    static let killTimeout: TimeInterval = 10
    /// How long a refused `emu kill` may take to show as the emulator going anyway.
    static let refusedGrace: Duration = .seconds(2)
    /// adb failing says nothing about the console, and an emulator that took the stop may save a snapshot first.
    static let unclearGrace: Duration = .seconds(30)
    /// adb drops a stopped emulator's row a moment after its process ends, and the next `devices` should not list it.
    static let rowGrace: Duration = .seconds(5)

    let host: AndroidHost
    let log: AndroidLog

    public init(host: AndroidHost, log: @escaping AndroidLog) {
        self.host = host
        self.log = log
    }

    /// What `raw` names, reading only the AVD folder, discovery files and an adb server that is already running, unless an emulator needs the server.
    public func find(_ raw: String) async throws -> EmulatorStopLookup {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(id) {
        case .androidSerial(let port): return try await find(serial: id, port: port)
        case .androidName(let name): return try await find(name: name)
        default: return .unknown
        }
    }

    private func find(serial: String, port: Int) async throws -> EmulatorStopLookup {
        let client = try client()
        let discovery = EmulatorDiscovery.live(host: host).first { $0.consolePort == port }
        let rows = try await rows(client, starting: discovery != nil)
        guard rows.contains(where: { $0.serial == serial }) || discovery != nil else { return .off(name: serial) }
        return .running(try await target(serial: serial, discovery: discovery, rows: rows, client: client))
    }

    private func find(name: String) async throws -> EmulatorStopLookup {
        let client = try client()
        let live = EmulatorDiscovery.live(host: host).filter { $0.avdID == name && $0.consolePort != nil }
        let rows = try await rows(client, starting: !live.isEmpty)
        if rows.contains(where: { $0.serial == name && $0.consolePort == nil }) {
            if let emulator = live.first?.consolePort { throw AndroidError.ambiguousDeviceName(name, emulatorSerial: "emulator-\(emulator)") }
            throw AndroidError.shutdownPhone(name)
        }
        if live.count > 1 { throw AndroidError.avdRunningTwice(name, serials: live.compactMap(\.consolePort).map { "emulator-\($0)" }) }
        if let discovery = live.first, let port = discovery.consolePort {
            return .running(try await target(serial: "emulator-\(port)", discovery: discovery, rows: rows, client: client))
        }
        // An emulator with no discovery file can only be matched by asking the device, and its console cannot be trusted with the token.
        if !rows.isEmpty, let row = try await AndroidDeviceDirectory(client: client, host: host).runningEmulators(detailed: false).first(where: { $0.avdName == name }) {
            throw AndroidError.emulatorUnconfirmed(row.serial)
        }
        guard let avd = AVDCatalog(host: host).info(named: name) else { return .unknown }
        if let holder = EmulatorBooter(host: host, log: log).instanceLockHolder(avd) { throw AndroidError.emulatorStillStarting(name, pid: holder) }
        return .off(name: name)
    }

    /// Checks the serial is no phone reporting an emulator's serial, and that the discovery file and the device itself name one AVD.
    private func target(serial: String, discovery: EmulatorDiscovery?, rows: [AdbDeviceEntry], client: AdbClient) async throws -> EmulatorStopTarget {
        let row = rows.first { $0.serial == serial }
        if row?.properties["usb"] != nil { throw AndroidError.shutdownPhone(serial) }
        guard let discovery, let avd = discovery.avdID, !avd.isEmpty else { throw AndroidError.emulatorUnconfirmed(serial) }
        if row?.state == .device, let reported = await reportedAVD(serial: serial, client: client), reported != avd {
            throw AndroidError.emulatorNamesDiffer(serial, file: avd, device: reported)
        }
        return EmulatorStopTarget(avd: avd, serial: serial, pid: discovery.pid, startedAt: host.processStartTime(discovery.pid))
    }

    /// The AVD the device says it is; nil when it does not say.
    private func reportedAVD(serial: String, client: AdbClient) async -> String? {
        guard let result = try? await client.shell(AndroidDeviceDirectory.avdNameScript, on: serial, timeout: .seconds(5), label: "getprop") else { return nil }
        return result.stdoutText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Stops `target` and returns once its process has ended; `false` when it had already gone.
    @discardableResult
    public func stop(_ target: EmulatorStopTarget, timeout: Duration) async throws -> Bool {
        let deadline = host.uptime() + timeout
        guard isServing(target) else { return false }
        let client = try client()
        // Session stop can take seconds, in which a serial could change hands.
        guard EmulatorDiscovery.live(host: host).contains(where: { $0.pid == target.pid && $0.avdID == target.avd && "emulator-\($0.consolePort ?? 0)" == target.serial }) else {
            // An emulator ending by itself removes its file a moment before its process goes.
            try await host.sleep(Self.poll)
            guard isServing(target) else { return false }
            throw AndroidError.emulatorUnconfirmed(target.serial)
        }
        let rows = try await rows(client, starting: true)
        if rows.first(where: { $0.serial == target.serial })?.properties["usb"] != nil { throw AndroidError.shutdownPhone(target.serial) }
        if let refusal = await sendKill(target) {
            let graceEnd = min(deadline, host.uptime() + (refusal.hasPrefix("KO") ? Self.refusedGrace : Self.unclearGrace))
            while isServing(target), host.uptime() < graceEnd { try await host.sleep(Self.poll) }
            if isServing(target) { throw AndroidError.emulatorStopRefused(target.avd, detail: refusal) }
        }
        while isServing(target) {
            guard host.uptime() < deadline else { throw AndroidError.emulatorStopTimedOut(target.avd, pid: target.pid, seconds: timeout.components.seconds) }
            try await host.sleep(Self.poll)
        }
        let rowDeadline = min(deadline, host.uptime() + Self.rowGrace)
        while host.uptime() < rowDeadline, (try? await client.devices())?.contains(where: { $0.serial == target.serial }) == true {
            try await host.sleep(Self.poll)
        }
        return true
    }

    /// The refusal in words, or nil once adb reports the console took the command. Only a `KO` line is kept, so nothing else the console printed is echoed.
    private func sendKill(_ target: EmulatorStopTarget) async -> String? {
        do {
            let adb = try AndroidSDK.locate(host: host).adb
            let environment = ChildEnvironment.make(.adbServer, from: host.environment)
            let result = try await host.processes.capture(
                executable: adb.path, arguments: Self.killArguments(serial: target.serial), environment: environment, timeout: Self.killTimeout
            )
            let lines = (result.stdout + result.stderr).split(whereSeparator: \.isNewline)
            if let refused = lines.first(where: { $0.hasPrefix("KO") }) { return String(refused) }
            return result.status == 0 ? nil : "adb exited \(result.status)"
        } catch {
            log(.debug, "adb emu kill failed: \(error)")
            return "adb did not finish"
        }
    }

    static func killArguments(serial: String) -> [String] {
        ["-s", serial, "emu", "kill"]
    }

    /// The same process, so a reused pid never reads as the emulator still going.
    private func isServing(_ target: EmulatorStopTarget) -> Bool {
        guard host.isProcessAlive(target.pid), host.processPath(target.pid).map(EmulatorDiscovery.isEmulatorExecutable) == true else { return false }
        guard let startedAt = target.startedAt, let now = host.processStartTime(target.pid) else { return true }
        return now == startedAt
    }

    private func client() throws -> AdbClient {
        let sdk = try AndroidSDK.locate(host: host)
        return AdbClient(endpoint: try LoopbackEndpoint.adbServer(environment: host.environment), connector: host.adbConnector, timing: host.timing, adb: sdk.adb.path)
    }

    /// The device list; empty when no server runs, and with `starting` the server is started first, so a mistyped name never starts adb.
    private func rows(_ client: AdbClient, starting: Bool) async throws -> [AdbDeviceEntry] {
        if starting { try await AdbServerLauncher(adb: try AndroidSDK.locate(host: host).adb).ensureRunning(client: client, host: host) }
        do {
            return try await client.devices()
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {
            return []
        }
    }
}
