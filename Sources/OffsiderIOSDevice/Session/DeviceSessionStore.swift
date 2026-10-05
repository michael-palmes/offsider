import Darwin
import Foundation
import OffsiderCore

/// `session.json`: the detached broker serving one device, and the socket it listens on.
public struct DeviceSessionRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case starting
        case running
    }

    public var udid: String
    public var pid: Int32
    /// Nil only when the process had exited before it could be read; such a record is never signalled.
    public var process: RunnerProcessIdentity?
    public var socket: String
    public var startedAt: Date
    public var version: Int
    public var state: State

    public init(udid: String, pid: Int32, process: RunnerProcessIdentity?, socket: String, startedAt: Date, version: Int, state: State) {
        self.udid = udid
        self.pid = pid
        self.process = process
        self.socket = socket
        self.startedAt = startedAt
        self.version = version
        self.state = state
    }
}

/// The broker's `session.json`, `session.log` and `session.lock` under `<private>/ios-devices/<udid>/`, and its socket under the shorter `<private>/sessions/`.
public struct DeviceSessionStore: Sendable {
    static let fileName = "session.json"
    static let logName = "session.log"
    static let lockName = "session.lock"
    static let socketDirectoryName = "sessions"

    public let root: String

    public init(root: String) {
        self.root = root
    }

    public func read(udid: String) throws -> DeviceSessionRecord? {
        let directory = try IOSDevicePaths.device(udid, root: root)
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: directory, maxBytes: 64 * 1024) else { return nil }
        return try? RunnerSessionStore.decoder.decode(DeviceSessionRecord.self, from: data)
    }

    public func write(_ record: DeviceSessionRecord) throws {
        let directory = try IOSDevicePaths.device(record.udid, root: root)
        try OffsiderPrivateDirectory.writeAtomically(try RunnerSessionStore.encoder.encode(record), named: Self.fileName, in: directory)
    }

    /// Removes the record only while it still names `pid`, when one is given.
    public func remove(udid: String, ifPID pid: Int32? = nil) {
        guard let directory = try? IOSDevicePaths.device(udid, root: root) else { return }
        if let pid, let record = try? read(udid: udid), record.pid != pid { return }
        OffsiderPrivateDirectory.removeFile(named: Self.fileName, in: directory)
    }

    /// Every device with a broker record, without creating directories for others.
    public func all() -> [DeviceSessionRecord] {
        IOSDevicePaths.knownDevices(root: root).compactMap { try? read(udid: $0) }
    }

    public func logPath(udid: String) throws -> String {
        (try IOSDevicePaths.device(udid, root: root) as NSString).appendingPathComponent(Self.logName)
    }

    func lockPath(udid: String) throws -> String {
        (try IOSDevicePaths.device(udid, root: root) as NSString).appendingPathComponent(Self.lockName)
    }

    /// `<private>/sessions/<hash>-v<protocol>.sock`; the protocol in the name keeps an older broker from answering.
    public func socketPath(udid: String) throws -> String {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(Self.socketDirectoryName, root: root)
        let name = String(BrokerEndpointNaming.fnv1a64(IOSDevicePaths.safeName(udid)), radix: 36)
        let path = (directory as NSString).appendingPathComponent("\(name)-v\(DeviceSessionWire.protocolVersion).sock")
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw IOSDeviceError(.sessionFailed, "The device session socket path \(path) is too long for a Unix socket.")
        }
        return path
    }
}

extension RunnerProcessControlling {
    /// True only while the recorded pid is still the broker the record names.
    public func isRunning(_ record: DeviceSessionRecord) -> Bool {
        guard let expected = record.process, let current = identity(of: record.pid) else { return false }
        return expected.matches(current)
    }
}

/// This `offsider` executable started detached, as `offsider device-session serve`.
public struct OffsiderSelfProcesses: RunnerProcessControlling {
    let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func launch(arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        try DetachedProcess().launch(executable: executable, arguments: arguments, environment: environment, logPath: logPath)
    }

    public func identity(of pid: Int32) -> RunnerProcessIdentity? {
        XcodebuildProcesses().identity(of: pid)
    }

    public func terminate(_ pid: Int32, identity: RunnerProcessIdentity) {
        guard let current = self.identity(of: pid), identity.matches(current) else { return }
        kill(pid, SIGTERM)
    }
}
