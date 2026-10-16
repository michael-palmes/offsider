import Darwin
import Foundation
import OffsiderCore

/// A command's way to the warm helper of one serial: an answering broker of this build, else a fresh one started under a lock.
@MainActor
struct HelperBrokerClient {
    static let connectTimeout: Duration = .milliseconds(500)
    /// From the spawn until the new broker listens.
    static let spawnTimeout: Duration = .seconds(10)
    /// A starting broker answers `hello` once its helper is ready, which takes as long as a cold helper start.
    static let helloTimeout: Duration = HelperLauncher.readyTimeout + .seconds(5)
    static let controlTimeout: Duration = .seconds(2)
    static let goneTimeout: Duration = .seconds(3)
    static let startLockWait: Duration = .seconds(45)

    let serial: String
    let paths: HelperBrokerPaths
    let dexSha256: String
    /// This command's `OFFSIDER_ANDROID_SESSION_IDLE`; a broker started with another is replaced.
    let idleSeconds: Int
    let host: HelperBrokerHost
    let log: AndroidLog
    var timing: AndroidTiming = .disabled

    init(
        serial: String, dexSha256: String, idleSeconds: Int, host: HelperBrokerHost, log: @escaping AndroidLog, timing: AndroidTiming = .disabled
    ) throws {
        let directory: String
        do {
            directory = try host.directory()
        } catch {
            throw HelperBrokerUnavailable(detail: "the private sessions folder is unusable: \(error)")
        }
        paths = HelperBrokerPaths(serial: serial, directory: directory)
        do {
            _ = try UnixSocket.address(paths.socket)
        } catch let error as UnixSocketError {
            throw HelperBrokerUnavailable(error)
        }
        self.serial = serial
        self.dexSha256 = dexSha256
        self.idleSeconds = idleSeconds
        self.host = host
        self.log = log
        self.timing = timing
    }

    /// The warm helper after `hello`; throws `HelperStartFailure` as a launch would, `HelperBrokerUnavailable` when no broker can serve.
    func connect(helloID: Int) async throws -> HelperConnection {
        try await timing.measure(.helperAttach) {
            if let connection = try await existing(helloID: helloID) { return connection }
            let lock: DeviceLock
            do {
                lock = try await DeviceLock.acquire(
                    DeviceLockKey(platform: .android, id: "\(serial).helper"), command: "helper start", wait: Self.startLockWait, root: host.lockRoot
                )
            } catch {
                throw HelperBrokerUnavailable(detail: "another command is still starting it: \(error)")
            }
            defer { lock.release() }
            if let connection = try await existing(helloID: helloID) { return connection }
            return try await timing.measure(.brokerStart) { try await start(helloID: helloID) }
        }
    }

    /// The answering broker's connection when it runs this build's helper and idle timeout; any other is stopped. Never starts one.
    func existing(helloID: Int) async throws -> HelperConnection? {
        guard let stream = await open() else { return nil }
        switch try await hello(stream, helloID: helloID) {
        case .ready(let connection):
            return connection
        case .replace(let detail):
            log(.debug, "The warm helper on \(serial) does not match this command (\(detail)); replacing it")
            await stop()
            return nil
        case .ended:
            await untilGone()
            return nil
        }
    }

