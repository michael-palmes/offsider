import ArgumentParser
import Foundation
@testable import Offsider
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("Pinned app on a physical iPhone")
@MainActor
struct IOSDevicePinningTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let playground = "com.mpalmes.offsider.playground"
    static let allowance = DeviceAllowance(platform: .ios, key: IOSDeviceFixtures.phone, name: "Test iPhone", added: Date(), expires: nil, apps: [playground])

    static func backend(_ transport: FakeRunnerTransport, onUSB: Bool = true, apps: [String] = [playground]) throws -> IOSDeviceBackend {
        var host = IOSDeviceHost.fake(
            try FakeDevicectl.listing("devicectl-list-xcode26.json"),
            usbmux: onUSB ? FakeUsbmuxListing.onUSB(IOSDeviceFixtures.phone) : FakeUsbmuxListing([])
        )
        host.runnerConnector = FakeRunnerConnector(transport: transport)
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("518.24") }
        let allowance = DeviceAllowance(platform: .ios, key: IOSDeviceFixtures.phone, name: "Test iPhone", added: Date(), expires: nil, apps: apps)
        let policy = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance]))
        IOSDevicePinning.configure(backend, allowance: allowance, policy: policy, profileBundleID: { nil })
        return backend
    }

    @Test("the pin is --app, else offsider.login.json's bundleId, else the allowance's only app")
    func defaultPin() {
        #expect(IOSDevicePinning.defaultPin(profile: "com.example.login", allowance: Self.allowance) == "com.example.login")
        #expect(IOSDevicePinning.defaultPin(profile: nil, allowance: Self.allowance) == Self.playground)
        let two = DeviceAllowance(platform: .ios, key: IOSDeviceFixtures.phone, name: "Test iPhone", added: Date(), expires: nil, apps: [Self.playground, "com.example.two"])
        #expect(IOSDevicePinning.defaultPin(profile: nil, allowance: two) == nil)
    }

    @Test("with no app named the command is a usage error (exit 64) and nothing reaches the runner")
    func noPinIsUsage() async throws {
        let transport = FakeRunnerTransport()
        let backend = try Self.backend(transport, apps: [])
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.requirePinnedAppInFront(Self.phone) }
        #expect(error?.reason == .usage)
        #expect(error?.message.contains("Pass --app <bundle-id>") == true)
        #expect(transport.calls.isEmpty)
    }

    @Test("a batch's --app counts before its input session opens, so a phone with no pinned app takes the batch, and without it nothing is sent")
    func batchAppBeforeSession() async throws {
        let transport = FakeRunnerTransport()
        transport.foregroundApp = Self.playground
        let backend = try Self.backend(transport, apps: [Self.playground, "com.example.two"])
        let route = DeviceRouter.Route(backend: backend, device: Self.phone)

        let unnamed = try Batch.parse(["--device", IOSDeviceFixtures.phone, "--no-settle", "--step", "tap -x 10 -y 20"])
        let error = await #expect(throws: IOSDeviceError.self) { try await unnamed.run(on: route, logger: OffsiderLogger()) }
        #expect(error?.reason == .usage)
        #expect(!transport.calls.contains { $0.path == "/tap-point" })

        let named = try Batch.parse(["--device", IOSDeviceFixtures.phone, "--app", Self.playground, "--no-settle", "--step", "tap -x 10 -y 20"])
        try await named.run(on: route, logger: OffsiderLogger())
        #expect(transport.calls.last?.path == "/tap-point")
        #expect(transport.calls.last?.body["app"] == AnyHashable(Self.playground))
    }

    @Test("rn tools off on a phone with no app named says to pass --app, not that the screen cannot be read")
    func rnToolsOffNamesTheApp() async throws {
        let transport = FakeRunnerTransport()
        let backend = try Self.backend(transport, apps: [])
        let route = DeviceRouter.Route(backend: backend, device: Self.phone)
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await RNToolsOff.parse(["--device", IOSDeviceFixtures.phone]).turnOff(on: route, clock: .live)
        }
        #expect(error?.reason == .usage)
        #expect(error?.message.contains("Pass --app <bundle-id>") == true)
    }

    /// Commands with `--device` that never read or drive a phone's screen: refused on a phone, a setting, or their own `--app`.
    static let noScreenOnPhone: Set<String> = [
        "device-session serve", "android-session serve", "doctor", "logs", "displays", "shake", "login", "credential", "rn prepare", "rn open",
        "orientation", "posture", "appearance", "content-size", "permission", "status-bar", "biometric", "stay-awake", "wake", "unlock-code",
        "device-access allow", "device-access status", "device-access remove", "runner status", "runner build", "runner stop",
        "session status", "session stop", "lease",
    ]

    @Test("every command with --device takes --app unless it never reads or drives a phone's screen, as the refusal without one says")
    func appOptionOnEveryPhoneCommand() {
        func leaves(_ command: any ParsableCommand.Type, path: [String]) -> [(String, any ParsableCommand.Type)] {
            let name = path + [command._commandName]
            let children = command.configuration.subcommands
            return children.isEmpty ? [(name.dropFirst().joined(separator: " "), command)] : children.flatMap { leaves($0, path: name) }
        }
        let missing = leaves(OffsiderCommand.self, path: []).filter { name, command in
            let help = command.helpMessage(columns: 400)
            return help.contains("\n  --device <") && !help.contains("--app <bundle-id>") && !Self.noScreenOnPhone.contains(name)
        }.map(\.0)
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test("a deny-listed or unpinned app is app_not_allowed before the runner is asked")
    func refusedApps() async throws {
        let transport = FakeRunnerTransport()
        let backend = try Self.backend(transport)
        backend.targetApp = "com.apple.mobilesafari"
        let browser = await #expect(throws: IOSDeviceError.self) { try await backend.requirePinnedAppInFront(Self.phone) }
        #expect(browser?.reason == .appNotAllowed)
        backend.targetApp = "com.example.other"
        let other = await #expect(throws: IOSDeviceError.self) { _ = try await backend.rawAccessibilitySource(for: Self.phone) }
        #expect(other?.reason == .appNotAllowed)
        #expect(other?.message.contains("`offsider device-access allow` in their own terminal, choose") == true)
        #expect(other?.message.contains("(\(IOSDeviceFixtures.phone)) and pin com.example.other") == true)
        #expect(transport.calls.isEmpty)
    }

    @Test("input is refused with nothing sent while another app is in front, and goes through once the pinned app is")
    func inputNeedsPinnedAppInFront() async throws {
        let transport = FakeRunnerTransport()
        transport.foregroundApp = "com.example.other"
        let backend = try Self.backend(transport)
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.openInputSession(for: Self.phone).perform(.tapAt(x: 10, y: 20)) }
        #expect(error?.reason == .appNotAllowed)
        #expect(error?.message.contains("com.example.other is in front") == true)
        #expect(!transport.calls.contains { $0.path == "/tap-point" })

        transport.foregroundApp = Self.playground
        try await backend.openInputSession(for: Self.phone).perform(.tapAt(x: 10, y: 20))
        #expect(transport.calls.last?.path == "/tap-point")
        #expect(transport.calls.last?.body["app"] == AnyHashable(Self.playground))
    }

    @Test("a device usbmuxd no longer lists on USB gets no input")
    func cablePulled() async throws {
        let transport = FakeRunnerTransport()
        transport.foregroundApp = Self.playground
        let backend = try Self.backend(transport, onUSB: false)
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.openInputSession(for: Self.phone).perform(.tapAt(x: 10, y: 20)) }
        #expect(error?.reason == .deviceNotWired)
        #expect(!transport.calls.contains { $0.path == "/tap-point" })
    }

    @Test("the runner's 409 app_not_in_front is app_not_allowed")
    func runnerConflict() async throws {
        let transport = FakeRunnerTransport()
        transport.failure = ("/snapshot", 409, "app_not_in_front")
        let client = RunnerClient(udid: IOSDeviceFixtures.phone, token: "t", transport: transport)
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await client.snapshot(app: Self.playground) }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("a backend the CLI did not configure enforces no pin")
    func unconfigured() async throws {
        var host = IOSDeviceHost.fake(try FakeDevicectl.listing("devicectl-list-xcode26.json"))
        host.runnerConnector = FakeRunnerConnector(transport: FakeRunnerTransport())
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        try await backend.requirePinnedAppInFront(Self.phone)
    }
}
