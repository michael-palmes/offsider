import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Each way Offsider starts a child process, and a plain `posix_spawn` that closes nothing, as a library might start one.
enum ChildSpawner: String, CaseIterable, CustomTestStringConvertible {
    case processCapture, foundationProcess, detachedProcess, plainSpawn

    var testDescription: String { rawValue }
}

/// A child that is still running, as one a broker or command starts while it holds sockets.
struct RunningChild {
    let stop: @Sendable () async -> Void

    /// Starts `/bin/sh`, which marks itself ready and then sleeps for 5 s in the same process.
    static func start(_ spawner: ChildSpawner, in folder: String) async throws -> RunningChild {
        let ready = folder + "/ready"
        let arguments = ["-c", "/usr/bin/touch \"$0\"; exec /bin/sleep 5", ready]
        let child: RunningChild
        switch spawner {
        case .processCapture:
            let task = Task { _ = try? await ProcessCapture.run(executable: "/bin/sh", arguments: arguments, timeout: 10) }
            child = RunningChild { task.cancel(); _ = await task.value }
        case .foundationProcess:
            let task = Task {
                _ = try? await AccessibilityFetcher.runProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 10)
            }
            child = RunningChild { task.cancel(); _ = await task.value }
        case .detachedProcess:
            let pid = try DetachedProcess().launch(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, environment: [:], logPath: folder + "/child.log"
            )
            child = RunningChild { await kill(pid) }
        case .plainSpawn:
            let argv = (["/bin/sh"] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var spawned: pid_t = 0
            try #require(posix_spawn(&spawned, "/bin/sh", nil, nil, argv, environ) == 0)
            let pid = spawned
            child = RunningChild { await kill(pid) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if !FileManager.default.fileExists(atPath: ready) { Issue.record("the \(spawner.rawValue) child never started") }
        return child
    }

    private static func kill(_ pid: pid_t) async {
        Darwin.kill(pid, SIGKILL)
        var attempts = 0
        while DetachedProcess().exitStatus(of: pid) == nil, attempts < 100 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("Sockets in child processes", .serialized)
struct ChildDescriptorTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static func folder() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-fds-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// True when the peer's end is closed, so `descriptor` reads EOF within `milliseconds`.
    static func readsEOF(_ descriptor: Int32, within milliseconds: Int32 = 1000) -> Bool {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, milliseconds) == 1 else { return false }
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) == 0
    }

    @Test("a child holds none of a broker's sockets, so closing one ends it at once", arguments: ChildSpawner.allCases)
    func childHoldsNoSockets(_ spawner: ChildSpawner) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/b.sock"
        let listener = try UnixSocket.listen(at: path)
        let leavingClient = try HIDBroker.connect(to: path)
        let servedForLeavingClient = CloseOnExecSocket.accept(listener)
        let stayingClient = try HIDBroker.connect(to: path)
        let servedForStayingClient = CloseOnExecSocket.accept(listener)
        try #require(servedForLeavingClient >= 0 && servedForStayingClient >= 0)
        defer {
            close(servedForLeavingClient)
            close(stayingClient)
            unlink(path)
        }

        let child = try await RunningChild.start(spawner, in: folder)
        close(leavingClient)
        let brokerSawClientLeave = Self.readsEOF(servedForLeavingClient)
        close(servedForStayingClient)
        let clientSawBrokerHangUp = Self.readsEOF(stayingClient)
        close(listener)
        let socketStillAnswers = UnixSocket.answers(path)
        await child.stop()

        #expect(brokerSawClientLeave, "the child kept the client's socket open")
        #expect(clientSawBrokerHangUp, "the child kept the accepted socket open")
        #expect(!socketStillAnswers, "the child kept the listening socket open")
    }

    @Test("every socket and accept in Sources goes through CloseOnExecSocket")
    func noRawSocketCalls() throws {
        let call = try Regex(#"(^|[^A-Za-z0-9_.])(socket|socketpair|accept)\(|Darwin\.(socket|socketpair|accept)\("#)
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.sources.path.count + 1))
            guard relative != "OffsiderCore/Platform/CloseOnExecSocket.swift" else { continue }
            let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(call) && !line.contains("func accept(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "Use CloseOnExecSocket.make or .accept: \(offenders.joined(separator: ", "))")
    }
}
