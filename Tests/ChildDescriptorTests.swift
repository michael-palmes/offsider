import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid
@testable import OffsiderIOSDevice

/// Each way Offsider starts a child process.
enum ChildSpawner: String, CaseIterable {
    case processCapture, foundationProcess, detachedProcess
}

/// A child that is still running, as one a broker or command starts while it holds sockets.
struct RunningChild {
    let stop: @Sendable () async -> Void

    /// Starts `/bin/sh`, which marks itself ready and then sleeps for 30 s in the same process.
    static func start(_ spawner: ChildSpawner, in folder: String) async throws -> RunningChild {
        let ready = folder + "/ready"
        let arguments = ["-c", "/usr/bin/touch \"$0\"; exec /bin/sleep 30", ready]
        let child: RunningChild
        switch spawner {
        case .processCapture:
            let task = Task { _ = try? await ProcessCapture.run(executable: "/bin/sh", arguments: arguments, timeout: 60) }
            child = RunningChild { task.cancel(); _ = await task.value }
        case .foundationProcess:
            let task = Task {
                _ = try? await AccessibilityFetcher.runProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 60)
            }
            child = RunningChild { task.cancel(); _ = await task.value }
        case .detachedProcess:
            let pid = try DetachedProcess().launch(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, environment: [:], logPath: folder + "/child.log"
            )
            child = RunningChild {
                Darwin.kill(pid, SIGKILL)
                var attempts = 0
                while DetachedProcess().exitStatus(of: pid) == nil, attempts < 100 {
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if !FileManager.default.fileExists(atPath: ready) { Issue.record("the \(spawner.rawValue) child never started") }
        return child
    }
}

/// A `/bin/sleep 30` that, as a plain `posix_spawn` would, inherits each of `descriptors` unless it is close-on-exec, and nothing else.
struct InheritingChild: Sendable {
    let pid: pid_t

    init?(inheriting descriptors: [Int32]) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Under CLOEXEC_DEFAULT only these reach the child, and on macOS a dup2 onto itself keeps each one's own close-on-exec flag.
        for descriptor in descriptors { posix_spawn_file_actions_adddup2(&actions, descriptor, descriptor) }
        let words: [String] = ["/bin/sleep", "30"]
        let argv = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sleep", &actions, &attributes, argv, environ) == 0 else { return nil }
        self.pid = pid
    }

    func stop() {
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

/// The children a broker's `admits` hook started, read back by the test.
final class StartedChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [InheritingChild?] = []

    func append(_ child: InheritingChild?) { lock.withLock { children.append(child) } }
    var all: [InheritingChild?] { lock.withLock { children } }
}

/// Each broker's own accept loop.
enum BrokerAccept: String, CaseIterable {
    case helperBroker, hidBroker, deviceSession
}

@Suite("Sockets in child processes", .serialized)
struct ChildDescriptorTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static func folder() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-fds-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// A connected pair with neither end close-on-exec, as any descriptor a library opens may be.
    static func barePair() throws -> (Int32, Int32) {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        return (ends[0], ends[1])
    }

    static func connect(to path: String) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        var address = try UnixSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        return client
    }

