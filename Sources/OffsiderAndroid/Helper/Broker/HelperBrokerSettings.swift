import Foundation
import OffsiderCore

/// `OFFSIDER_ANDROID_SESSION` and `OFFSIDER_ANDROID_SESSION_IDLE`: whether the helper stays warm between commands, and for how long.
enum HelperBrokerSettings {
    enum Mode: String, Sendable {
        /// Emulators keep the helper warm; a USB phone starts one per command.
        case auto
        /// Emulators and allowed USB phones keep it warm.
        case on
        /// One helper per command everywhere.
        case off
    }

    static let modeVariable = "OFFSIDER_ANDROID_SESSION"
    static let idleVariable = "OFFSIDER_ANDROID_SESSION_IDLE"
    static let defaultIdleSeconds = 60
    static let maxIdleSeconds = 3600
    /// A broker stops at its next idle moment after this long, so the next command starts a fresh one.
    static let maxLifetime: Duration = .seconds(12 * 3600)
    /// The warm helper's own idle timeout: the broker pings it every 2 s, so it outlives a broker that stopped answering by this much at most.
    static let helperIdleTimeoutMs = 30_000

    /// Unset or empty is auto.
    static func mode(host: AndroidHost) throws -> Mode {
        guard let value = host.variable(modeVariable) else { return .auto }
        guard let mode = Mode(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: modeVariable, value: value, expected: "auto, on or off")
        }
        return mode
    }

    /// 60 when unset or not a positive whole number, at most 3600.
    static func idleSeconds(_ environment: [String: String]) -> Int {
        let seconds = environment[idleVariable].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
        return min(seconds ?? defaultIdleSeconds, maxIdleSeconds)
    }

    static func keepsWarm(_ mode: Mode, isEmulator: Bool) -> Bool {
        switch mode {
        case .auto: return isEmulator
        case .on: return true
        case .off: return false
        }
    }

    /// An `emulator-NNNN` serial; a phone's serial is anything else adb lists.
    static func isEmulatorSerial(_ serial: String) -> Bool {
        if case .androidSerial = DeviceIDClassifier.classify(serial) { return true }
        return false
    }
}

/// Where the broker for one serial listens and logs, under the private `sessions/` folder; base 36 keeps the socket inside the 104-byte `sun_path`.
struct HelperBrokerPaths: Equatable, Sendable {
    static let prefix = "android-"
    static let socketExtension = "sock"

    let socket: String
    let log: String

    init(serial: String, directory: String) {
        let name = Self.prefix + String(BrokerEndpointNaming.fnv1a64(serial), radix: 36)
        socket = (directory as NSString).appendingPathComponent("\(name).\(Self.socketExtension)")
        log = (directory as NSString).appendingPathComponent("\(name).log")
    }

    /// The serial a broker's log names in its `Serving <serial> on` line; nil when it has none.
    static func servedSerial(inLog path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        guard let range = head.range(of: #"Serving \S+ on "#, options: .regularExpression) else { return nil }
        return String(head[range].dropFirst("Serving ".count).dropLast(" on ".count))
    }

    /// Every Android broker socket in `directory`, whichever serial it serves.
    static func sockets(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".\(socketExtension)") }.sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }
}

/// What a command needs to reach or start a broker; the executable supplies it, tests and other hosts leave it nil and keep one helper per command.
public struct HelperBrokerHost: Sendable {
    /// The private `sessions/` folder, made 0700 on first use.
    public var directory: @Sendable () throws -> String
    /// Starts `offsider android-session serve --device <serial>` detached, appending its output to `logPath`; returns its pid.
    public var spawn: @Sendable (_ serial: String, _ logPath: String) throws -> Int32
    /// The spawned broker's exit status once it has exited, else nil.
    public var exitStatus: @Sendable (Int32) -> Int32?
    /// The private root whose `locks/` serialise broker starts.
    public var lockRoot: String

    /// How `offsider android-session serve` is started for `serial`, as its process lists its arguments; `spawn` and the lookup of a refusing broker share it.
    public static func serveArguments(_ serial: String) -> [String] {
        ["android-session", "serve", "--device", serial]
    }

    public init(
        directory: @escaping @Sendable () throws -> String,
        spawn: @escaping @Sendable (String, String) throws -> Int32,
        exitStatus: @escaping @Sendable (Int32) -> Int32?,
        lockRoot: String
    ) {
        self.directory = directory
        self.spawn = spawn
        self.exitStatus = exitStatus
        self.lockRoot = lockRoot
    }
}

extension AndroidHost {
    /// `serial`'s warm helper socket; nil when this host keeps no warm helper.
    func warmHelperSocket(for serial: String) -> String? {
        guard let directory = try? helperBroker?.directory() else { return nil }
        return HelperBrokerPaths(serial: serial, directory: directory).socket
    }

    /// Every warm helper socket, or `serial`'s alone.
    func warmHelperSockets(serial: String?) -> [String] {
        if let serial { return warmHelperSocket(for: serial).map { [$0] } ?? [] }
        guard let directory = try? helperBroker?.directory() else { return [] }
        return HelperBrokerPaths.sockets(in: directory)
    }
}
