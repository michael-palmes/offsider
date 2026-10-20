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
            child = .untilCancelled { _ = try? await ProcessCapture.run(executable: "/bin/sh", arguments: arguments, timeout: 60) }
        case .foundationProcess:
            child = .untilCancelled {
                _ = try? await AccessibilityFetcher.runProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 60)
            }
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
        while !FileManager.default.fileExists(atPath: ready), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !FileManager.default.fileExists(atPath: ready) { Issue.record("the \(spawner.rawValue) child never started") }
        return child
    }

    /// A call that returns once its child exits, and ends the child when cancelled.
    static func untilCancelled(_ call: @escaping @Sendable () async -> Void) -> RunningChild {
        let task = Task { await call() }
        return RunningChild { task.cancel(); _ = await task.value }
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
    func stopAll() { all.forEach { $0?.stop() } }
}

/// Descriptors a test opened; each is closed once, by the test or at its end.
final class OpenDescriptors: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<Int32> = []

    func add(_ descriptor: Int32) -> Int32 {
        if descriptor >= 0 { lock.withLock { _ = open.insert(descriptor) } }
        return descriptor
    }

    func close(_ descriptor: Int32) {
        if lock.withLock({ open.remove(descriptor) }) != nil { Darwin.close(descriptor) }
    }

    func closeAll() {
        let remaining = lock.withLock {
            defer { open = [] }
            return open
        }
        remaining.forEach { Darwin.close($0) }
    }
}

/// Each broker's own accept loop.
enum BrokerAccept: String, CaseIterable {
    case helperBroker, hidBroker, deviceSession
}

@Suite("Sockets in child processes", .serialized)
struct ChildDescriptorTests {
    static func folder() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-fds-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// A connected pair with neither end close-on-exec, as any descriptor a library opens may be.
    static func barePair(_ descriptors: OpenDescriptors) throws -> (Int32, Int32) {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        return (descriptors.add(ends[0]), descriptors.add(ends[1]))
    }

    /// True once the peer's end of `descriptor` is closed within `milliseconds`, peeked every 10 ms so no thread waits on it.
    static func readsEOF(_ descriptor: Int32, within milliseconds: Int = 1000) async -> Bool {
        guard descriptor >= 0 else { return false }
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while !SocketPeer.closed(descriptor) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("Offsider's ways of starting a child pass on no descriptor but stdin, stdout and stderr", arguments: ChildSpawner.allCases)
    func spawnersPassOnNothing(_ spawner: ChildSpawner) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let descriptors = OpenDescriptors()
        defer { descriptors.closeAll() }
        let (kept, peer) = try Self.barePair(descriptors)

        let child = try await RunningChild.start(spawner, in: folder)
        descriptors.close(kept)
        let peerSawClose = await Self.readsEOF(peer)
        await child.stop()

        #expect(peerSawClose, "the \(spawner.rawValue) child kept a descriptor that was not close-on-exec")
    }

    @Test("a child that inherits what is not close-on-exec gets none of the broker listeners and clients")
    func listenersAndClientsStayOut() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let descriptors = OpenDescriptors()
        defer { descriptors.closeAll() }
        let path = folder + "/b.sock"
        let hidPath = folder + "/h.sock"
        let listener = descriptors.add(try UnixSocket.listen(at: path))
        let hidListener = descriptors.add(try HIDBroker.makeListener(at: hidPath))
        let hidClient = descriptors.add(try HIDBroker.connect(to: path))
        let hidServed = descriptors.add(accept(listener, nil, nil))
        let sessionClient = try DeviceSessionChannel.connect(to: path)
        defer { sessionClient.close() }
        let sessionServed = descriptors.add(accept(listener, nil, nil))
        let (control, controlPeer) = try Self.barePair(descriptors)
        let child = try #require(InheritingChild(inheriting: [listener, hidListener, hidClient, sessionClient.descriptor, control]))
        defer { child.stop() }

