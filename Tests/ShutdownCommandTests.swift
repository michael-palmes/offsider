import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Shutdown command")
@MainActor
struct ShutdownCommandTests {
    static let step = Shutdown.Step(platform: .android, name: "Offsider_E2E", id: "emulator-5554", leaseKey: "Offsider_E2E", running: true)
    static let table = ProcessTable { _ in nil }

    /// What the stop did, in order.
    final class Calls {
        var made: [String] = []
    }

    private func stop(
        _ step: Shutdown.Step = step, label: String? = nil, environment: [String: String] = [:], root: String, claims: DeviceClaims = DeviceClaims(), calls: Calls,
        left: [DeviceSessionRow.Left] = [], recordingKept: Notice? = nil, deviceError: (any Error)? = nil
    ) async throws -> ShutdownReport {
        claims.root = { root }
        claims.environment = environment
        return try await Shutdown.stop(
            step, label: label, timeout: .seconds(5), claims: claims, store: DeviceLeaseStore(root: root), environment: environment,
            selfPID: getpid(), processes: Self.table,
            stopSessions: { device in
                calls.made.append("sessions \(device)")
                return ([DeviceSessionRow.Stopped(device: device, runner: false, broker: false, helper: true)], left, recordingKept)
            },
            stopDevice: {
                calls.made.append("device")
                if let deviceError { throw deviceError }
            }
        )
    }

    private func root() throws -> String {
        try makePrivateLockRoot()
    }

    @Test("sessions stop before the device, and --json says what stopped")
    func order() async throws {
        let calls = Calls()
        let report = try await stop(root: try root(), calls: calls)
        #expect(calls.made == ["sessions emulator-5554", "device"])
        #expect(report.jsonLine() == #"{"version":1,"ok":true,"platform":"android","name":"Offsider_E2E","id":"emulator-5554","alreadyOff":false,"sessions":["warm helper"],"notRemoved":[],"exitCode":0}"#)
        #expect(report.line == "Stopped Offsider_E2E (emulator-5554).\n")
    }

    @Test("a device already off succeeds, touching no sessions and reading no lease")
    func alreadyOff() async throws {
        let root = try root()
        let store = DeviceLeaseStore(root: root)
        let now = Date()
        _ = try store.set(platform: .android, key: "Offsider_E2E", now: now) { _ in DeviceLease(label: "someone else", created: now, expires: now.addingTimeInterval(600), pid: 1) }
        let calls = Calls()
        let off = Shutdown.Step(platform: .android, name: "Offsider_E2E", id: nil, leaseKey: "Offsider_E2E", running: false)

        let report = try await stop(off, root: root, calls: calls)

        #expect(calls.made.isEmpty)
        #expect(report.alreadyOff)
        #expect(report.jsonLine() == #"{"version":1,"ok":true,"platform":"android","name":"Offsider_E2E","id":null,"alreadyOff":true,"sessions":[],"notRemoved":[],"exitCode":0}"#)
        #expect(report.line == "Offsider_E2E was already off.\n")
    }

