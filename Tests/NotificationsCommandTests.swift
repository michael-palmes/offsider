import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

@Suite("notifications command")
struct NotificationsCommandTests {
    static let phone = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)

    @MainActor
    static func route(allowance: DeviceAllowance?) -> DeviceRouter.Route {
        DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: Self.phone, allowance: allowance)
    }

    static func gate(_ allowance: DeviceAllowance) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance])), now: PolicyFixtures.now)
    }

    @Test("the app is --app, else offsider.login.json's package, else a phone's only pinned app")
    @MainActor
    func appFallbacks() throws {
        let pinned = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.pinned"])
        #expect(try NotificationsCommand.app(nil, route: Self.route(allowance: pinned), gate: Self.gate(pinned), profile: { nil }) == "com.example.pinned")
        #expect(try NotificationsCommand.app(nil, route: Self.route(allowance: nil), profile: { LoginProfile(package: "com.example.android") }) == "com.example.android")
        let error = #expect(throws: CLIError.self) { try NotificationsCommand.app(nil, route: Self.route(allowance: nil), profile: { nil }) }
        #expect(error?.reason == .usage)
    }

    @Test("a phone allowed for any app refuses another app's notifications from a messages or system app", arguments: ["com.google.android.apps.messaging", "com.android.systemui", "com.google.android.gm", " com.android.chrome", "com.google.android.gm "])
    @MainActor
    func anyAppPhoneRefusesDenyList(_ app: String) {
        let any = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: [])
        let error = #expect(throws: CLIError.self) { try NotificationsCommand.app(app, route: Self.route(allowance: any), gate: Self.gate(any), profile: { nil }) }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("a broken offsider.login.json exits 64, not a fall through to the pin")
    @MainActor
    func brokenProfileRefuses() {
        let pinned = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.pinned"])
        let error = #expect(throws: CLIError.self) {
            try NotificationsCommand.app(nil, route: Self.route(allowance: pinned), gate: Self.gate(pinned), profile: { throw CLIError(errorDescription: "broken", reason: .usage) })
        }
        #expect(error?.reason == .usage)
    }

    @Test("a phone pinned to one app refuses another app's notifications")
    @MainActor
    func pinnedPhoneRefusesOtherApp() {
        let pinned = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.pinned"])
        let error = #expect(throws: CLIError.self) { try NotificationsCommand.app("com.example.other", route: Self.route(allowance: pinned), gate: Self.gate(pinned), profile: { nil }) }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("an iOS device is refused as not_supported before anything is routed")
    func iOSRefused() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("notifications --app com.example.app --device 00000000-0000-0000-0000-000000000001")
        #expect(result.exitCode == 1)
        #expect(result.output.contains("Android only"))
    }

    @Test("--timeout needs --wait and 1 to 600 s, and --wait needs text", arguments: ["--timeout 5", "--wait x --timeout 0", "--wait ' '"])
    func optionRules(_ options: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("notifications --app com.example.app \(options) --device 00000000-0000-0000-0000-000000000001")
        #expect(result.exitCode == 64)
    }

    static func snapshot(_ titles: String...) -> NotificationSnapshot {
        NotificationSnapshot(notifications: titles.map { PostedNotification(key: $0, title: $0) }, source: .keys)
    }

    /// Reads in order, the last one for good, counting them.
    final class Reads: @unchecked Sendable {
        private(set) var count = 0
        private let script: [NotificationSnapshot]
        init(_ script: [NotificationSnapshot]) { self.script = script }
        func next() -> NotificationSnapshot {
            defer { count += 1 }
            return script[min(count, script.count - 1)]
        }
    }

    static func wait(for text: String, new: Bool, mask: TreeValueMask = .none, timeout: Duration, reads: Reads) async throws -> [String?] {
        let clock = ContinuousClock()
        let (_, listed) = try await NotificationsCommand.poll(wait: text, new: new, mask: mask, until: clock.now + timeout, clock: clock, read: { reads.next() }) { _ in
            CLIError(errorDescription: "gave up", reason: .conditionNotMet)
        }
        return listed.map(\.notification.title)
    }

    @Test("--new --timeout 1 can succeed: the first read is the baseline and the deadline gets a read of its own")
    func newWithOneSecond() async throws {
        let reads = Reads([Self.snapshot(), Self.snapshot("Order filled")])
        #expect(try await Self.wait(for: "order", new: true, timeout: .seconds(1), reads: reads) == ["Order filled"])
        #expect(reads.count == 2)
    }

    @Test("a push at the last moment is seen: a wait runs its whole timeout and reads again at its end")
    func runsItsWholeTimeout() async throws {
        let reads = Reads([Self.snapshot()])
        let started = ContinuousClock.now
        await #expect(throws: CLIError.self) { _ = try await Self.wait(for: "order", new: false, timeout: .seconds(1.5), reads: reads) }
        let took = ContinuousClock.now - started
        #expect(took >= .seconds(1.5), "\(took)")
        #expect(reads.count == 3)
    }

    @Test("--wait matches the masked text, so it cannot test for a value offsider.mask.json hides, and a list reads masked too")
    func waitAppliesTheMask() async throws {
        let mask = TreeValueMask(patterns: [try MaskPlan.compile(#"rc-\d{4}"#)])
        let posted = Reads([Self.snapshot("Code rc-5521")])
        await #expect(throws: CLIError.self) { _ = try await Self.wait(for: "rc-5521", new: false, mask: mask, timeout: .seconds(1), reads: posted) }
        #expect(try await Self.wait(for: "code", new: false, mask: mask, timeout: .seconds(1), reads: Reads([Self.snapshot("Code rc-5521")])) == ["Code [redacted]"])

        let clock = ContinuousClock()
        let (_, listed) = try await NotificationsCommand.poll(wait: nil, new: false, mask: mask, until: clock.now, clock: clock, read: { Self.snapshot("Code rc-5521") }) { _ in CLIError(errorDescription: "no") }
        #expect(listed.first?.notification.title == "Code [redacted]")
        #expect(listed.first?.count == 1)
    }

    @Test("without --wait there is one read and no sleep")
    func listReadsOnce() async throws {
        let reads = Reads([Self.snapshot("A")])
        let clock = ContinuousClock()
        let (_, listed) = try await NotificationsCommand.poll(wait: nil, new: false, mask: .none, until: clock.now, clock: clock, read: { reads.next() }) { _ in CLIError(errorDescription: "no") }
        #expect(listed.count == 1 && reads.count == 1)
    }
}