    private func start(helloID: Int) async throws -> HelperConnection {
        let pid: Int32
        do {
            pid = try host.spawn(serial, paths.log)
        } catch {
            throw HelperBrokerUnavailable(detail: "could not start the broker: \(error)")
        }
        log(.debug, "Started the warm helper's broker for \(serial) (pid \(pid))")
        let deadline = ContinuousClock.now + Self.spawnTimeout
        while true {
            if let stream = await open() {
                switch try await hello(stream, helloID: helloID) {
                case .ready(let connection): return connection
                case .replace(let detail): throw HelperBrokerUnavailable(detail: "the broker it started does not match this command (\(detail))")
                case .ended: throw HelperBrokerUnavailable(detail: "the broker stopped before its helper was ready; see \(paths.log)")
                }
            }
            if let status = host.exitStatus(pid) {
                throw HelperBrokerUnavailable(detail: "the broker exited with status \(status) before it listened; see \(paths.log)")
            }
            guard ContinuousClock.now < deadline else {
                throw HelperBrokerUnavailable(detail: "the broker did not listen within \(Self.spawnTimeout); see \(paths.log)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult
    func stop() async -> Bool {
        await Self.stop(at: paths.socket)
    }

    private func untilGone() async {
        await Self.untilGone(paths.socket)
    }

    /// Asks the broker at `path` to stop and waits until its socket is gone, which is after its helper has freed the UiAutomation slot.
    @discardableResult
    static func stop(at path: String) async -> Bool {
        guard UnixSocket.answers(path), await control("stop", at: path) != nil else { return false }
        await untilGone(path)
        return true
    }

    static func untilGone(_ path: String) async {
        let deadline = ContinuousClock.now + goneTimeout
        while UnixSocket.answers(path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open() async -> PosixAdbStream? {
        await Self.open(paths.socket)
    }

    private enum Greeting {
        case ready(HelperConnection)
        /// Another build's broker, or one with another idle timeout.
        case replace(String)
        case ended
    }

    private func hello(_ stream: PosixAdbStream, helloID: Int) async throws -> Greeting {
        let connection = HelperConnection(shell: nil, socket: stream, ready: Self.unknownReady)
        let outcome: HelperConnection.Outcome
        do {
            outcome = try await connection.exchange(.hello(token: ""), id: helloID, timeout: Self.helloTimeout)
        } catch {
            await connection.close()
            throw HelperBrokerUnavailable(detail: "its hello failed: \(error)")
        }
        guard case .reply(let frame) = outcome else {
            await connection.close()
            if case .timedOut = outcome {
                throw HelperBrokerUnavailable(detail: "no reply to hello within \(Self.helloTimeout)")
            }
            return .ended
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(HelperEnvelope.self, from: frame) else {
            await connection.close()
            return .replace("its hello reply was unreadable")
        }
        guard envelope.ok == true else {
            await connection.close()
            let reply = try? decoder.decode(HelperBrokerWire.ErrorReply.self, from: frame)
            if let failure = reply?.startFailure { throw failure }
            if reply?.error.code == HelperBrokerWire.Code.ended { return .ended }
            throw HelperBrokerUnavailable(detail: reply?.error.message ?? "it refused hello")
        }
        guard let hello = try? decoder.decode(HelperHello.self, from: frame),
              let broker = try? decoder.decode(HelperBrokerWire.Hello.self, from: frame) else {
            await connection.close()
            return .replace("its hello reply has no broker fields")
        }
        guard broker.brokerProtocol == HelperBrokerWire.protocolVersion, hello.protocol == HelperDex.protocolVersion, broker.dexSha256 == dexSha256 else {
            await connection.close()
            return .replace("broker protocol \(broker.brokerProtocol), helper protocol \(hello.protocol), helper \(broker.dexSha256.prefix(12))")
        }
        guard broker.idleSeconds == idleSeconds else {
            await connection.close()
            return .replace("it stops after \(broker.idleSeconds) idle seconds, this command asks for \(idleSeconds)")
        }
        connection.adopt(HelperReady(
            event: "ready", protocol: hello.protocol, helper: hello.helper, pid: broker.helperPid, socket: "", token: "", sdkInt: broker.sdkInt
        ))
        connection.ops = hello.ops ?? []
        connection.eventSeq = broker.eventSeq
        connection.launchMilliseconds = broker.launchMs
        connection.pushed = broker.pushed
        return .ready(connection)
    }

    /// Stands in until `hello` names the warm helper; a broker never asks for the token.
    static let unknownReady = HelperReady(event: "ready", protocol: HelperDex.protocolVersion, helper: "", pid: 0, socket: "", token: "", sdkInt: 0)

    static func open(_ path: String) async -> PosixAdbStream? {
        let deadline = ContinuousClock.now + connectTimeout
        return try? await PosixAdbStream.onQueue(DispatchQueue(label: "offsider.helper-broker.connect")) {
            try PosixAdbStream.open(.unix(path: path), deadline: deadline)
        }
    }

    /// One op the broker at `path` answers itself, which never counts as use; nil when nothing answered.
    static func control(_ op: String, fields: [String: HelperValue] = [:], at path: String) async -> Data? {
        guard let stream = await open(path) else { return nil }
        let connection = HelperConnection(shell: nil, socket: stream, ready: unknownReady)
        let outcome = try? await connection.exchange(HelperRequest(op: op, fields: fields), id: 1, timeout: controlTimeout)
        // Closed before returning, so a status read never holds one of the broker's client slots afterwards.
        await connection.close()
        guard case .reply(let frame)? = outcome else { return nil }
        return frame
    }

    static func status(at path: String) async -> HelperBrokerWire.Status? {
        guard let frame = await control("status", at: path) else { return nil }
        return try? JSONDecoder().decode(HelperBrokerWire.StatusReply.self, from: frame).status
    }

    /// The display facts a command left with the broker at `path`; nil when it has none or nothing answered.
    static func screen(at path: String) async -> String? {
        guard let frame = await control("screen", at: path) else { return nil }
        return try? JSONDecoder().decode(HelperBrokerWire.ScreenReply.self, from: frame).screen
    }

    /// Leaves `screen` with the broker at `path` for later commands; false when nothing answered.
    @discardableResult
    static func rememberScreen(_ screen: String, at path: String) async -> Bool {
        guard let frame = await control("rememberScreen", fields: ["screen": .string(screen)], at: path) else { return false }
        return HelperBrokerWire.isOK(frame)
    }
}
