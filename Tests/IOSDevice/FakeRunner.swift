import Darwin
import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice

/// One request the fake runner saw.
struct RunnerCall: Equatable, @unchecked Sendable {
    let method: String
    let path: String
    let token: String?
    let body: [String: AnyHashable]
}

/// The runner's routes in process: ping answers with `buildKey`, snapshot with `snapshot`, everything else `{ok: true}`.
final class FakeRunnerTransport: RunnerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RunnerCall] = []
    var buildKey: String
    var snapshot: Data
    var failure: (path: String, status: Int, code: String)?
    var refuseConnections = false
    var pingTimesOut = false

    init(buildKey: String = "key", snapshot: Data = Data("[]".utf8)) {
        self.buildKey = buildKey
        self.snapshot = snapshot
    }

    var calls: [RunnerCall] { lock.withLock { recorded } }

    func exchange(method: String, path: String, token: String, body: Data?, timeout: TimeInterval) throws -> UsbmuxHTTPResponse {
        if refuseConnections { throw UsbmuxError.result(3) }
        if pingTimesOut, path == "/ping" { throw UsbmuxError.timedOut }
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: AnyHashable] } ?? [:]
        lock.withLock { recorded.append(RunnerCall(method: method, path: path, token: token, body: object)) }
        if let failure, failure.path == path {
            return Self.response(failure.status, ["ok": false, "error": ["code": failure.code, "message": "scripted"]])
        }
        switch path {
        case "/ping":
            return Self.response(200, ["ok": true, "data": ["version": RunnerClient.protocolVersion, "buildKey": buildKey, "screenBounds": ["width": 430, "height": 932], "scale": 3, "orientation": "portrait"]])
        case "/snapshot":
            let data = (try? JSONSerialization.jsonObject(with: snapshot)) ?? []
            return Self.response(200, ["ok": true, "data": data])
        default:
            return Self.response(200, ["ok": true, "data": [String: Any]()])
        }
    }

    func error(for failure: UsbmuxError, udid: String) -> IOSDeviceError {
        .runner(failure, udid: udid)
    }

    static func response(_ status: Int, _ object: [String: Any]) -> UsbmuxHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return UsbmuxHTTPResponse(status: status, headers: ["content-length": String(body.count)], body: body)
    }
}

/// A runner stand-in on 127.0.0.1 that checks `X-Offsider-Token` the way the real one does.
final class FakeRunnerHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let token: String
    private let reply: @Sendable (String) -> (Int, Data)

    init(token: String, reply: @escaping @Sendable (String) -> (Int, Data)) throws {
        self.token = token
        self.reply = reply
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw UsbmuxError.socketUnavailable("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in serve() }.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while received.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = read(connection, &buffer, buffer.count)
                if count <= 0 { break }
                received.append(contentsOf: buffer.prefix(count))
            }
            let head = String(decoding: received, as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let authorised = head.lowercased().contains("x-offsider-token: \(token)\r\n")
            let (status, body) = authorised ? reply(path) : (401, Data(#"{"ok":false,"error":{"code":"unauthorised","message":"token"}}"#.utf8))
            let response = Data("HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            _ = response.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }
    }
}

/// Scripted builds: always the same key and xctestrun, counted.
final class FakeRunnerBuilder: RunnerBuilding, @unchecked Sendable {
    let key: String
    private let lock = NSLock()
    private var count = 0

    init(key: String = "key") {
        self.key = key
    }

    var builds: Int { lock.withLock { count } }

    func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        lock.withLock { count += 1 }
        return RunnerBuild(key: key, xctestrun: URL(fileURLWithPath: "/cache/\(key)/Runner.xctestrun"), directory: URL(fileURLWithPath: "/cache/\(key)"))
    }
}

/// Launches nothing; pids in `alive` are running as `xcodebuild` started at `startTime`, unless `startTimes` names another start.
/// A launch writes `launchLog` as xcodebuild's output, and with `exitsOnLaunch` its pid is gone at once.
final class FakeRunnerProcesses: RunnerProcessControlling, @unchecked Sendable {
    static let startTime: UInt64 = 1_800_000_000_000_000
    static let identity = RunnerProcessIdentity(startTime: startTime, executable: "xcodebuild")

    struct Launch {
        let arguments: [String]
        let environment: [String: String]
        let logPath: String
    }

    private let lock = NSLock()
    private var liveSet: Set<Int32>
    private var launched: [Launch] = []
    private var terminated: [Int32] = []
    private let startTimes: [Int32: UInt64]
    private let nextPID: Int32
    private let launchLog: Data?
    private let exitsOnLaunch: Bool

    init(alive: Set<Int32> = [], startTimes: [Int32: UInt64] = [:], nextPID: Int32 = 5151, launchLog: Data? = nil, exitsOnLaunch: Bool = false) {
        liveSet = alive
        self.startTimes = startTimes
        self.nextPID = nextPID
        self.launchLog = launchLog
        self.exitsOnLaunch = exitsOnLaunch
    }

    var launches: [Launch] { lock.withLock { launched } }
    var terminations: [Int32] { lock.withLock { terminated } }

    func launch(arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        if let launchLog { FileManager.default.createFile(atPath: logPath, contents: launchLog, attributes: [.posixPermissions: 0o600]) }
        lock.withLock {
            launched.append(Launch(arguments: arguments, environment: environment, logPath: logPath))
            if !exitsOnLaunch { liveSet.insert(nextPID) }
        }
        return nextPID
    }

    func identity(of pid: Int32) -> RunnerProcessIdentity? {
        lock.withLock {
            liveSet.contains(pid) ? RunnerProcessIdentity(startTime: startTimes[pid] ?? Self.startTime, executable: "xcodebuild") : nil
        }
    }

    func exit(_ pid: Int32) {
        _ = lock.withLock { liveSet.remove(pid) }
    }

    func terminate(_ pid: Int32, identity: RunnerProcessIdentity) {
        lock.withLock {
            terminated.append(pid)
            liveSet.remove(pid)
        }
    }
}

/// Hands the backend one client over a fake transport.
@MainActor
final class FakeRunnerConnector: RunnerConnecting {
    let transport: FakeRunnerTransport
    private(set) var connections = 0

    init(transport: FakeRunnerTransport) {
        self.transport = transport
    }

    func connect(_ destination: RunnerDestination, deviceName: String) async throws -> RunnerClient {
        connections += 1
        return RunnerClient(udid: destination.udid, token: "test-token", transport: transport)
    }
}

enum RunnerTestPaths {
    static func temporaryRoot() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-\(UUID().uuidString)").path
    }
}

/// usbmuxd's device list as a test scripts it: each read takes the next list, then the last repeats.
final class FakeUsbmuxListing: UsbmuxListing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[UsbmuxDevice]]
    private var count = 0
    /// Runs after each read with the read's number, from 1.
    var onRead: (@Sendable (Int) -> Void)?

    init(_ rows: [UsbmuxDevice]) {
        script = [rows]
    }

    init(script: [[UsbmuxDevice]]) {
        self.script = script
    }

    /// The device on USB, as usbmuxd lists a wired one.
    static func onUSB(_ udid: String) -> FakeUsbmuxListing {
        FakeUsbmuxListing([UsbmuxDevice(deviceID: 3, udid: udid, connectionType: "USB")])
    }

    var reads: Int { lock.withLock { count } }

    func listDevices() throws -> [UsbmuxDevice] {
        let (rows, number, hook) = lock.withLock {
            count += 1
            let rows = script.count > 1 ? script.removeFirst() : script[0]
            return (rows, count, onRead)
        }
        hook?(number)
        return rows
    }
}
