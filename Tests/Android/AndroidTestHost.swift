import Foundation
import OffsiderCore
@testable import OffsiderAndroid

final class RecordingProcessRunner: HostProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> ProcessCaptureResult

    init(respond: @escaping @Sendable (Call) -> ProcessCaptureResult = { _ in ProcessCaptureResult(status: 0, stdout: "", stderr: "") }) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    func capture(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessCaptureResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        lock.withLock { recorded.append(call) }
        return respond(call)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var sleeps: [Duration] { lock.withLock { recorded } }

    func sleep(_ duration: Duration) {
        lock.withLock { recorded.append(duration) }
    }
}

/// Hermetic hosts: a temporary home, a scripted adb server, recorded processes and no real waiting.
enum AndroidTestHost {
    static func make(
        home: URL? = nil,
        environment: [String: String] = [:],
        adb: FakeAdbServer = FakeAdbServer { _ in .hang },
        emulator: FakeEmulatorConnector = .refusing,
        processes: RecordingProcessRunner = RecordingProcessRunner(),
        files: (any FileSystemProbe)? = nil,
        liveProcesses: Set<Int32> = [],
        processPaths: [Int32: String] = [:],
        sleeps: SleepRecorder = SleepRecorder()
    ) -> AndroidHost {
        let homeDirectory = home ?? URL(fileURLWithPath: "/nonexistent/offsider-test-home", isDirectory: true)
        return AndroidHost(
            environment: environment.merging(["HOME": homeDirectory.path]) { current, _ in current },
            homeDirectory: homeDirectory,
            files: files ?? LocalFileSystem(),
            adbConnector: adb,
            emulatorConnector: emulator,
            processes: processes,
            isProcessAlive: { liveProcesses.contains($0) },
            processPath: { pid in processPaths[pid] ?? (liveProcesses.contains(pid) ? emulatorExecutable : nil) },
            sleep: { sleeps.sleep($0) }
        )
    }

    static let emulatorExecutable = "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"

    /// A temporary home with an SDK in the Android Studio location, so `prepare()` finds adb without any variable.
    static func homeWithSDK() throws -> URL {
        let home = try temporaryHome()
        try makeExecutable("Library/Android/sdk/platform-tools/adb", in: home)
        return home
    }

    static func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-android-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func makeExecutable(_ path: String, in root: URL) throws {
        try write("#!/bin/sh\nexit 0\n", to: path, in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
    }
}