    /// True when the peer's end is closed, so `descriptor` reads EOF within `milliseconds`; polls off the cooperative pool.
    static func readsEOF(_ descriptor: Int32, within milliseconds: Int32 = 1000) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                var byte: UInt8 = 0
                continuation.resume(returning: poll(&poller, 1, milliseconds) == 1 && read(descriptor, &byte, 1) == 0)
            }
        }
    }

    @Test("Offsider's ways of starting a child pass on no descriptor but stdin, stdout and stderr", arguments: ChildSpawner.allCases)
    func spawnersPassOnNothing(_ spawner: ChildSpawner) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let (kept, peer) = try Self.barePair()
        defer { close(peer) }

        let child = try await RunningChild.start(spawner, in: folder)
        close(kept)
        let peerSawClose = await Self.readsEOF(peer)
        await child.stop()

        #expect(peerSawClose, "the \(spawner.rawValue) child kept a descriptor that was not close-on-exec")
    }

    @Test("a child that inherits what is not close-on-exec gets none of the broker listeners and clients")
    func listenersAndClientsStayOut() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/b.sock"
        let hidPath = folder + "/h.sock"
        let listener = try UnixSocket.listen(at: path)
        let hidListener = try HIDBroker.makeListener(at: hidPath)
        let hidClient = try HIDBroker.connect(to: path)
        let hidServed = accept(listener, nil, nil)
        let sessionClient = try DeviceSessionChannel.connect(to: path)
        let sessionServed = accept(listener, nil, nil)
        let (control, controlPeer) = try Self.barePair()
        defer { [hidServed, sessionServed, controlPeer].forEach { close($0) } }
        let child = try #require(InheritingChild(inheriting: [listener, hidListener, hidClient, sessionClient.descriptor, control]))
        defer { child.stop() }

        close(control)
        let controlHeld = await !Self.readsEOF(controlPeer, within: 200)
        close(hidClient)
        let hidClientReleased = await Self.readsEOF(hidServed)
        sessionClient.close()
        let sessionClientReleased = await Self.readsEOF(sessionServed)
        close(listener)
        let listenerAnswers = UnixSocket.answers(path)
        close(hidListener)
        let hidListenerAnswers = UnixSocket.answers(hidPath)

        #expect(controlHeld, "the child should inherit a descriptor that is not close-on-exec")
        #expect(hidClientReleased, "the child kept the HID broker client open")
        #expect(sessionClientReleased, "the child kept the device session client open")
        #expect(!listenerAnswers, "the child kept the broker listener open")
        #expect(!hidListenerAnswers, "the child kept the HID broker listener open")
    }

    @Test("a child a broker starts while admitting a connection does not hold that connection", arguments: BrokerAccept.allCases)
    func acceptedConnectionStaysOut(_ broker: BrokerAccept) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/b.sock"
        let (control, controlPeer) = try Self.barePair()
        defer { close(controlPeer) }
        let started = StartedChildren()
        // The hook runs after the broker's own accept and before it closes the refused connection.
        let admits: @Sendable (Int32) -> Bool = { accepted in
            started.append(InheritingChild(inheriting: [accepted, control]))
            return false
        }

        let stopBroker = try await Self.startAccepting(broker, at: path, admits: admits)
        let client = try Self.connect(to: path)
        let clientSawClose = await Self.readsEOF(client, within: 10_000)
        close(control)
        let controlHeld = await !Self.readsEOF(controlPeer, within: 200)
        await stopBroker()
        close(client)
        started.all.forEach { $0?.stop() }

        #expect(started.all.count == 1 && started.all.allSatisfy { $0 != nil }, "the broker never admitted the connection")
        #expect(controlHeld, "the child should inherit a descriptor that is not close-on-exec")
        #expect(clientSawClose, "the child kept the \(broker.rawValue) connection open")
    }

    static func startAccepting(_ broker: BrokerAccept, at path: String, admits: @escaping @Sendable (Int32) -> Bool) async throws -> @Sendable () async -> Void {
        switch broker {
        case .helperBroker:
            let listener = try UnixSocketListener(path: path, admits: admits)
            let accepting = Task { await listener.accept(timeout: .seconds(3)) }
            return { _ = await accepting.value; listener.close() }
        case .hidBroker:
            return try await startHIDBroker(at: path, admits: admits)
        case .deviceSession:
            let listener = try UnixSocket.listen(at: path)
            let flag = DeviceSessionStopFlag()
            DeviceSessionServer.acceptLoop(
                listener: listener, flag: flag, udid: "SIM-A", clients: DeviceSessionClientCount(limit: 8),
                timeouts: DeviceSessionTimeouts(first: .seconds(1), header: .seconds(1), body: .seconds(1)), admits: admits
            ) { id, _, _ in (.failure(id: id, CancellationError()), nil) }
            return {
                flag.raise()
                try? await Task.sleep(for: .milliseconds(250))
                close(listener)
                unlink(path)
            }
        }
    }

    @MainActor
    static func startHIDBroker(at path: String, admits: @escaping @Sendable (Int32) -> Bool) throws -> @Sendable () async -> Void {
        let server = HIDBrokerServer(
            udid: "SIM-A", listener: try HIDBroker.makeListener(at: path), endpoint: path, sink: HIDBrokerSink(send: { _ in }, sendPaced: { _ in }),
            isCurrentBoot: { true }, admits: admits, idleSeconds: 60, log: { _ in }
        )
        let serving = Task { await server.run() }
        return { @MainActor in
            server.requestStop("test over")
            _ = await serving.value
        }
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