    @Test("another session's lease refuses, naming the holder, and nothing stops")
    func leased() async throws {
        let root = try root()
        let now = Date()
        _ = try DeviceLeaseStore(root: root).set(platform: .android, key: "Offsider_E2E", now: now) { _ in
            DeviceLease(label: "PR 123 review", created: now, expires: now.addingTimeInterval(600), pid: 1)
        }
        let calls = Calls()
        await #expect {
            try await stop(root: root, calls: calls)
        } throws: {
            let failure = $0 as? any OffsiderFailure
            return failure?.reason == .deviceLeased && failure?.reason.exitCode == .deviceBusy && "\($0)".contains("PR 123 review")
        }
        #expect(calls.made.isEmpty)
    }

    @Test("this session's lease does not refuse, by --label or OFFSIDER_LEASE")
    func ownLease() async throws {
        let root = try root()
        let now = Date()
        _ = try DeviceLeaseStore(root: root).set(platform: .android, key: "Offsider_E2E", now: now) { _ in
            DeviceLease(label: "mine", created: now, expires: now.addingTimeInterval(600), pid: 1)
        }
        let byLabel = Calls()
        _ = try await stop(label: "mine", root: root, calls: byLabel)
        #expect(byLabel.made.contains("device"))
        let byVariable = Calls()
        _ = try await stop(environment: [DeviceLeaseRules.sessionVariable: "mine"], root: root, calls: byVariable)
        #expect(byVariable.made.contains("device"))
    }

    @Test("a lease is read under the AVD's name, not the serial it runs on today")
    func leaseKey() async throws {
        let root = try root()
        let now = Date()
        _ = try DeviceLeaseStore(root: root).set(platform: .android, key: "emulator-5554", now: now) { _ in
            DeviceLease(label: "on the serial", created: now, expires: now.addingTimeInterval(600), pid: 1)
        }
        let calls = Calls()
        _ = try await stop(root: root, calls: calls)
        #expect(calls.made.contains("device"))
    }

    @Test("a command holding the device's lock refuses, naming it, and nothing stops")
    func locked() async throws {
        let root = try root()
        let holder = try await DeviceLock.acquire(DeviceLockKey(platform: .android, id: "emulator-5554"), command: "tap", wait: nil, root: root)
        defer { holder.release() }
        let calls = Calls()
        await #expect {
            try await stop(root: root, calls: calls)
        } throws: {
            ($0 as? DeviceBusy)?.reason == .deviceBusy && "\($0)".contains("offsider tap")
        }
        #expect(calls.made.isEmpty)
    }

    @Test("a lease set while waiting for the lock still refuses")
    func leaseSetDuringLockWait() async throws {
        let root = try root()
        let holder = try await DeviceLock.acquire(DeviceLockKey(platform: .android, id: "emulator-5554"), command: "tap", wait: nil, root: root)
        let calls = Calls()
        let now = Date()
        let claims = DeviceClaims()
        claims.waitOption = 5
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            _ = try? DeviceLeaseStore(root: root).set(platform: .android, key: "Offsider_E2E", now: now) { _ in
                DeviceLease(label: "arrived later", created: now, expires: now.addingTimeInterval(600), pid: 1)
            }
            holder.release()
        }
        await #expect {
            try await stop(root: root, claims: claims, calls: calls)
        } throws: { "\($0)".contains("arrived later") }
        #expect(calls.made.isEmpty)
    }

    @Test("a recording that will not stop keeps the device running, and says why")
    func recordingKept() async throws {
        let calls = Calls()
        await #expect {
            try await stop(root: try root(), calls: calls, recordingKept: .warning("The recording on emulator-5554 is still running."))
        } throws: {
            ($0 as? CLIError)?.reason == .deviceBusy && "\($0)".contains("still running")
        }
        #expect(calls.made == ["sessions emulator-5554"])
    }

    @Test("what the session stop could not undo is named, with the command that does, and the device still stops")
    func airplaneLeftOn() async throws {
        let calls = Calls()
        let report = try await stop(root: try root(), calls: calls, left: [DeviceSessionRow.Left(device: "emulator-5554", airplane: true, why: .failed)])
        #expect(calls.made == ["sessions emulator-5554", "device"])
        let sentence = try #require(report.notRemoved.first)
        #expect(sentence.contains("airplane mode") && sentence.contains("offsider session stop --device emulator-5554"))
        #expect(report.jsonLine().contains("\"notRemoved\":[\"Offsider could not remove the airplane mode"))
    }

    @Test("a stop that fails is the command's failure, not a report")
    func stopFails() async throws {
        let calls = Calls()
        await #expect {
            try await stop(root: try root(), calls: calls, deviceError: CLIError(errorDescription: "still running", reason: .shutdownTimedOut))
        } throws: { ($0 as? CLIError)?.reason == .shutdownTimedOut }
    }

    @Test("what only a phone can be named is refused by its shape", arguments: ["00008130-0000000000000ABC", "0123456789abcdef0123456789abcdef01234567", "10.0.0.5:5555"])
    func phoneShapes(name: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("shutdown \(name) --json")
        #expect(result.exitCode == 7, "stderr: \(result.stderr)")
        #expect(result.stdout.contains(#""reason":"device_not_allowed""#))
    }

    @Test("OFFSIDER_DEVICE never names what stops")
    func environmentAlone() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("shutdown --json", environment: ["OFFSIDER_DEVICE": "Offsider_E2E"])
        #expect(result.exitCode == 64, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("Missing expected argument"))
    }

    @Test("a simulator UDID no simulator has stops nothing and says so")
    func unknownSimulator() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("shutdown 00000000-0000-0000-0000-000000000001 --json")
        #expect(result.exitCode == 7, "stderr: \(result.stderr)")
        #expect(result.stdout.contains(#""reason":"device_not_found""#))
    }

    @Test("--device is answered with the argument form")
    func deviceOption() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("shutdown --device Offsider_E2E")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("offsider shutdown <name>"))
    }

    @Test("init's rules let an agent run it with no prompt")
    func noPrompt() {
        for rule in AgentPermissionRules.rules {
            let prefix = rule.claude.hasSuffix("*") ? String(rule.claude.dropLast()) : rule.claude
            #expect(!"offsider shutdown Offsider_E2E".hasPrefix(prefix), "\(rule.claude) gates shutdown")
        }
    }

    @Test("several simulators with one name are refused, each UDID named for the command that was run")
    func sharedName() {
        let twins = ["1", "2"].map { SimulatorBootCandidate(udid: "00000000-0000-0000-0000-00000000000\($0)", name: "Twin", state: "Booted", osVersion: "iOS 26.0") }
        #expect(SimulatorBootTarget.match("Twin", among: twins) == .several(twins))
        #expect(SimulatorBootTarget.ambiguity("Twin", twins, command: "shutdown").contains("Stop one by its UDID"))
        #expect(SimulatorBootTarget.ambiguity("Twin", twins).contains("Boot one by its UDID"))
    }

    @Test("a simulator in each state gets the right step", arguments: [("Shutdown", SimulatorShutdownStep.alreadyOff), ("Shutting Down", .waitForShutdown), ("Booted", .shutdown), ("Booting", .shutdown)])
    func simulatorSteps(state: String, step: SimulatorShutdownStep) {
        #expect(SimulatorShutdownStep.step(for: state) == step)
    }
}
