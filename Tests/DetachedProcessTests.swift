import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Detached processes", .serialized)
struct DetachedProcessTests {
    static func folder() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-detached-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }

    /// Waits for `pid` to exit, up to 10 s.
    static func wait(_ pid: Int32) async throws {
        let process = DetachedProcess()
        for _ in 0..<200 {
            if process.exitStatus(of: pid) != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("pid \(pid) did not exit")
    }

    @Test("a symbolic link at the log path is refused before anything starts")
    func symlinkedLogRefused() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: folder + "/target"))
        try FileManager.default.createSymbolicLink(atPath: folder + "/run.log", withDestinationPath: folder + "/target")
        #expect(throws: DetachedProcessError.self) {
            _ = try DetachedProcess().launch(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], environment: [:], logPath: folder + "/run.log")
        }
        #expect(FileManager.default.contents(atPath: folder + "/target") == Data("keep".utf8))
    }

    @Test("a hard-linked or FIFO log is refused")
    func otherLogsRefused() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data().write(to: URL(fileURLWithPath: folder + "/a"))
        link(folder + "/a", folder + "/b.log")
        mkfifo(folder + "/fifo.log", 0o600)
        #expect(throws: DetachedProcessError.self) { _ = try DetachedProcess.openLog(folder + "/b.log") }
        #expect(throws: DetachedProcessError.self) { _ = try DetachedProcess.openLog(folder + "/fifo.log") }
    }

    @Test("a log over 5 MB is emptied before the child appends; the log is 0600")
    func largeLogTruncated() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let log = folder + "/run.log"
        try Data(repeating: 0x41, count: 6 << 20).write(to: URL(fileURLWithPath: log))
        chmod(log, 0o600)
        let pid = try DetachedProcess().launch(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["fresh"], environment: [:], logPath: log)
        try await Self.wait(pid)
        #expect(FileManager.default.contents(atPath: log) == Data("fresh\n".utf8))
        var info = stat()
        stat(log, &info)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("the child sees exactly the given environment and inherits only stdin, stdout and stderr")
    func environmentAndDescriptors() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let log = folder + "/run.log"
        // A descriptor without close-on-exec that a plain spawn would hand to the child.
        let opened = open(folder + "/leak", O_WRONLY | O_CREAT, 0o600)
        let leaked = fcntl(opened, F_DUPFD, 200)
        close(opened)
        defer { close(leaked) }
        #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)
        let pid = try DetachedProcess().launch(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "env; ls /dev/fd"], environment: ["ONLY": "this"], logPath: log
        )
        try await Self.wait(pid)
        let lines = String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.contains("ONLY=this"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") })
        let descriptors = Set(lines.filter { $0.allSatisfy(\.isNumber) })
        #expect(!descriptors.contains(String(leaked)))
        #expect(descriptors.isSuperset(of: ["0", "1", "2"]))
    }
}
