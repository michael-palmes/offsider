import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderAndroid
import OffsiderCore

struct HIDBrokerBootIdentity: Equatable {
    let processIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum HIDBroker {
    static let inputDeliveryFailureDescription = "Offsider could not deliver simulator input. The simulator may have restarted or disconnected. Confirm it is booted and try again."
    static let dtuhidMinimumBootUptime: TimeInterval = 10
    /// The largest handshake or reply; a request may be up to `maximumRequestBytes`.
    static let maximumMessageBytes = 64 * 1024
    static let maximumRequestBytes = 2 << 20
    static let serverIOTimeoutMilliseconds: Int = 2_000
    static let clientWriteTimeoutMilliseconds: Int = 2_000
    static let clientResponseTimeoutMilliseconds: Int = 30_000
    /// How long a command waits for a running broker's handshake before opening its own input session.
    static let attachTimeoutMilliseconds: Int = 2_000
    static let startupAttempts = 300
    static let startupTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// `touch --down` or `--up` alone: one request on a connection of its own, waiting for a broker to start when none runs.
    static func sendDetachedTouch(_ event: FBSimulatorHIDEvent, simulatorUDID: String) throws {
        let endpoint = try endpointPath(simulatorUDID: simulatorUDID)
        try sendInput(event, keepHeld: true) {
            try connectToReadyBroker(simulatorUDID: simulatorUDID, endpoint: endpoint)
        }
    }

    static func sendInput(
        _ event: FBSimulatorHIDEvent,
        keepHeld: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        descriptorProvider: () throws -> Int32
    ) throws {
        let request = try request(for: event, keepHeld: keepHeld, environment: environment)
        // Recovery is limited to broker readiness. Once exchange starts, a lost response has an
        // ambiguous outcome, so the request must never be reconnected or replayed.
        let descriptor = try descriptorProvider()
        defer { Darwin.close(descriptor) }
        do {
            try exchange(request.data, on: descriptor, timeoutMilliseconds: request.timeoutMilliseconds)
        } catch let notSent as HIDBrokerNotSent {
            throw CLIError(errorDescription: notSent.userFacingDescription, reason: .hidBrokerFailed)
        }
    }

    /// The encoded request, refused before anything is sent when the broker would refuse it, and how long its reply may take.
    static func request(
        for event: FBSimulatorHIDEvent,
        keepHeld: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (data: Data, timeoutMilliseconds: Int) {
        let summary = try HIDBrokerEvent.validate(event, limitingCount: false)
        let request = HIDBrokerRequest(
            op: .input,
            event: HIDBrokerEvent(event),
            keepHeld: keepHeld ? true : nil,
            stabilizationMs: HIDStabilization.resolve(environment: environment).milliseconds,
            idleSeconds: SimulatorSessionSettings.idleSeconds(environment)
        )
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        // Input too long for the broker, such as pages of typed text, goes through the command's own session.
        guard summary.primitives <= HIDBrokerEvent.maxPrimitives, data.count <= maximumRequestBytes else {
            throw HIDBrokerNotSent(detail: "\(summary.primitives) events are too many for one request")
        }
        // idb paces keys 10 ms apart and settles 50 ms after them.
        let seconds = summary.delaySeconds + Double(summary.keyboardEvents) * 0.01 + 0.05
        return (data, clientResponseTimeoutMilliseconds + Int(seconds * 1000))
    }

    enum Attachment: Equatable {
        /// A ready broker's connection, its handshake read.
        case ready(Int32)
        /// No broker runs, so this command opens its own session and starts one for the next.
        case absent
        /// One is starting, stopping or did not answer in time; this command opens its own session.
        case unavailable
    }

    /// A ready broker's connection for a command's input session, if one runs.
    static func attach(simulatorUDID: String) -> Attachment {
        guard let endpoint = try? endpointPath(simulatorUDID: simulatorUDID) else { return .unavailable }
        return attach(endpoint: endpoint, connector: connect(to:))
    }

    static func attach(endpoint: String, connector: (String) throws -> Int32) -> Attachment {
        do {
            return .ready(try connectAndAwaitHandshake(endpoint: endpoint, connector: connector, timeoutMilliseconds: attachTimeoutMilliseconds))
        } catch {
            logDiagnostic(error)
            // One whose simulator restarted stops by itself, so the next is started once this command is done.
            if let notReady = error as? HIDBrokerNotReadyError {
                return notReady.isSafeToReplaceBroker ? .absent : .unavailable
            }
            // A broker still starting holds the lifetime lock before it listens.
            guard isBrokerUnavailable(error), liveness(endpoint: endpoint) != .alive else { return .unavailable }
            return .absent
        }
    }

    /// Starts a broker for the next command unless one already runs; a second one started at the same moment exits at the lifetime lock.
    static func startInBackground(simulatorUDID: String) {
        guard let endpoint = try? endpointPath(simulatorUDID: simulatorUDID), liveness(endpoint: endpoint) != .alive else { return }
        do {
            try spawnBroker(simulatorUDID: simulatorUDID)
        } catch {
            diagnosticLog("Could not start the simulator input broker: \(error.localizedDescription)")
        }
    }

    /// Serves `simulatorUDID` until idle; this process holds the endpoint's lifetime lock.
    @MainActor
    static func serve(simulatorUDID: String, logger: OffsiderLogger) async throws {
        let endpoint = try endpointPath(simulatorUDID: simulatorUDID)
        let boot = try currentBootIdentity(simulatorUDID: simulatorUDID)
        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let listener: Int32
        do {
            // Only the lifetime lock's holder listens, so a socket left at the path is a dead broker's.
            try removeOwnedSocket(endpoint)
            listener = try makeListener(at: endpoint)
        } catch {
            await HIDInteractor.closeSession(session)
            throw error
        }
        let server = HIDBrokerServer(
            udid: simulatorUDID,
            listener: listener,
            endpoint: endpoint,
            sink: .live(session, logger: logger),
            isCurrentBoot: { bootIdentity(processIdentifier: boot.processIdentifier) == boot },
            idleSeconds: SimulatorSessionSettings.idleSeconds(ProcessInfo.processInfo.environment),
            log: { line in
                let stamp = ISO8601DateFormatter().string(from: Date())
                FileHandle.standardOutput.write(Data("\(stamp) \(line)\n".utf8))
            }
        )
        // A command that leaves before its handshake must not end the broker with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { server.requestStop("signal \(number)") } }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        server.log("Serving \(simulatorUDID) on \(endpoint)")
        let reason = await server.run()
        server.log("Stopped: \(reason)")
        await HIDInteractor.closeSession(session)
    }

    static func isSameUserPeer(_ client: Int32, expectedUID: uid_t = getuid()) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return getpeereid(client, &peerUID, &peerGID) == 0 && peerUID == expectedUID
    }

    static func brokerResponseDescription(for error: Error) -> String {
        if let userFacingError = error as? UserFacingError {
            return userFacingError.userFacingDescription
        }
        return inputDeliveryFailureDescription
    }

    static func endpointPath(simulatorUDID: String) throws -> String {
        let developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
        try requireTrustedDeveloperDirectory(developerDirectory)
        return try endpointPath(simulatorUDID: simulatorUDID, developerDirectory: developerDirectory)
    }

    static func brokerRootPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent(BrokerEndpointNaming.rootDirectoryName(uid: getuid()), isDirectory: true)
            .path
    }

