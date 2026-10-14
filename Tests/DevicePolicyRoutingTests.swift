import Foundation
@testable import Offsider
@testable import OffsiderAndroid
@testable import OffsiderCore
import OffsiderIOSDevice
import Testing

@Suite("Physical device gate in the router", .serialized)
@MainActor
struct DevicePolicyRoutingTests {
    static let phone = PolicyFixtures.phone
    static let simulator = "ABCDEF00-0000-4000-8000-00000000ABCD"

    static func gate(_ entries: [DeviceAllowance], managed: ManagedDevicePolicy = .none) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: entries)), now: PolicyFixtures.now)
    }

    static func route(_ id: String, gate: DevicePolicyGate, scope: CommandScope = CommandScope(), host: AndroidHost = .cli()) async throws -> DeviceRouter.Route {
        try await DevicePolicyGate.$current.withValue(gate) {
            try await DeviceRouter.route(id, logger: OffsiderLogger(), host: host, scope: scope)
        }
    }

    @Test("an iPhone no one allowed is refused with exit 7 before any backend exists, so devicectl is never asked")
    func iPhoneRefusedFirst() async throws {
        let scope = CommandScope()
        let error = await #expect(throws: CLIError.self) { _ = try await Self.route(Self.phone, gate: Self.gate([]), scope: scope) }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(error?.exitCode == .deviceUnavailable)
        #expect(error?.userFacingDescription.contains("Ask the user to run `offsider device-access allow --device \(Self.phone)` in their own terminal") == true)
        #expect(scope.adopted.isEmpty)
        #expect(scope.routes.isEmpty)
    }

    @Test("managed policy refuses even a device the person allowed, and names no allow command")
    func managedRefusal() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.route(Self.phone, gate: Self.gate([PolicyFixtures.entry()], managed: ManagedDevicePolicy(allowPhysicalDevices: false)))
        }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(error?.hint == nil)
        #expect(error?.userFacingDescription.contains("administrator") == true)
    }

    @Test("an allowed iPhone routes with its allowance, and the banner prints once per device on stderr")
    func allowedRoutesWithBanner() async throws {
        let scope = CommandScope()
        var notes: [String] = []
        scope.bannerNote = { notes.append($0) }
        let gate = Self.gate([PolicyFixtures.entry(apps: ["com.mpalmes.offsider.playground"])])
        let first = try await Self.route(Self.phone.lowercased(), gate: gate, scope: scope)
        _ = try await Self.route(Self.phone, gate: gate, scope: scope)
        _ = try await Self.route(Self.simulator, gate: gate, scope: scope)

        #expect(first.backend is IOSDeviceBackend)
        #expect(first.allowance?.key == Self.phone)
        #expect(notes == [
            "Offsider: driving physical iPhone or iPad \"Test iPhone\" (\(Self.phone)), allowed until 2026-09-21T15:13:20Z for com.mpalmes.offsider.playground (managed policy: none). "
                + "offsider device-access remove --device \(Self.phone) withdraws it.",
        ])
    }

    @Test("a simulator never consults the policy")
    func simulatorSkipsPolicy() async throws {
        let gate = DevicePolicyGate(policy: { Issue.record("the policy was read for a simulator"); return PhysicalDevicePolicy(managed: .none, list: .empty) })
        let route = try await Self.route(Self.simulator, gate: gate)
        #expect(route.allowance == nil)
    }

    @Test("OFFSIDER_DEVICE naming an allowed physical device is refused: it needs --device")
    func environmentRefused() async throws {
        let resolved = DeviceDefault.$environment.withValue({ Self.phone }) { DeviceDefault.resolve(explicit: nil) }
        #expect(resolved?.source == .environment)
        defer { DeviceDefault.record(Self.phone, source: .option) }
        let error = await #expect(throws: CLIError.self) { _ = try await Self.route(Self.phone, gate: Self.gate([PolicyFixtures.entry()])) }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.contains("must be named with --device") == true)

        _ = DeviceDefault.resolve(explicit: Self.phone)
        _ = try await Self.route(Self.phone, gate: Self.gate([PolicyFixtures.entry()]))
    }

    static func phoneServer(_ listing: String) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            [],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: listing)
                default: return .hang
                }
            },
            device: { _, _ in .hang }
        ))
    }

    @Test("a USB phone named by serial is refused from the host-side device list alone; nothing is sent to it")
    func androidPhoneRefused() async throws {
        let server = Self.phoneServer("R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n")
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        let error = await #expect(throws: CLIError.self) { _ = try await Self.route("R58M123ABC", gate: Self.gate([]), host: host) }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(server.requests.allSatisfy { $0.serial == nil && !$0.service.contains("R58M123ABC") })

        let allowed = try await Self.route("R58M123ABC", gate: Self.gate([PolicyFixtures.entry(.android, key: "R58M123ABC")]), host: host)
        #expect(allowed.allowance?.platform == .android)
    }

    @Test("a USB device reporting an emulator serial is refused")
    func spoofedEmulatorSerial() async throws {
        let server = Self.phoneServer("emulator-5554 device usb:1-1 model:Pixel_9 transport_id:2\n")
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        let error = await #expect(throws: CLIError.self) { _ = try await Self.route("emulator-5554", gate: Self.gate([]), host: host) }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(error?.userFacingDescription.contains("reporting an emulator's serial") == true)
        #expect(server.requests.allSatisfy { $0.serial == nil })
    }
}

