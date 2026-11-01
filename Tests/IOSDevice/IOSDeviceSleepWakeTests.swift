import Foundation
@testable import Offsider
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("iPhone screen sleep and wake", .serialized)
@MainActor
struct IOSDeviceSleepWakeTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    static func backend(_ transport: FakeRunnerTransport, whole: Bool = false, root: String? = nil) throws -> IOSDeviceBackend {
        var host = IOSDeviceHost.fake(try FakeDevicectl.listing("devicectl-list-xcode26.json"), usbmux: FakeUsbmuxListing.onUSB(IOSDeviceFixtures.phone))
        host.runnerConnector = FakeRunnerConnector(transport: transport)
        if let root { host.privateRoot = root }
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("518.24") }
        let allowance = DeviceAllowance(platform: .ios, key: IOSDeviceFixtures.phone, name: "Test iPhone", added: Date(), expires: nil, apps: [], testDevice: whole)
        IOSDevicePinning.configure(backend, allowance: allowance, policy: PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance])), profileBundleID: { nil })
        return backend
    }

    @Test("the lock hold stays inside the window a real phone showed: above the 0.29 s some devices ignore, below Siri's 0.40 s")
    func holdWindow() {
        for button in [HardwareButton.lock, .sideButton] {
            #expect(button.deviceShortPressHold >= 0.29)
            #expect(button.deviceShortPressHold < 0.40)
        }
    }

    @Test("sleep on a dark screen sends nothing, since a press would light it")
    func sleepIdempotent() async throws {
        let transport = FakeRunnerTransport()
        transport.screenOn = false
        transport.screenLocked = true
        let change = try await Self.backend(transport).sleepScreen(Self.phone)
        #expect(change.presses == 0)
        #expect(transport.lockPresses == 0)
    }

    @Test("sleep presses lock until the screen is dark, and once more when the first press only closes a sheet")
    func sleepPresses() async throws {
        let transport = FakeRunnerTransport()
        #expect(try await Self.backend(transport).sleepScreen(Self.phone).presses == 1)
        let sheet = FakeRunnerTransport()
        sheet.sheetsOpen = 1
        #expect(try await Self.backend(sheet).sleepScreen(Self.phone).presses == 2)
    }

    @Test("wake on an awake, unlocked screen sends nothing, as Home would leave the app")
    func wakeIdempotent() async throws {
        let transport = FakeRunnerTransport()
        #expect(try await Self.backend(transport).wakeScreen(Self.phone).presses == 0)
        #expect(transport.homePresses == 0)
    }

    @Test("wake presses Home twice from dark with no passcode")
    func wakeFromDark() async throws {
        let transport = FakeRunnerTransport()
        transport.screenOn = false
        transport.screenLocked = true
        #expect(try await Self.backend(transport).wakeScreen(Self.phone).presses == 2)
        #expect(!transport.screenLocked)
    }

    @Test("a passcode stops wake at two presses with device_locked; it types nothing")
    func wakeStopsAtPasscode() async throws {
        let transport = FakeRunnerTransport()
        transport.screenOn = false
        transport.screenLocked = true
        transport.passcode = true
        let error = await #expect(throws: IOSDeviceError.self) { try await Self.backend(transport).wakeScreen(Self.phone) }
        #expect(error?.kind == .locked)
        #expect(transport.homePresses == 2)
        #expect(!transport.calls.contains { $0.path == "/type" })
    }

    @Test("a pinned app behind the lock screen says to wake, not to open the app")
    func lockedNamesWake() async throws {
        let transport = FakeRunnerTransport()
        transport.foregroundApp = "com.mpalmes.offsider.playground"
        transport.screenLocked = true
        let backend = try Self.backend(transport)
        backend.targetApp = "com.mpalmes.offsider.playground"
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.requirePinnedAppInFront(Self.phone) }
        #expect(error?.kind == .locked)
        #expect(error?.message.contains("offsider wake --device") == true)
    }

    @Test("a test device needs no app named and makes no front-app check")
    func wholeSkipsCheck() async throws {
        let transport = FakeRunnerTransport()
        let backend = try Self.backend(transport, whole: true)
        #expect(backend.targetApp == nil)
        try await backend.requirePinnedAppInFront(Self.phone)
        #expect(!transport.calls.contains { $0.path == "/foreground" })
    }

    @Test("on a test device, --app on an app not in front names the command that opens it, and asks nobody")
    func wholeNamesLaunch() async throws {
        let transport = FakeRunnerTransport()
        transport.failure = ("/snapshot", 409, "app_not_in_front")
        let backend = try Self.backend(transport, whole: true)
        backend.targetApp = "com.example.app"
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.rawAccessibilitySource(for: Self.phone) }
        #expect(error?.message.contains("offsider app launch --app com.example.app") == true)
        #expect(error?.message.contains("Ask the user") == false)
    }

    @Test("a test device's next command wakes a screen Offsider put to sleep, once, and clears the mark")
    func nextCommandWakes() async throws {
        let root = try makePolicyHome()
        chmod(root, 0o700)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let transport = FakeRunnerTransport()
        let backend = try Self.backend(transport, whole: true, root: root)
        _ = try await backend.sleepScreen(Self.phone)
        let store = DeviceSessionStore(root: root)
        #expect(store.isMarkedAsleep(udid: IOSDeviceFixtures.phone))
        try await backend.requirePinnedAppInFront(Self.phone)
        #expect(transport.homePresses == 2)
        #expect(!store.isMarkedAsleep(udid: IOSDeviceFixtures.phone))
        try await backend.requirePinnedAppInFront(Self.phone)
        #expect(transport.homePresses == 2)
    }

    @Test("a plain allowance's sleep leaves no mark, so nothing wakes by itself")
    func plainLeavesNoMark() async throws {
        let root = try makePolicyHome()
        chmod(root, 0o700)
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try await Self.backend(FakeRunnerTransport(), root: root).sleepScreen(Self.phone)
        #expect(!DeviceSessionStore(root: root).isMarkedAsleep(udid: IOSDeviceFixtures.phone))
    }

    @Test("the broker sleeps only an allowed test device not already asleep")
    func brokerAsks() throws {
        let root = try makePolicyHome()
        chmod(root, 0o700)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = DeviceSessionStore(root: root)
        let key = IOSDeviceFixtures.phone.uppercased()
        func gate(_ entry: DeviceAllowance, managed: ManagedDevicePolicy = .none) -> DevicePolicyGate {
            .fixed(PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: [entry])))
        }
        let whole = DeviceAllowance(platform: .ios, key: key, name: "T", added: Date(), expires: nil, apps: [], testDevice: true)
        let plain = DeviceAllowance(platform: .ios, key: key, name: "T", added: Date(), expires: nil, apps: [])
        #expect(DeviceSessionServe.sleepsWhenIdle(udid: IOSDeviceFixtures.phone, key: key, store: store, gate: gate(whole)))
        #expect(!DeviceSessionServe.sleepsWhenIdle(udid: IOSDeviceFixtures.phone, key: key, store: store, gate: gate(plain)))
        #expect(!DeviceSessionServe.sleepsWhenIdle(udid: IOSDeviceFixtures.phone, key: key, store: store, gate: gate(whole, managed: ManagedDevicePolicy(allowPhysicalDevices: true))))
        store.markAsleep(udid: IOSDeviceFixtures.phone)
        #expect(!DeviceSessionServe.sleepsWhenIdle(udid: IOSDeviceFixtures.phone, key: key, store: store, gate: gate(whole)))
    }
}
