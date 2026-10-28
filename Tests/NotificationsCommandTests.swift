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

    @Test("a phone allowed for any app refuses another app's notifications from a messages or system app", arguments: ["com.google.android.apps.messaging", "com.android.systemui", "com.google.android.gm"])
    @MainActor
    func anyAppPhoneRefusesDenyList(_ app: String) {
        let any = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: [])
        let error = #expect(throws: CLIError.self) { try NotificationsCommand.app(app, route: Self.route(allowance: any), gate: Self.gate(any), profile: { nil }) }
        #expect(error?.reason == .appNotAllowed)
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
}
