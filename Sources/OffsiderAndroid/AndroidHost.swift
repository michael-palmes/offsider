import Darwin
import Foundation
import OffsiderCore

public enum AndroidLogLevel: Sendable {
    case debug
    case info
    case warning
}

public typealias AndroidLog = @Sendable (_ level: AndroidLogLevel, _ message: String) -> Void

/// The file reads Android discovery needs; a protocol so tests can make a file vanish mid-scan.
protocol FileSystemProbe: Sendable {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func contents(atPath path: String) -> Data?
    /// Entry names, or an empty list when the directory is missing or unreadable.
    func contentsOfDirectory(atPath path: String) -> [String]
    func resolvingSymlinks(inPath path: String) -> String
}

protocol HostProcessRunning: Sendable {
    func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessCaptureResult
}

struct LocalFileSystem: FileSystemProbe {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func contents(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    func resolvingSymlinks(inPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

struct LocalProcessRunner: HostProcessRunning {
    func capture(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessCaptureResult {
        try await ProcessCapture.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}

/// Everything Android code reads from the Mac, injected so unit tests never reach the real SDK or adb.
public struct AndroidHost: Sendable {
    public var environment: [String: String]
    public var homeDirectory: URL
    var files: any FileSystemProbe
    var adbConnector: any AdbConnecting
    var emulatorConnector: any EmulatorConnecting
    var processes: any HostProcessRunning
    var isProcessAlive: @Sendable (Int32) -> Bool
    /// The executable of a running process, or nil when it has gone or cannot be read.
    var processPath: @Sendable (Int32) -> String?
    var sleep: @Sendable (Duration) async throws -> Void
    var launcher: any EmulatorLaunching
    /// Monotonic time for deadlines; tests advance it with their recorded sleeps.
    var uptime: @Sendable () -> Duration

    init(
        environment: [String: String],
        homeDirectory: URL,
        files: any FileSystemProbe = LocalFileSystem(),
        adbConnector: any AdbConnecting = PosixAdbConnector(),
        emulatorConnector: any EmulatorConnecting = GrpcEmulatorConnector(),
        processes: any HostProcessRunning = LocalProcessRunner(),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { AndroidHost.processIsAlive($0) },
        processPath: @escaping @Sendable (Int32) -> String? = { AndroidHost.executablePath(of: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        launcher: any EmulatorLaunching = DetachedProcess(),
        uptime: @escaping @Sendable () -> Duration = { .seconds(ProcessInfo.processInfo.systemUptime) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.files = files
        self.adbConnector = adbConnector
        self.emulatorConnector = emulatorConnector
        self.processes = processes
        self.isProcessAlive = isProcessAlive
        self.processPath = processPath
        self.sleep = sleep
        self.launcher = launcher
        self.uptime = uptime
    }

    /// `HOME` wins over the account's home folder, so a test run with an empty `HOME` sees no SDK or AVDs.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> AndroidHost {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return AndroidHost(environment: environment, homeDirectory: home)
    }

    /// `EPERM` means the process exists but belongs to another user, so it counts as alive.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A set, non-empty variable; an empty value counts as unset.
    func variable(_ name: String) -> String? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value
    }
}