@Suite("list-devices and the allow-list")
struct ListDevicesPolicyTests {
    static let emulator = DeviceSummary(id: "emulator-5554", platform: .android, state: "Booted", name: "Offsider_E2E", osVersion: nil, deviceType: nil, kind: .emulator)
    static let phone = DeviceSummary(id: "R58M123ABC", platform: .android, state: "Booted", name: "Pixel 9", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
    static let iPhone = DeviceSummary(id: PolicyFixtures.phone, platform: .ios, state: "Booted", name: "Test iPhone", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
    static let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [PolicyFixtures.entry()])), now: PolicyFixtures.now)

    @Test("physical devices no one allowed are hidden and counted; an allowed one shows, marked allowed")
    func hidesUnallowed() throws {
        let (shown, hidden) = ListDevices.applyPolicy([Self.emulator, Self.phone, Self.iPhone], physicalOnly: false, gate: Self.gate)
        #expect(shown.map(\.id) == [Self.emulator.id, PolicyFixtures.phone])
        #expect(hidden == 1)
        #expect(ListDevices.hiddenNote(hidden) == ["1 physical device is hidden because no one allowed Offsider to drive it; a person can list them with offsider list-devices --physical."])
        #expect(DeviceListRenderer.table(shown).contains("Test iPhone (allowed)"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceListRenderer.json(shown, hiddenPhysical: hidden).utf8)) as? [String: Any])
        #expect(object["hiddenPhysical"] as? Int == 1)
        let rows = try #require(object["devices"] as? [[String: Any]])
        #expect(rows[0]["allowed"] is NSNull)
        #expect(rows[1]["allowed"] as? Bool == true)
    }

    @Test("--physical lists every physical device, allowed or not, and nothing else")
    func physicalOnly() {
        let (shown, hidden) = ListDevices.applyPolicy([Self.emulator, Self.phone, Self.iPhone], physicalOnly: true, gate: Self.gate)
        #expect(shown.map(\.allowed) == [false, true])
        #expect(hidden == 0)
    }

    @Test("with no physical row the policy is never read")
    func noPhysicalNoPolicy() {
        let gate = DevicePolicyGate(policy: { Issue.record("policy read"); return PhysicalDevicePolicy(managed: .none, list: .empty) })
        #expect(ListDevices.applyPolicy([Self.emulator], physicalOnly: false, gate: gate).shown == [Self.emulator])
    }
}

