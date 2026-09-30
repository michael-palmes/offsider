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
    var processes: any HostProcessRunning
    var isProcessAlive: @Sendable (Int32) -> Bool
    var sleep: @Sendable (Duration) async throws -> Void

    init(
        environment: [String: String],
        homeDirectory: URL,
        files: any FileSystemProbe = LocalFileSystem(),
        adbConnector: any AdbConnecting = PosixAdbConnector(),
        processes: any HostProcessRunning = LocalProcessRunner(),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { AndroidHost.processIsAlive($0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.files = files
        self.adbConnector = adbConnector
        self.processes = processes
        self.isProcessAlive = isProcessAlive
        self.sleep = sleep
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

    /// A set, non-empty variable; an empty value counts as unset.
    func variable(_ name: String) -> String? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value
    }
}
