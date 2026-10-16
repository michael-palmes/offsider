import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("HID Broker Reliability Tests")
struct HIDBrokerReliabilityTests {
    private final class Played: @unchecked Sendable {
        var touches: [(down: Bool, x: Double, y: Double)] = []
        var slept: Duration = .zero
    }

    @Test("A request is refused before anything is sent when it is too long, a delay is out of range or not finite, or the delays add up past 25 s", arguments: [
        Array(repeating: HIDBrokerPrimitive.delay(0), count: 4097),
        [HIDBrokerPrimitive.delay(10.5)],
        [HIDBrokerPrimitive.delay(-1)],
        [HIDBrokerPrimitive.delay(.nan)],
        [HIDBrokerPrimitive.delay(.infinity)],
        [HIDBrokerPrimitive.delay(10), .delay(10), .delay(6)],
        [HIDBrokerPrimitive(kind: .down, x: .nan, y: 1, duration: nil)],
        [HIDBrokerPrimitive(kind: .up, x: nil, y: 1, duration: nil)],
    ])
    func validateRefuses(primitives: [HIDBrokerPrimitive]) {
        let error = #expect(throws: CLIError.self) { try HIDBroker.validate(primitives) }
        #expect(error?.reason == .hidBrokerFailed)
    }

    @Test("A request at the limits passes validation")
    func validateAccepts() throws {
        try HIDBroker.validate(Array(repeating: .delay(0), count: 4096))
        try HIDBroker.validate([.touch(.down, x: 1, y: 2), .delay(10), .delay(10), .delay(5), .touch(.up, x: 1, y: 2)])
    }

    @Test("A client that goes away mid-delay ends the request within a slice and its held touch is lifted")
    func abandonedPeerLiftsTouch() async throws {
        let played = Played()
        var checks = 0
        let outcome = try await HIDBroker.play(
            [.touch(.down, x: 5, y: 6), .delay(10), .touch(.up, x: 5, y: 6)],
            peerGone: {
                checks += 1
                return checks > 3
            },
            touch: { direction, x, y in played.touches.append((direction == .down, x, y)) },
            sleep: { played.slept += $0 }
        )
        #expect(outcome == .abandoned)
        #expect(played.touches.map(\.down) == [true, false])
        #expect(played.touches.last.map { ($0.x, $0.y) } ?? (0, 0) == (5, 6))
        #expect(played.slept <= .milliseconds(300))
    }

    @Test("A completed request sleeps its delays in 100 ms slices and lifts nothing extra")
    func completedRequest() async throws {
        let played = Played()
        var slices: [Duration] = []
        let outcome = try await HIDBroker.play(
            [.touch(.down, x: 1, y: 1), .delay(0.25), .touch(.up, x: 1, y: 1)],
            peerGone: { false },
            touch: { direction, x, y in played.touches.append((direction == .down, x, y)) },
            sleep: { slices.append($0) }
        )
        #expect(outcome == .completed)
        #expect(played.touches.map(\.down) == [true, false])
        #expect(slices == [.milliseconds(100), .milliseconds(100), .milliseconds(50)])
    }

    @Test("A touch that fails after a contact went down still lifts it before the error is reported")
    func failureLiftsTouch() async throws {
        let played = Played()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await HIDBroker.play(
                [.touch(.down, x: 1, y: 1), .touch(.down, x: 2, y: 2)],
                peerGone: { false },
                touch: { direction, x, y in
                    if direction == .down, x == 2 { throw Boom() }
                    played.touches.append((direction == .down, x, y))
                },
                sleep: { _ in }
            )
        }
        #expect(played.touches.map(\.down) == [true, false])
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