@Suite("doctor device.policy")
@MainActor
struct DoctorDevicePolicyTests {
    @Test("only an iPhone UDID or a serial adb lists as a phone is physical; simulators and AVDs are not")
    func physicalTargets() async {
        #expect(await Doctor.physicalTarget(PolicyFixtures.phone.lowercased()) { _ in false }! == (.ios, PolicyFixtures.phone))
        #expect(await Doctor.physicalTarget("R58M123ABC") { $0 == "R58M123ABC" }! == (.android, "R58M123ABC"))
        #expect(await Doctor.physicalTarget("Offsider_E2E") { _ in false } == nil)
        #expect(await Doctor.physicalTarget("ABCDEF00-0000-4000-8000-00000000ABCD") { _ in true } == nil)
    }

    @Test("a device no one allowed gets one failing device.policy check naming the allow command, and a policy object")
    func refusedReport() throws {
        let decision = DevicePolicyGate.$current.withValue(DevicePolicyRoutingTests.gate([])) {
            Doctor.decision(platform: .ios, key: PolicyFixtures.phone, fromEnvironment: false)
        }
        let policy = DoctorPolicy(platform: .ios, key: PolicyFixtures.phone, decision: decision, managed: false)
        let report = Doctor.policyReport(policy, target: (.ios, PolicyFixtures.phone), source: .option)
        #expect(report.checks.map(\.id) == [.devicePolicy])
        #expect(report.checks[0].status == .fail)
        #expect(report.checks[0].hint == "Ask the user to run `offsider device-access allow --device \(PolicyFixtures.phone)` in their own terminal.")
        #expect(report.exitCode == .doctorFailures)
        let object = try #require(try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        let json = try #require(object["policy"] as? [String: Any])
        #expect(json["allowed"] as? Bool == false)
        #expect(json["refusal"] as? String == "not_allowed")
    }

    @Test("an allowed device passes device.policy, unless only OFFSIDER_DEVICE named it")
    func allowedAndEnvironment() {
        let gate = DevicePolicyRoutingTests.gate([PolicyFixtures.entry()])
        let (named, fromEnvironment) = DevicePolicyGate.$current.withValue(gate) {
            (Doctor.decision(platform: .ios, key: PolicyFixtures.phone, fromEnvironment: false),
             Doctor.decision(platform: .ios, key: PolicyFixtures.phone, fromEnvironment: true))
        }
        let pass = DoctorPolicy(platform: .ios, key: PolicyFixtures.phone, decision: named, managed: false).check
        #expect(pass.status == .pass)
        #expect(pass.detail == "\(PolicyFixtures.phone) is allowed until 2026-09-21T15:13:20Z")
        let refused = DoctorPolicy(platform: .ios, key: PolicyFixtures.phone, decision: fromEnvironment, managed: false)
        let report = Doctor.policyReport(refused, target: (.ios, PolicyFixtures.phone), source: .environment)
        #expect(report.checks[0].hint == "offsider doctor --device \(PolicyFixtures.phone)")
    }
}

@Suite("unlock-code on a phone")
@MainActor
struct UnlockCodePolicyTests {
    @Test("set on a phone no one allowed is refused before its label is read; status and remove skip the label instead")
    func gate() async throws {
        let refused = DevicePolicyRoutingTests.gate([])
        let error = await #expect(throws: CLIError.self) {
            _ = try await UnlockCodeCommand.gatePhone("R58M123ABC", rawID: "R58M123ABC", action: .set, gate: refused) { _ in true }
        }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(try await UnlockCodeCommand.gatePhone("R58M123ABC", rawID: "R58M123ABC", action: .status, gate: refused) { _ in true } == false)
        #expect(try await UnlockCodeCommand.gatePhone("Offsider_E2E", rawID: "Offsider_E2E", action: .set, gate: refused) { _ in false } == true)
        let allowed = DevicePolicyRoutingTests.gate([PolicyFixtures.entry(.android, key: "R58M123ABC")])
        #expect(try await UnlockCodeCommand.gatePhone("R58M123ABC", rawID: "R58M123ABC", action: .set, gate: allowed) { _ in true } == true)
    }
}
