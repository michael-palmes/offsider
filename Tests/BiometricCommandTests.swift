import ArgumentParser
import Foundation
@testable import OffsiderCore
import Testing
@testable import Offsider

@Suite("Biometric command")
@MainActor
struct BiometricCommandTests {
    static let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    static func claims() -> DeviceClaims {
        let claims = DeviceClaims()
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-biometric-\(UUID().uuidString)")
        claims.root = { root }
        return claims
    }

    static func perform(_ action: BiometricAction, on device: DeviceID, backend: FakeDeviceBackend, claims: DeviceClaims? = nil) async throws -> String {
        let claims = claims ?? Self.claims()
        let (_, console) = DevicePersonOutputTests.agent()
        return try await BiometricCommand.perform(
            action, modality: nil, fingerID: nil, json: true, on: DeviceRouter.Route(backend: backend, device: device), console: console, claims: claims
        ).output
    }

    @Test("on a phone, enrol, unenrol, match and no-match refuse with nothing sent and no lock taken", arguments: [BiometricAction.enrol, .unenrol, .match, .noMatch])
    func phoneRefusesInput(action: BiometricAction) async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let claims = Self.claims()
        let error = await #expect(throws: CLIError.self) { _ = try await Self.perform(action, on: Self.phone, backend: backend, claims: claims) }
        #expect(error?.reason == .notSupported)
        #expect(error?.errorDescription?.contains("offsider biometric status --device R58M123ABC") == true)
        #expect(backend.stateCalls.isEmpty)
        #expect(claims.heldKeys.isEmpty)
    }

    @Test("status on a phone reads enrolment without the device lock")
    func phoneStatus() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.biometricModality = .finger
        let claims = Self.claims()
        let output = try await Self.perform(.status, on: Self.phone, backend: backend, claims: claims)
        #expect(output == #"{"version":1,"action":"status","device":"R58M123ABC","platform":"android","modality":"finger","enrolled":true,"sent":null}"#)
        #expect(backend.stateCalls == ["biometric read"])
        #expect(claims.heldKeys.isEmpty)
    }

    @Test("an emulator match still takes the device lock")
    func emulatorMatchLocks() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let claims = Self.claims()
        defer { claims.releaseAll() }
        _ = try await Self.perform(.match, on: Self.emulator, backend: backend, claims: claims)
        #expect(claims.heldKeys == [DeviceLockKey(platform: .android, id: "emulator-5554")])
        #expect(backend.stateCalls.contains("biometric match face"))
    }

    @Test("status leaves the tree cache alone while every other action counts as input")
    func effects() throws {
        #expect(try BiometricCommand.parse(["status", "--device", "emulator-5554"]).effect == .none)
        for action in ["enrol", "enroll", "unenrol", "match", "no-match"] {
            #expect(try BiometricCommand.parse([action, "--device", "emulator-5554"]).effect == .input, "\(action)")
        }
        #expect(CommandEffect.of(try BiometricCommand.parse(["status", "--device", "emulator-5554"]), path: "biometric") == .none)
        #expect(CommandEffect.of(try Tap.parse(["--device", "emulator-5554", "-x", "1", "-y", "2"]), path: "tap") == .input)
    }

    @Test("the audit record names the action word, and only a known command's")
    func auditedAction() throws {
        #expect(try BiometricCommand.parse(["enroll", "--device", "emulator-5554"]).auditedAction == "enrol")
        #expect(AuditTrail.command("biometric", action: "status") == "biometric status")
        #expect(AuditTrail.command("biometric", action: "no-match") == "biometric no-match")
        #expect(AuditTrail.liveStamp(command: "biometric", action: "status").command == "biometric status")
        #expect(AuditTrail.command("hunter2", action: "status") == nil)
        #expect(AuditTrail.command(nil, action: "status") == nil)
    }

    // MARK: Evidence

    @Test("every action is a line with no file in the run, carrying what enrolment read; a refusal keeps its exit and reason")
    func manifestLines() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.biometricEnrolment = false

        try await fixture.command(fixture.recorder("biometric", arguments: ["status", "--device", "R58M123ABC"])) {
            _ = try await Self.perform(.status, on: Self.phone, backend: backend)
        }
        let status = try #require(fixture.manifest().last)
        #expect(status.command == "biometric" && status.file == nil && status.n == nil && status.exit == 0)
        #expect(status.enrolled == false && status.device == "R58M123ABC" && status.args == ["status", "--device", "R58M123ABC"])

        let claims = Self.claims()
        defer { claims.releaseAll() }
        try await fixture.command(fixture.recorder("biometric", arguments: ["match", "--device", "emulator-5554"])) {
            _ = try await Self.perform(.match, on: Self.emulator, backend: backend, claims: claims)
        }
        #expect(try #require(fixture.manifest().last).exit == 0)

        await #expect(throws: CLIError.self) {
            try await fixture.command(fixture.recorder("biometric", arguments: ["match", "--device", "R58M123ABC"])) {
                _ = try await Self.perform(.match, on: Self.phone, backend: backend)
            }
        }
        let refused = try #require(fixture.manifest().last)
        #expect(refused.exit == 1 && refused.reason == "not_supported" && refused.enrolled == nil)
        #expect(fixture.manifest().count == 3)
        #expect(EvidenceRecorder.records("biometric"))
    }

    @Test("an iOS simulator's enrol is recorded too, with the state it set")
    func simulatorLine() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = FakeDeviceBackend(platform: .ios, trees: [])
        let claims = Self.claims()
        defer { claims.releaseAll() }
        try await fixture.command(fixture.recorder("biometric", arguments: ["enrol", "--device", Self.simulator.rawValue])) {
            _ = try await Self.perform(.enrol, on: Self.simulator, backend: backend, claims: claims)
        }
        let line = try #require(fixture.manifest().last)
        #expect(line.platform == "ios" && line.enrolled == true && line.file == nil)
    }

    @Test("the timeline names the action and what enrolment read")
    func timelineNotes() {
        let line = RunManifestLine(command: "biometric", device: "R58M123ABC", time: Date(timeIntervalSince1970: 0), ms: 40, exit: 0, args: ["status", "--device", "R58M123ABC"], enrolled: true)
        let timeline = RunTimeline(dir: "/tmp/run", state: RunState(label: nil, startedAt: Date(timeIntervalSince1970: 0)), entries: [line], unrecorded: [])
        #expect(timeline.notes(for: line) == ["status", "enrolled"])
        var reordered = line
        reordered.args = ["--device", "R58M123ABC", "no-match"]
        reordered.enrolled = nil
        #expect(timeline.notes(for: reordered) == ["no-match"])
        #expect(line.jsonLine().hasSuffix(#","enrolled":true}"#))
    }
}
