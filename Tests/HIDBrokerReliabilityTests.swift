import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("HID Broker Reliability Tests")
struct HIDBrokerReliabilityTests {
    @Test("A request is refused before anything is sent when it has too many events, a coordinate or pause out of range, or pauses over an hour together", arguments: [
        FBSimulatorHIDEvent.composite(Array(repeating: .delay(0), count: 65_537)),
        .delay(3601),
        .delay(-1),
        .delay(.nan),
        .delay(.infinity),
        .composite([.delay(1800), .delay(1800), .delay(1)]),
        .touch(direction: .down, x: .nan, y: 1),
        .touch(direction: .up, x: 1, y: 100_001),
        .twoFingerTouch(direction: .down, finger1: CGPoint(x: 1, y: 1), finger2: CGPoint(x: CGFloat.infinity, y: 1)),
        .deviceOrientation(.portrait),
    ])
    func validateRefuses(event: FBSimulatorHIDEvent) {
        let error = #expect(throws: CLIError.self) { try HIDBrokerEvent.validate(event) }
        #expect(error?.reason == .hidBrokerFailed)
        #expect(error?.userFacingDescription.contains("Nothing was sent") == true)
    }

    @Test("A request at the limits passes validation and is summarised for the reply wait")
    func validateAccepts() throws {
        try HIDBrokerEvent.validate(.composite(Array(repeating: .delay(0), count: 65_536)))
        let summary = try HIDBrokerEvent.validate(.composite([
            .touch(direction: .down, x: 1, y: 2), .delay(1800), .delay(1800), .touch(direction: .up, x: 100_000, y: 2),
            .keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4),
        ]))
        #expect(summary == HIDBrokerEvent.Summary(primitives: 6, delaySeconds: 3600, keyboardEvents: 2))
    }

    @Test("A command waits for its reply as long as the event's pauses and key pacing, on top of the usual 30 s")
    func replyWaitCoversTheEvent() throws {
        let quick = try HIDBroker.request(for: .tapAt(x: 1, y: 2), keepHeld: false, environment: [:])
        let long = try HIDBroker.request(for: .composite([.delay(40), .shortKeyPressSequence(Array(repeating: 4, count: 100))]), keepHeld: false, environment: [:])
        #expect(quick.timeoutMilliseconds < 31_000)
        #expect(long.timeoutMilliseconds >= 30_000 + 40_000 + 2_000)
    }

    @Test("Input too long for the broker, such as pages of typed text, is not sent to it, so the command types it through a session of its own")
    func oversizedRequestGoesItsOwnWay() {
        let keys = FBSimulatorHIDEvent.shortKeyPressSequence(Array(repeating: 4, count: 35_000))
        #expect(throws: HIDBrokerNotSent.self) { try HIDBroker.request(for: keys, keepHeld: false, environment: [:]) }
    }

    @Test("A broker lifetime lock distinguishes a live process from a stale endpoint")
    func lifetimeLockTracksBrokerProcess() throws {
        let endpoint = try makeEndpoint()
        defer { try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock") }

        let lifetimeLock = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        #expect(try HIDBroker.isBrokerProcessAlive(endpoint: endpoint))

        #expect(flock(lifetimeLock, LOCK_UN) == 0)
        Darwin.close(lifetimeLock)
        #expect(try !HIDBroker.isBrokerProcessAlive(endpoint: endpoint))
    }

    @Test("Liveness reports a held, released or missing lock without creating one")
    func livenessDoesNotCreateLock() throws {
        let endpoint = try makeEndpoint()
        defer { removeEndpointArtifacts(endpoint) }
        let lockPath = endpoint + ".lifetime.lock"

        #expect(HIDBroker.liveness(endpoint: endpoint) == .absent)
        #expect(!FileManager.default.fileExists(atPath: lockPath))

        let listener = try HIDBroker.makeListener(at: endpoint)
        defer { Darwin.close(listener) }
        #expect(HIDBroker.liveness(endpoint: endpoint) == .stale)
        #expect(!FileManager.default.fileExists(atPath: lockPath))

        let lifetimeLock = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        #expect(HIDBroker.liveness(endpoint: endpoint) == .alive)

        #expect(flock(lifetimeLock, LOCK_UN) == 0)
        Darwin.close(lifetimeLock)
        #expect(HIDBroker.liveness(endpoint: endpoint) == .stale)
    }

    @Test("A refused connection cannot remove an endpoint owned by a live broker")
    func refusedConnectionPreservesLiveBrokerEndpoint() throws {
        let endpoint = try makeEndpoint()
        let listener = try HIDBroker.makeListener(at: endpoint)
        defer {
            Darwin.close(listener)
            try? HIDBroker.removeOwnedSocket(endpoint)
        }
        var isAlive = true
        var endpointExistedWhileAlive = false

        try HIDBroker.waitForStaleEndpointShutdown(
            endpoint,
            connector: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
            },
            sleeper: { _ in
                endpointExistedWhileAlive = FileManager.default.fileExists(atPath: endpoint)
                isAlive = false
            },
            brokerIsAlive: { isAlive }
        )

        #expect(endpointExistedWhileAlive)
    }

    @Test("Broker startup uses a monotonic deadline")
    func startupDeadlineIsBounded() throws {
        let endpoint = try makeEndpoint()
        defer { removeEndpointArtifacts(endpoint) }
        var now: UInt64 = 0
        var spawnCount = 0

        do {
            _ = try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                },
                spawner: { _ in spawnCount += 1 },
                sleeper: { _ in now = HIDBroker.startupTimeoutNanoseconds },
                monotonicNow: { now }
            )
            Issue.record("Startup should stop at its deadline")
        } catch let error as HIDBrokerNotReadyError {
            #expect(error.userFacingDescription.contains("could not establish simulator input"))
        }

        #expect(spawnCount == 1)
    }

    @Test("A slow broker startup is not spawned more than once")
    func slowStartupSpawnsOnce() throws {
        let endpoint = try makeEndpoint()
        defer { removeEndpointArtifacts(endpoint) }
        var now: UInt64 = 0
        var spawnCount = 0
        var attemptsAfterSpawn = 0
        var peerDescriptors: [Int32] = []
        defer { peerDescriptors.forEach { Darwin.close($0) } }

        let descriptor: Int32
        do {
            descriptor = try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: { _ in
                    guard spawnCount > 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    attemptsAfterSpawn += 1
                    guard attemptsAfterSpawn > 4 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    var descriptors = [Int32](repeating: -1, count: 2)
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    try HIDBroker.writeAll(Data("{\"ready\":true}\n".utf8), to: descriptors[1])
                    peerDescriptors.append(descriptors[1])
                    return descriptors[0]
                },
                spawner: { _ in spawnCount += 1 },
                sleeper: { _ in now += 3_000_000_000 },
                monotonicNow: { now }
            )
        } catch let error as HIDBrokerNotReadyError {
            Issue.record("Broker diagnostic: \(error.diagnosticDescription)")
            return
        }
        Darwin.close(descriptor)

        #expect(now > 2_000_000_000)
        #expect(spawnCount == 1)
    }

    @Test("A peer trickling one byte at a time cannot stretch a read past its one deadline")
    func tricklingPeerTimesOut() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[0]) }
        let writer = descriptors[1]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { Darwin.close(writer); done.signal() }
            var byte: UInt8 = 0x20
            for _ in 0..<10 {
                guard Darwin.write(writer, &byte, 1) == 1 else { return }
                usleep(100_000)
            }
        }
        let start = Date()
        #expect(throws: CLIError.self) { try HIDBroker.readMessage(from: descriptors[0], withinMilliseconds: 500) }
        #expect(Date().timeIntervalSince(start) < 1.5)
        done.wait()
    }

    @Test("Brokers drop core dumps entirely and lower, never raise, the open-file limit to 256")
    func brokerLimits() {
        let generous = BrokerLimits.limits(currentFiles: rlimit(rlim_cur: 10_240, rlim_max: rlim_t.max))
        #expect(generous.core.rlim_cur == 0 && generous.core.rlim_max == 0)
        #expect(generous.files.rlim_cur == 256)
        #expect(generous.files.rlim_max == rlim_t.max)
        #expect(BrokerLimits.limits(currentFiles: rlimit(rlim_cur: 128, rlim_max: 128)).files.rlim_cur == 128)
    }

    @Test("Handshake failures preserve diagnostics without exposing them to users")
    func handshakeDiagnosticsRemainInternal() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        try HIDBroker.writeAll(Data("not-json\n".utf8), to: descriptors[1])

        do {
            _ = try HIDBroker.connectAndAwaitHandshake(
                endpoint: "unused",
                connector: { _ in descriptors[0] }
            )
            Issue.record("An invalid handshake should fail")
        } catch let error as HIDBrokerNotReadyError {
            #expect(error.diagnosticDescription.contains("readiness handshake failed"))
            #expect(!error.userFacingDescription.contains("JSON"))
            #expect(!error.isSafeToReplaceBroker)
            #expect(error.allowsReplacementAfterProcessExit)
        }
    }

    private func makeEndpoint() throws -> String {
        try HIDBroker.endpointPath(
            simulatorUDID: UUID().uuidString,
            developerDirectory: FileManager.default.temporaryDirectory.path
        )
    }

    private func removeEndpointArtifacts(_ endpoint: String) {
        try? HIDBroker.removeOwnedSocket(endpoint)
        try? FileManager.default.removeItem(atPath: endpoint + ".lock")
        try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock")
    }
}
