import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android device directory")
struct AndroidDeviceDirectoryTests {
    static let listing = """
    emulator-5556 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3
    emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    emulator-5558 offline transport_id:4
    R5CT1234ABC device usb:1-1 model:SM_S928B transport_id:5
    192.168.1.5:5555 device model:y transport_id:6

    """

    /// getprop lines: qemu avd_name, kernel avd_name, boot_completed, release, sdk.
    static let properties: [String: String] = [
        "emulator-5554": "Work_AVD\n\n1\n15\n35\n",
        "emulator-5556": "Offsider_E2E\n\n\n16\n36\n",
    ]

    static func server(listing: String = listing, properties: [String: String] = properties) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            Set(properties.keys),
            host: { service in service == "host:devices-l" ? FakeAdbServer.okay(payload: listing) : .hang },
            device: { serial, _ in FakeAdbServer.shell(stdout: properties[serial] ?? "") }
        ))
    }

    static func homeWithAVDs(_ names: [String]) throws -> URL {
        let home = try AndroidTestHost.temporaryHome()
        for name in names {
            let directory = home.appendingPathComponent(".android/avd/\(name).avd")
            try AndroidTestHost.write("path=\(directory.path)\n", to: ".android/avd/\(name).ini", in: home)
            try AndroidTestHost.write("hw.device.name=pixel_9\nimage.sysdir.1=system-images/android-36/google_apis/arm64-v8a/\n", to: ".android/avd/\(name).avd/config.ini", in: home)
        }
        return home
    }

    static func directory(_ server: FakeAdbServer, home: URL, liveProcesses: Set<Int32> = []) -> AndroidDeviceDirectory {
        let host = AndroidTestHost.make(home: home, adb: server, liveProcesses: liveProcesses)
        return AndroidDeviceDirectory(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host)
    }

    @Test("rows: running emulators by port with their state, then AVDs that are not running")
    func summaries() async throws {
        let home = try Self.homeWithAVDs(["Offsider_E2E", "Spare_AVD"])
        let rows = try await Self.directory(Self.server(), home: home).summaries()

        #expect(rows == [
            DeviceSummary(id: "emulator-5554", platform: .android, state: "Booted", name: "Work_AVD", osVersion: "Android 15", deviceType: "sdk_gphone64_arm64", kind: .emulator, avd: "Work_AVD"),
            DeviceSummary(id: "emulator-5556", platform: .android, state: "Booting", name: "Offsider_E2E", osVersion: "Android 16", deviceType: "pixel_9", kind: .emulator, avd: "Offsider_E2E"),
            DeviceSummary(id: "emulator-5558", platform: .android, state: "Offline", name: "emulator-5558", osVersion: nil, deviceType: nil, kind: .emulator),
            DeviceSummary(id: "R5CT1234ABC", platform: .android, state: "Booted", name: "SM S928B", osVersion: nil, deviceType: "Physical (USB)", kind: .physical, connection: "usb"),
            DeviceSummary(id: "192.168.1.5:5555", platform: .android, state: "Unsupported", name: "y", osVersion: nil, deviceType: "Physical (network)", kind: .physical, connection: "network"),
            DeviceSummary(id: "Spare_AVD", platform: .android, state: "Shutdown", name: "Spare_AVD", osVersion: "Android API 36", deviceType: "pixel_9", kind: .avd, avd: "Spare_AVD"),
        ])
    }

    @Test("a running emulator names its AVD and the emulator process from its discovery file; phones have neither")
    func avdAndBootedBy() async throws {
        let home = try Self.homeWithAVDs(["Work_AVD"])
        try AndroidTestHost.write("avd.id=Work_AVD\nport.serial=5554\n", to: "Library/Caches/TemporaryItems/avd/running/pid_900.ini", in: home)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let server = Self.server()
        let host = AndroidTestHost.make(home: home, adb: server, liveProcesses: [900], startTimes: [900: started])
        let rows = try await AndroidDeviceDirectory(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host).summaries()

        let emulator = try #require(rows.first { $0.id == "emulator-5554" })
        #expect(emulator.avd == "Work_AVD")
        #expect(emulator.bootedBy == ProcessStamp(pid: 900, startedAt: started))
        let phone = try #require(rows.first { $0.id == "R5CT1234ABC" })
        #expect(phone.avd == nil && phone.bootedBy == nil)
        #expect(rows.first { $0.id == "emulator-5556" }?.bootedBy == nil)
    }

    @Test("an emulator whose properties cannot be read is Unknown, not Booting; checking that serial alone fails")
    func unreadableProperties() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5554", "emulator-5556"],
            host: { service in service == "host:devices-l" ? FakeAdbServer.okay(payload: Self.listing) : .hang },
            device: { serial, _ in serial == "emulator-5556" ? .hang : FakeAdbServer.shell(stdout: "Work_AVD\n\n1\n15\n35\n") }
        ))
        let directory = Self.directory(server, home: try AndroidTestHost.temporaryHome())

        let rows = try await directory.summaries().filter { $0.kind == .emulator }
        #expect(rows.map(\.state) == ["Booted", "Unknown", "Offline"])

        let error = await #expect(throws: AndroidError.self) { try await directory.runningEmulator(serial: "emulator-5556") }
        #expect(error?.message.hasPrefix("`getprop` failed on emulator-5556") == true)
    }

    @Test("a live discovery file names the AVD; getprop is the fallback, then the older kernel property")
    func avdNameSources() async throws {
        let home = try AndroidTestHost.temporaryHome()
        try AndroidTestHost.write("avd.id=From_Discovery\nport.serial=5554\n", to: "Library/Caches/TemporaryItems/avd/running/pid_900.ini", in: home)
        let properties = ["emulator-5554": "Work_AVD\n\n1\n15\n35\n", "emulator-5556": "\nKernel_Name\n1\n16\n36\n"]
        let emulators = try await Self.directory(Self.server(properties: properties), home: home, liveProcesses: [900]).runningEmulators()

        #expect(emulators.map(\.avdName) == ["From_Discovery", "Kernel_Name", nil])
        #expect(emulators.first?.discovery?.pid == 900)
    }

    @Test("physical and host:port serials are never listed")
    func physicalIgnored() async throws {
        let emulators = try await Self.directory(Self.server(), home: try AndroidTestHost.temporaryHome()).runningEmulators()
        #expect(emulators.map(\.serial) == ["emulator-5554", "emulator-5556", "emulator-5558"])
    }

    @Test("an AVD running once resolves to its serial")
    func resolvesOnce() async throws {
        let directory = Self.directory(Self.server(), home: try AndroidTestHost.temporaryHome())
        #expect(try await directory.serial(forAVDNamed: "Offsider_E2E") == "emulator-5556")
    }

    @Test("an AVD running twice is refused, listing both serials")
    func runningTwice() async throws {
        let properties = ["emulator-5554": "Twin\n\n1\n16\n36\n", "emulator-5556": "Twin\n\n1\n16\n36\n"]
        let directory = Self.directory(Self.server(properties: properties), home: try AndroidTestHost.temporaryHome())
        let error = await #expect(throws: AndroidError.self) { try await directory.serial(forAVDNamed: "Twin") }
        #expect(error?.message == "Twin is running more than once (emulator-5554, emulator-5556). Pass one serial with --device.")
    }

    @Test("a known AVD that is not running points at boot; an unknown name points at list-devices")
    func notRunningOrUnknown() async throws {
        let directory = Self.directory(Self.server(), home: try Self.homeWithAVDs(["Spare_AVD"]))

        let notRunning = await #expect(throws: AndroidError.self) { try await directory.serial(forAVDNamed: "Spare_AVD") }
        #expect(notRunning?.message == "Emulator Spare_AVD is not running. Start it with `offsider boot Spare_AVD`.")

        let unknown = await #expect(throws: AndroidError.self) { try await directory.serial(forAVDNamed: "Pixel_10") }
        #expect(unknown?.message == "No device named Pixel_10. Run `offsider list-devices` to find device IDs.")
    }

    @Test("resolving a name never queries an emulator whose discovery file already names it")
    func routingSkipsNamedEmulators() async throws {
        let home = try AndroidTestHost.temporaryHome()
        try AndroidTestHost.write("avd.id=Work_AVD\nport.serial=5554\n", to: "Library/Caches/TemporaryItems/avd/running/pid_900.ini", in: home)
        let server = Self.server()

        _ = try await Self.directory(server, home: home, liveProcesses: [900]).serial(forAVDNamed: "Offsider_E2E")
        #expect(!server.requests.contains { $0.serial == "emulator-5554" || $0.service == "host:transport:emulator-5554" })
    }

    @Test("checking one serial queries only that emulator")
    func singleSerial() async throws {
        let server = Self.server()
        let emulator = try await Self.directory(server, home: try AndroidTestHost.temporaryHome()).runningEmulator(serial: "emulator-5556")

        #expect(emulator?.avdName == "Offsider_E2E")
        #expect(emulator?.bootCompleted == false)
        #expect(server.services.filter { $0.hasPrefix("host:transport:") } == ["host:transport:emulator-5556"])
    }

    // MARK: Phones

    static let phoneListing = """
    emulator-5556 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1
    R58M123ABC device usb:1-1 product:tokay model:Pixel_9 device:tokay transport_id:2
    1A2B3C4D5E6F unauthorized usb:1-2 transport_id:3
    192.168.1.5:5555 device product:husky model:Pixel_8_Pro transport_id:4

    """

    static func touchedPhone(_ server: FakeAdbServer) -> Bool {
        server.requests.contains { request in
            ["R58M123ABC", "1A2B3C4D5E6F", "192.168.1.5:5555"].contains { request.serial == $0 || request.service.hasSuffix(":\($0)") }
        }
    }

    @Test("an AVD-name lookup never returns a phone, even when it is the only device")
    func lookupSkipsPhones() async throws {
        let server = Self.server(listing: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n", properties: [:])
        let directory = Self.directory(server, home: try Self.homeWithAVDs(["Pixel_9"]))

        let byAVD = await #expect(throws: AndroidError.self) { try await directory.serial(forAVDNamed: "Pixel_9") }
        #expect(byAVD?.kind == .avdNotRunning)
        #expect(try await directory.runningEmulators().isEmpty)
        #expect(!Self.touchedPhone(server))
    }

    @Test("a named USB serial resolves to the phone without querying it; a network serial is refused")
    func namedPhone() async throws {
        let server = Self.server(listing: Self.phoneListing)
        let directory = Self.directory(server, home: try AndroidTestHost.temporaryHome())

        #expect(try await directory.resolve(name: "R58M123ABC") == "R58M123ABC")
        #expect(try await directory.resolve(name: "1A2B3C4D5E6F") == "1A2B3C4D5E6F")
        #expect(try await directory.resolve(name: "Offsider_E2E") == "emulator-5556")
        let network = await #expect(throws: AndroidError.self) { try await directory.resolve(name: "192.168.1.5:5555") }
        #expect(network?.kind == .unsupportedDevice)
        #expect(!Self.touchedPhone(server))
    }

    @Test("a phone whose serial equals a running AVD's name is refused as ambiguous")
    func ambiguousName() async throws {
        let server = Self.server(listing: Self.phoneListing, properties: ["emulator-5556": "R58M123ABC\n\n1\n16\n36\n"])
        let directory = Self.directory(server, home: try AndroidTestHost.temporaryHome())

        let error = await #expect(throws: AndroidError.self) { try await directory.resolve(name: "R58M123ABC") }
        #expect(error?.kind == .ambiguousDeviceName)
        #expect(error?.message.contains("emulator-5556") == true)
    }

    @Test("phones are listed from the device list alone: unauthorised and network rows included, none queried")
    func phoneSummaries() async throws {
        let server = Self.server(listing: Self.phoneListing)
        let rows = try await Self.directory(server, home: try AndroidTestHost.temporaryHome()).summaries()
        let phones = rows.filter { $0.kind == .physical }

        #expect(phones.map(\.id) == ["R58M123ABC", "1A2B3C4D5E6F", "192.168.1.5:5555"])
        #expect(phones.map(\.state) == ["Booted", "Unauthorised", "Unsupported"])
        #expect(phones.map(\.connection) == ["usb", "usb", "network"])
        #expect(phones[0].name == "Pixel 9")
        #expect(phones[0].deviceType == "Physical (USB)")
        #expect(rows.first?.kind == .emulator)
        #expect(!Self.touchedPhone(server))
    }

    @Test("a phone named at routing is checked from the row routing read, so the device list is read once; an unauthorised row is still refused")
    @MainActor
    func routingRowIsReused() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"], host: { service in
            switch service {
            case "host:version": return FakeAdbServer.okay(payload: "0029")
            case "host:devices-l": return FakeAdbServer.okay(payload: Self.phoneListing)
            default: return .hang
            }
        }, device: { _, _ in FakeAdbServer.shell(stdout: "") }))
        let backend = AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), environment: [:], adb: server)) { _, _ in }

        let serial = try await backend.resolveAndroidName("R58M123ABC")
        let booted = try await backend.requireBootedDevice(DeviceID(rawValue: serial, platform: .android))
        #expect(booted.name == "Pixel 9")
        #expect(server.services.filter { $0 == "host:devices-l" }.count == 1)
        #expect(!Self.touchedPhone(server))

        let unauthorised = try await backend.resolveAndroidName("1A2B3C4D5E6F")
        let error = await #expect(throws: AndroidError.self) {
            try await backend.requireBootedDevice(DeviceID(rawValue: unauthorised, platform: .android))
        }
        #expect(error?.message == AndroidError.phoneUnauthorised("1A2B3C4D5E6F").message)
        #expect(server.services.filter { $0 == "host:devices-l" }.count == 2)
    }
}
