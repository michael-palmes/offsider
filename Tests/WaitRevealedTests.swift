import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("wait --settled and revealed password fields")
@MainActor
struct WaitRevealedTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let field = SecureFieldRecord.Entry(id: "password-field", frame: FakeUI.frame(16, 270, 361, 44))

    /// A sign-in screen with its password field shown as plain text, and a masked balance row.
    static func screen(password: String = "hunter22") -> UITree {
        FakeUI.tree([
            FakeUI.node(.textField, id: "password-field", label: "Password", value: password, frame: field.frame),
            FakeUI.node(.text, id: "balance", label: "Balance", value: "$12", frame: FakeUI.frame(16, 330, 361, 44)),
        ])
    }

    static func revealed(_ fixture: TreeCacheFixture) throws -> RevealedSecrets {
        let record = SecureFieldRecord(platform: .ios, device: device.rawValue, writtenAt: fixture.now, bootMarker: nil, entries: [field])
        try OffsiderPrivateDirectory.writeAtomically(
            record.encoded(), named: SecureFieldRecord.fileName(platform: .ios, device: device.rawValue), in: fixture.directory
        )
        return RevealedSecrets(record)
    }

    static func wait(on backend: FakeDeviceBackend, timeout: Int = 3) async throws -> WaitOutcome {
        try await Wait.parse(["--settled", "--timeout", "\(timeout)", "--device", device.rawValue])
            .evaluate(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger(), clock: ScriptedClock().poll)
    }

    @Test("a timeout while a revealed password field's text changes names the field, never its text, in the line and the JSON")
    func changeMessageHidesRevealedText() async throws {
        let fixture = try TreeCacheFixture()
        _ = try Self.revealed(fixture)
        let backend = FakeDeviceBackend(trees: (1...20).map { Self.screen(password: "hunter" + String(repeating: "2", count: $0)) })

        let outcome = try await fixture.run { try await Self.wait(on: backend) }

        #expect(!outcome.met)
        #expect(outcome.reason.contains("value of password-field changed"), "\(outcome.reason)")
        let command = try Wait.parse(["--settled", "--device", Self.device.rawValue])
        for shown in [outcome.reason, command.failureLine(outcome), WaitReport(Wait.shown(outcome)).jsonLine()] {
            #expect(!shown.contains("hunter"), "\(shown)")
        }
    }

    @Test("a revealed password field the cache stored masked is no effect of the last input, so the gate holds for its 2 s")
    func gateComparesRevealedAlike() async throws {
        let fixture = try TreeCacheFixture()
        let secrets = try Self.revealed(fixture)
        let record = TreeCacheRecord(
            platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: fixture.now,
            treeReadAt: fixture.now.addingTimeInterval(-0.2), lastInputAt: fixture.now.addingTimeInterval(-0.1), treeRole: .preAction,
            roots: Self.screen().redacted(TreeValueMask(revealed: secrets), scope: .cache).roots
        )
        try OffsiderPrivateDirectory.writeAtomically(
            record.encoded(), named: TreeCacheRecord.fileName(platform: .ios, device: Self.device.rawValue), in: fixture.directory
        )

        let outcome = try await fixture.run { try await Self.wait(on: FakeDeviceBackend(trees: [Self.screen()])) }

        #expect(outcome.met)
        #expect(outcome.elapsed >= 1.9, "the gate opened after \(outcome.elapsed) s, before the input's time was up")
    }

    @Test("a batch's own read from before its input is masked like the cache's, so neither a revealed field nor a masked row opens the gate")
    func batchGateComparesAlike() async throws {
        let fixture = try TreeCacheFixture()
        _ = try Self.revealed(fixture)
        let backend = FakeDeviceBackend(trees: [Self.screen()])
        let mask = TreeValueMask(ids: ["balance"])

        let outcome = try await OutputMasks.$current.withValue(OutputMasks { mask }) {
            try await fixture.run {
                let ledger = DeviceActivityLedger.current
                ledger.recordTreeRead(Self.screen(), on: Self.device, startedAt: fixture.now)
                fixture.now = fixture.now.addingTimeInterval(0.1)
                ledger.recordInput(on: Self.device)
                return try await Self.wait(on: backend)
            }
        }

        #expect(outcome.met)
        #expect(outcome.elapsed >= 1.9, "the gate opened after \(outcome.elapsed) s, before the input's time was up")
    }

    @Test("a real change still opens the gate at once, with a revealed field on screen")
    func gateStillSeesTheEffect() async throws {
        let fixture = try TreeCacheFixture()
        let secrets = try Self.revealed(fixture)
        let record = TreeCacheRecord(
            platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: fixture.now,
            treeReadAt: fixture.now.addingTimeInterval(-0.2), lastInputAt: fixture.now.addingTimeInterval(-0.1), treeRole: .preAction,
            roots: Self.screen().redacted(TreeValueMask(revealed: secrets), scope: .cache).roots
        )
        try OffsiderPrivateDirectory.writeAtomically(
            record.encoded(), named: TreeCacheRecord.fileName(platform: .ios, device: Self.device.rawValue), in: fixture.directory
        )
        let pushed = FakeUI.tree([FakeUI.node(.header, id: "detail", label: "Detail", frame: FakeUI.frame(0, 60, 402, 44))])

        let outcome = try await fixture.run { try await Self.wait(on: FakeDeviceBackend(trees: [pushed])) }

        #expect(outcome.met)
        #expect(outcome.elapsed < 1)
    }
}