        descriptors.close(control)
        let controlHeld = await !Self.readsEOF(controlPeer, within: 200)
        descriptors.close(hidClient)
        let hidClientReleased = await Self.readsEOF(hidServed)
        sessionClient.close()
        let sessionClientReleased = await Self.readsEOF(sessionServed)
        descriptors.close(listener)
        let listenerAnswers = UnixSocket.answers(path)
        descriptors.close(hidListener)
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
        let descriptors = OpenDescriptors()
        defer { descriptors.closeAll() }
        let path = folder + "/b.sock"
        let (control, controlPeer) = try Self.barePair(descriptors)
        let started = StartedChildren()
        defer { started.stopAll() }
        // The hook runs after the broker's own accept and before it closes the refused connection.
        let admits: @Sendable (Int32) -> Bool = { accepted in
            started.append(InheritingChild(inheriting: [accepted, control]))
            return false
        }

        let stopBroker = try await Self.startAccepting(broker, at: path, admits: admits)
        let client: Int32
        do {
            client = descriptors.add(try HIDBroker.connect(to: path))
        } catch {
            await stopBroker()
            throw error
        }
        let clientSawClose = await Self.readsEOF(client, within: 10_000)
        await stopBroker()
        // Closed only once no hook can run, so a late one never passes on a reused descriptor number.
        descriptors.close(control)
        let controlHeld = await !Self.readsEOF(controlPeer, within: 200)

        #expect(started.all.count == 1 && started.all.allSatisfy { $0 != nil }, "the broker never admitted the connection")
        #expect(controlHeld, "the child should inherit a descriptor that is not close-on-exec")
        #expect(clientSawClose, "the child kept the \(broker.rawValue) connection open")
    }

    static func startAccepting(_ broker: BrokerAccept, at path: String, admits: @escaping @Sendable (Int32) -> Bool) async throws -> @Sendable () async -> Void {
        switch broker {
        case .helperBroker:
            let listener = try UnixSocketListener(path: path, admits: admits)
            let accepting = Task { await listener.accept(timeout: .seconds(10)) }
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

    /// Call sites of `names` in `Sources/` outside `allowed` files, the device-side runner, comments, and `func` or `case` declarations.
    static func calls(to names: [String], outside allowed: Set<String>) throws -> [String] {
        let lines = try #require(SourceLines.all)
        let alternatives = names.joined(separator: "|")
        let declaration = try Regex(#"\b(func|case)\s+("# + alternatives + #")\("#)
        let call = try Regex(#"(^|[^A-Za-z0-9_.])("# + alternatives + #")\(|Darwin\.("# + alternatives + #")\("#)
        let needles = names.map { $0 + "(" }
        return lines.filter { line in
            needles.contains(where: line.text.contains) && !allowed.contains(line.file) && !line.file.hasPrefix("Offsider/Resources/runner/")
                && !line.isComment && String(line.text).replacing(declaration, with: "").contains(call)
        }.map(\.location)
    }

    @Test("every socket, accept and descriptor copy in Sources is close-on-exec")
    func noRawSocketCalls() throws {
        let copy = try Regex("F_DUPFD(?!_CLOEXEC)")
        let offenders = try Self.calls(to: ["socket", "socketpair", "accept", "dup", "dup2"], outside: ["OffsiderCore/Platform/CloseOnExecSocket.swift"])
            + (try #require(SourceLines.all)).filter { $0.text.contains("F_DUPFD") && !$0.isComment && $0.text.contains(copy) }.map(\.location)
        #expect(offenders.isEmpty, "Use CloseOnExecSocket.make or .accept, or F_DUPFD_CLOEXEC for a copy: \(offenders.joined(separator: ", "))")
    }

    @Test("every child process in Sources starts through DetachedProcess or Foundation's Process")
    func noOtherSpawns() throws {
        let names = ["posix_spawn", "posix_spawnp", "fork", "vfork", "system", "popen", "execv", "execve", "execvp", "execl", "execlp", "execle"]
        let offenders = try Self.calls(to: names, outside: ["OffsiderCore/Process/DetachedProcess.swift"])
        #expect(offenders.isEmpty, "Start children with DetachedProcess or Process, which pass on no descriptor but stdio: \(offenders.joined(separator: ", "))")
    }
}