    static func endpointPath(simulatorUDID: String, developerDirectory: String) throws -> String {
        let root = brokerRootPath()
        try ensurePrivateDirectory(root, uid: getuid())
        let developerDirectory = URL(fileURLWithPath: developerDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        // The filename carries the wire protocol version so an older broker cannot intercept a request.
        let filename = BrokerEndpointNaming.endpointFilename(
            simulatorUDID: simulatorUDID,
            developerDirectory: developerDirectory
        )
        let path = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(filename).path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CLIError(errorDescription: "HID broker socket path is too long.", reason: .hidBrokerFailed)
        }
        return path
    }

    private static func ensurePrivateDirectory(_ path: String, uid: uid_t) throws {
        do {
            try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: uid)
        } catch let error as PrivateDirectoryError {
            throw brokerError(error, subject: "directory")
        }
    }

    /// Keeps the broker's own wording, and POSIX errors in their domain so callers can still match `EWOULDBLOCK` and `ENOENT`.
    static func brokerError(_ error: PrivateDirectoryError, subject: String) -> Error {
        switch error.kind {
        case .unsafeDirectory:
            return CLIError(errorDescription: "HID broker directory is not a private owned directory.", reason: .privateDirectoryUnsafe)
        case .unsafeFile:
            return CLIError(errorDescription: "HID broker " + subject + " is not a private owned file.", reason: .privateDirectoryUnsafe)
        case .system(let operation, let code):
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "HID broker \(operation) \(subject) failed: \(String(cString: strerror(code)))"
            ])
        }
    }

    /// Starts `hid-broker` detached in its own session, logging to the private `sessions/`; returns its pid.
    @discardableResult
    static func spawnBroker(simulatorUDID: String) throws -> Int32 {
        guard let executable = Bundle.main.executableURL else {
            throw CLIError(errorDescription: "Unable to locate the Offsider executable for the HID broker.", reason: .hidBrokerFailed)
        }
        return try DetachedProcess().launch(
            executable: executable,
            arguments: ["hid-broker", "--udid", simulatorUDID],
            environment: ChildEnvironment.make(.offsiderBroker, from: ProcessInfo.processInfo.environment).filter { $0.key != "OFFSIDER_TIMINGS" },
            logPath: try logPath(simulatorUDID: simulatorUDID)
        )
    }

    /// `sessions/simulator-<hash>.log` in the private directory, beside the other brokers' logs.
    static func logPath(simulatorUDID: String) throws -> String {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(AndroidHost.sessionsDirectoryName)
        let name = "simulator-" + String(BrokerEndpointNaming.fnv1a64(simulatorUDID), radix: 36) + ".log"
        return (directory as NSString).appendingPathComponent(name)
    }

    private static func connectToReadyBroker(simulatorUDID: String, endpoint: String) throws -> Int32 {
        var spawned: Int32?
        do {
            return try connectToReadyBroker(
                simulatorUDID: simulatorUDID,
                endpoint: endpoint,
                connector: connect(to:),
                spawner: { spawned = try spawnBroker(simulatorUDID: $0) },
                sleeper: { _ = usleep($0) },
                spawnedBrokerExited: { spawned.map { DetachedProcess().exitStatus(of: $0) != nil } ?? false }
            )
        } catch {
            logDiagnostic(error)
            throw error
        }
    }

    static func connectToReadyBroker(
        simulatorUDID: String,
        endpoint: String,
        connector: (String) throws -> Int32,
        spawner: (String) throws -> Void,
        sleeper: (useconds_t) -> Void,
        monotonicNow: () -> UInt64 = monotonicTimeNanoseconds,
        spawnedBrokerExited: () -> Bool = { false }
    ) throws -> Int32 {
        let startedAt = monotonicNow()
        let deadlineResult = startedAt.addingReportingOverflow(startupTimeoutNanoseconds)
        let deadline = deadlineResult.overflow ? UInt64.max : deadlineResult.partialValue
        func handshakeTimeout() throws -> Int {
            let now = monotonicNow()
            guard now < deadline else {
                throw HIDBrokerNotReadyError(diagnosticDescription: "The broker startup deadline expired.")
            }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            return min(serverIOTimeoutMilliseconds, remainingMilliseconds)
        }

        do {
            return try connectAndAwaitHandshake(
                endpoint: endpoint,
                connector: connector,
                timeoutMilliseconds: handshakeTimeout()
            )
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        // Hold the endpoint lock until the listener accepts connections so concurrent cold-start
        // clients wait for this broker instead of spawning competitors.
        let lockDescriptor = try acquireStartupLock(
            endpoint: endpoint,
            deadline: deadline,
            monotonicNow: monotonicNow,
            sleeper: sleeper
        )
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        do {
            return try connectAndAwaitHandshake(
                endpoint: endpoint,
                connector: connector,
                timeoutMilliseconds: handshakeTimeout()
            )
        } catch {
            guard isBrokerUnavailable(error) else { throw error }
        }
        var didSpawnBroker = false
        if try !isBrokerProcessAlive(endpoint: endpoint) {
            try waitForStaleEndpointShutdown(
                endpoint,
                deadline: deadline,
                monotonicNow: monotonicNow,
                sleeper: sleeper
            )
            try spawner(simulatorUDID)
            didSpawnBroker = true
        }
        var lastError: Error?
        for _ in 0..<startupAttempts {
            guard monotonicNow() < deadline else { break }
            do {
                return try connectAndAwaitHandshake(
                    endpoint: endpoint,
                    connector: connector,
                    timeoutMilliseconds: handshakeTimeout()
                )
            } catch {
                guard isBrokerUnavailable(error) else { throw error }
                lastError = error
                if didSpawnBroker, !(error is HIDBrokerNotReadyError), spawnedBrokerExited(), try !isBrokerProcessAlive(endpoint: endpoint) {
                    throw HIDBrokerNotReadyError(
                        diagnosticDescription: "The broker exited before it listened; see \((try? logPath(simulatorUDID: simulatorUDID)) ?? "its log").",
                        isSafeToReplaceBroker: false
                    )
                }
                if let notReady = error as? HIDBrokerNotReadyError,
                   notReady.isSafeToReplaceBroker {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                } else if let notReady = error as? HIDBrokerNotReadyError,
                          notReady.allowsReplacementAfterProcessExit,
                          try !isBrokerProcessAlive(endpoint: endpoint) {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                } else if try !isBrokerProcessAlive(endpoint: endpoint), !didSpawnBroker {
                    try waitForStaleEndpointShutdown(
                        endpoint,
                        deadline: deadline,
                        monotonicNow: monotonicNow,
                        sleeper: sleeper
                    )
                    try spawner(simulatorUDID)
                    didSpawnBroker = true
                }
                sleeper(100_000)
            }
        }
        let failure: HIDBrokerNotReadyError
        if let notReady = lastError as? HIDBrokerNotReadyError {
            failure = notReady
        } else {
            failure = HIDBrokerNotReadyError(
                diagnosticDescription: "Broker startup failed: \(lastError?.localizedDescription ?? "no connection attempt completed")",
                isSafeToReplaceBroker: false
            )
        }
        throw failure
    }

}
