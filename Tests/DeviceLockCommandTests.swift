import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Device lock commands")
struct DeviceLockCommandTests {
    /// Holds the lock the CLI resolves for a random simulator UDID, as another Offsider process would.
    private func holdRandomSimulator(command: String = "batch") async throws -> (udid: String, lock: DeviceLock) {
        let udid = UUID().uuidString
        let lock = try await DeviceLock.acquire(DeviceLockKey(platform: .ios, id: udid), command: command, wait: nil)
        return (udid, lock)
    }

    @Test("an input command on a held device exits 8, names the holder and reports device_busy in JSON")
    func inputCommandOnHeldDevice() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        defer { lock.release() }

        let result = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1 --verify --json --device \(udid)")
        #expect(result.exitCode == 8)
        #expect(result.stderr.contains("is in use by pid \(getpid()) (offsider batch"))
        let report = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let error = report?["error"] as? [String: Any]
        #expect(report?["exitCode"] as? Int == 8)
        #expect(error?["reason"] as? String == "device_busy")
        #expect(error?["dispatched"] as? String == "no")
    }

    @Test("agents with different TMPDIR values share one device lock")
    func sharedAcrossTMPDIR() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        defer { lock.release() }
        let sandbox = "/private/tmp/offsider-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        let result = try await TestHelpers.runOffsiderCommandSeparated("swipe --start-x 1 --start-y 1 --end-x 2 --end-y 2 --device \(udid)", environment: ["TMPDIR": sandbox])
        #expect(result.exitCode == 8)
    }

    @Test("--wait-lock proceeds once the holder releases")
    func waitLockProceeds() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            lock.release()
        }
        // Past the lock, the random UDID is not a simulator, so the command reaches device lookup.
        let result = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1 --wait-lock 30 --device \(udid)")
        #expect(result.exitCode == 7)
    }

    @Test("OFFSIDER_WAIT_LOCK sets the wait when --wait-lock is absent")
    func environmentWait() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            lock.release()
        }
        let result = try await TestHelpers.runOffsiderCommandSeparated("key 4 --device \(udid)", environment: ["OFFSIDER_WAIT_LOCK": "30"])
        #expect(result.exitCode == 7)
    }

    @Test("reads on a held iOS device never lock")
    func readsDoNotLock() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        defer { lock.release() }
        for command in ["describe-ui", "screenshot --output /dev/null", "orientation", "appearance", "content-size"] {
            let result = try await TestHelpers.runOffsiderCommandSeparated("\(command) --device \(udid)")
            #expect(result.exitCode == 7, "\(command): \(result.stderr)")
        }
    }

    @Test("setting a value on a held device exits 8")
    func settersLock() async throws {
        let (udid, lock) = try await holdRandomSimulator()
        defer { lock.release() }
        for command in ["orientation landscape-left", "appearance dark", "content-size large"] {
            let result = try await TestHelpers.runOffsiderCommandSeparated("\(command) --device \(udid)")
            #expect(result.exitCode == 8, "\(command): \(result.stderr)")
        }
    }

    @Test("--wait-lock outside 0 to 600 is a usage error, and batch steps cannot take it")
    func waitLockValidation() async throws {
        let udid = UUID().uuidString
        let tooLong = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1 --wait-lock 601 --device \(udid)")
        #expect(tooLong.exitCode == 64)
        #expect(throws: (any Error).self) { try BatchStepParser.rejectPerStepDevice(["-x", "1", "--wait-lock", "5"]) }
    }
}

@Suite("Device claims")
@MainActor
struct DeviceClaimsTests {
    private func claims(root: String) -> DeviceClaims {
        let claims = DeviceClaims()
        claims.root = { root }
        claims.environment = [:]
        claims.configure(command: "batch", waitOption: nil)
        return claims
    }

    @Test("a batch's steps and the Android helper reuse the command's claim instead of locking again")
    func reentrant() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = claims(root: root)
        let key = DeviceLockKey(platform: .android, id: "emulator-5554")

        try await claims.claim(key)
        try await claims.claim(key)
        try await claims.claim(DeviceID(rawValue: "emulator-5554", platform: .android))
        #expect(claims.heldKeys == [key])

        let other = self.claims(root: root)
        await #expect(throws: DeviceBusy.self) { try await other.claim(key) }

        claims.releaseAll()
        try await other.claim(key)
        other.releaseAll()
    }

    @Test("closing the command's backends releases its claims afterwards")
    func scopeReleases() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = claims(root: root)
        let scope = CommandScope(claims: claims)
        try await scope.run {
            try await claims.claim(DeviceLockKey(platform: .ios, id: UUID().uuidString))
            #expect(claims.heldKeys.count == 1)
        }
        #expect(claims.heldKeys.isEmpty)
    }

    @Test("--wait-lock wins over OFFSIDER_WAIT_LOCK, and a bad variable is a usage error")
    func waitResolution() throws {
        #expect(try DeviceClaims.resolveWait(option: 2, environment: ["OFFSIDER_WAIT_LOCK": "30"]) == .seconds(2))
        #expect(try DeviceClaims.resolveWait(option: nil, environment: ["OFFSIDER_WAIT_LOCK": "30"]) == .seconds(30))
        #expect(try DeviceClaims.resolveWait(option: nil, environment: [:]) == nil)
        #expect(throws: CLIError.self) { try DeviceClaims.resolveWait(option: nil, environment: ["OFFSIDER_WAIT_LOCK": "soon"]) }
    }
}
