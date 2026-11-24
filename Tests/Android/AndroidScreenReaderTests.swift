import Foundation
@testable import OffsiderAndroid
import OffsiderCore
import Testing

@Suite("Android screen reader")
@MainActor
struct AndroidScreenReaderTests {
    nonisolated static let emulator = DeviceID(rawValue: "emulator-5556", platform: .android)
    nonisolated static let phone = DeviceID(rawValue: "R58MFAKE01", platform: .android)
    nonisolated static let talkBack = AndroidScreenReader.components[0]
    nonisolated static let other = "com.example.switches/com.example.switches.SwitchService"

    /// TalkBack and its settings as Android keeps them, with the commands that change them.
    final class Device: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String]
        private var granted: Bool?
        private var commands: [String] = []
        private var asked = 0
        private let installed: Bool
        private let binds: Bool
        private let refusesGrant: Bool
        var beforeChange: (@Sendable () -> Void)?

        init(services: [String] = [], granted: Bool? = false, installed: Bool = true, binds: Bool = true, refusesGrant: Bool = false) {
            self.services = services
            self.granted = granted
            self.installed = installed
            self.binds = binds
            self.refusesGrant = refusesGrant
        }

        var enabled: [String] { lock.withLock { services } }
        var isGranted: Bool? { lock.withLock { granted } }
        var changes: [String] { lock.withLock { commands } }
        var shells: Int { lock.withLock { asked } }

        private var exploring: Bool { binds && services.contains(AndroidScreenReaderTests.talkBack) }
        private var list: String { services.isEmpty ? "null" : services.joined(separator: ":") }

        func reply(_ command: String) -> FakeAdbServer.Reply {
            let changes = command.hasPrefix("pm grant") || command.hasPrefix("pm revoke") || command.hasPrefix("settings put") || command.hasPrefix("settings delete")
            if changes { beforeChange?() }
            return lock.withLock {
                asked += 1
                if changes { commands.append(command) }
                switch command {
                case AndroidScreenReader.stateScript:
                    return FakeAdbServer.shell(stdout: "\(list)\n\(exploring ? 1 : 0)\n")
                case AndroidScreenReader.touchScript:
                    return FakeAdbServer.shell(stdout: exploring ? "1\n" : "0\n")
                case AndroidScreenReader.installedScript:
                    return FakeAdbServer.shell(stdout: installed ? "com.google.android.marvin.talkback\n" : "")
                case AndroidScreenReader.grantedScript(component: AndroidScreenReaderTests.talkBack):
                    return FakeAdbServer.shell(stdout: granted.map { "      android.permission.POST_NOTIFICATIONS: granted=\($0), flags=[ USER_SENSITIVE_WHEN_GRANTED]\n" } ?? "", status: granted == nil ? 1 : 0)
                case AndroidScreenReader.permissionScript(grant: true, component: AndroidScreenReaderTests.talkBack):
                    if refusesGrant { return FakeAdbServer.shell(stderr: "Exception occurred while executing 'grant'\n", status: 255) }
                    granted = true
                case AndroidScreenReader.permissionScript(grant: false, component: AndroidScreenReaderTests.talkBack):
                    granted = false
                case "settings delete secure enabled_accessibility_services":
                    services = []
                default:
                    let prefix = "settings put secure enabled_accessibility_services '"
                    if command.hasPrefix(prefix) { services = command.dropFirst(prefix.count).dropLast().split(separator: ":").map(String.init) }
                }
                return FakeAdbServer.shell()
            }
        }
    }

    static func server(_ device: Device, serial: String) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            [serial],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device transport_id:2\n")
                default: return .hang
                }
            },
            device: { _, service in device.reply(String(service.dropFirst("shell,v2,raw:".count))) }
        ))
    }

    static func host(_ device: Device, serial: String = phone.rawValue, directory: URL) throws -> AndroidHost {
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server(device, serial: serial))
        host.screenReaderRecordDirectory = { _ in directory.path }
        return host
    }

    /// A host whose emulator on 5556 was started with `arguments`, as its discovery file records them.
    static func emulatorHost(_ device: Device, arguments: String, directory: URL) throws -> AndroidHost {
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write("avd.id=Offsider_E2E\nport.serial=5556\ncmdline=\(arguments)\n", to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini", in: home)
        var host = AndroidTestHost.make(home: home, adb: server(device, serial: emulator.rawValue), liveProcesses: [50144])
        host.screenReaderRecordDirectory = { _ in directory.path }
        return host
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-talkback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func store(_ directory: URL) -> AndroidScreenReaderRecordStore {
        AndroidScreenReaderRecordStore(directory: directory.path)
    }

    // MARK: What Android prints

    @Test("the enabled list and touch exploration are read together, and a list holding anything but component names is no answer")
    func parseState() {
        #expect(AndroidScreenReader.parseState("null\n0\n") == .init(services: [], touchExploration: false))
        #expect(AndroidScreenReader.parseState("\(Self.other):\(Self.talkBack)\n1\n") == .init(services: [Self.other, Self.talkBack], touchExploration: true))
        #expect(AndroidScreenReader.parseState("\(Self.talkBack)\n") == nil)
        #expect(AndroidScreenReader.parseState("a/b'; reboot; '\n1\n") == nil, "it would go back into a shell command")
        #expect(AndroidScreenReader.parseState("\(Self.talkBack)\nmaybe\n") == nil)
    }

    @Test("TalkBack counts as on only when it is enabled and Android explores by touch")
    func isOn() {
        #expect(AndroidScreenReader.State(services: [Self.talkBack], touchExploration: true).isOn(Self.talkBack))
        #expect(!AndroidScreenReader.State(services: [Self.talkBack], touchExploration: false).isOn(Self.talkBack))
        #expect(!AndroidScreenReader.State(services: [Self.other], touchExploration: true).isOn(Self.talkBack))
    }

    @Test("the installed TalkBack is found by package, the list is written quoted or deleted when empty, and a missing permission line is no answer")
    func scripts() {
        #expect(AndroidScreenReader.installed("com.google.android.marvin.talkback\n") == Self.talkBack)
        #expect(AndroidScreenReader.installed("com.samsung.android.accessibility.talkback\n") == AndroidScreenReader.components[1])
        #expect(AndroidScreenReader.installed("") == nil)
        #expect(AndroidScreenReader.writeScript(services: [Self.other, Self.talkBack]) == "settings put secure enabled_accessibility_services '\(Self.other):\(Self.talkBack)'")
        #expect(AndroidScreenReader.writeScript(services: []) == "settings delete secure enabled_accessibility_services")
        #expect(AndroidScreenReader.parseGranted("android.permission.POST_NOTIFICATIONS: granted=true, flags=[]") == true)
        #expect(AndroidScreenReader.parseGranted("android.permission.POST_NOTIFICATIONS: granted=false, flags=[]") == false)
        #expect(AndroidScreenReader.parseGranted("") == nil)
    }

    @Test("an emulator is silent only when its discovery file shows -no-audio")
    func silent() throws {
        #expect(try EmulatorDiscovery.parse(fileName: "pid_1.ini", contents: #"cmdline="qemu" "-avd" "Offsider_E2E" "-no-metrics" "-no-audio""#).isSilent)
        #expect(try EmulatorDiscovery.parse(fileName: "pid_1.ini", contents: #"cmdline="qemu" "-avd" "Offsider_E2E""#).isSilent == false)
        #expect(try EmulatorDiscovery.parse(fileName: "pid_1.ini", contents: "avd.id=Offsider_E2E").isSilent == false)
    }

    @Test("a record names a TalkBack Offsider knows, and anything else on disk is not a record")
    func record() throws {
        let directory = try Self.directory()
        let store = Self.store(directory)
        let record = AndroidScreenReaderRecord(serial: Self.phone.rawValue, avd: nil, component: Self.talkBack, turnedOn: true, grantedNotifications: true)
        try store.save(record)
        #expect(store.load(serial: Self.phone.rawValue) == record)
        #expect(AndroidScreenReaderRecord(data: Data(#"{"serial":"R58MFAKE01","component":"a/b; reboot","turnedOn":true}"#.utf8)) == nil)
        #expect(AndroidScreenReaderRecord(data: Data(#"{"serial":"R58MFAKE01","turnedOn":true}"#.utf8)) == nil)
    }

    // MARK: on

    @Test("on records first, answers TalkBack's notification prompt ahead of time, and adds TalkBack to the services already enabled")
    func on() async throws {
        let device = Device(services: [Self.other])
        let directory = try Self.directory()
        let recordedFirst = RecordChecks()
        let path = directory.path
        device.beforeChange = { recordedFirst.note(AndroidScreenReaderRecordStore(directory: path).load(serial: Self.phone.rawValue) != nil) }
        let host = try Self.host(device, directory: directory)
        let change = try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.phone)
        #expect(change == ScreenReaderChange(previous: false, current: true, resetBySessionStop: true))
        #expect(device.enabled == [Self.other, Self.talkBack])
        #expect(device.isGranted == true)
        #expect(device.changes.first == "pm grant com.google.android.marvin.talkback android.permission.POST_NOTIFICATIONS")
        #expect(recordedFirst.values == [true, true], "the record is on disk before each change")
        #expect(Self.store(directory).load(serial: Self.phone.rawValue) == AndroidScreenReaderRecord(serial: Self.phone.rawValue, avd: nil, component: Self.talkBack, turnedOn: true, grantedNotifications: true))
    }

    @Test("off takes TalkBack out, leaves the other services, and revokes the permission only where Offsider granted it", arguments: [false, true])
    func off(alreadyGranted: Bool) async throws {
        let device = Device(services: [Self.other], granted: alreadyGranted)
        let directory = try Self.directory()
        let backend = AndroidBackend(host: try Self.host(device, directory: directory)) { _, _ in }
        _ = try await backend.setScreenReader(true, on: Self.phone)
        let change = try await backend.setScreenReader(false, on: Self.phone)
        #expect(change == ScreenReaderChange(previous: true, current: false, resetBySessionStop: false))
        #expect(device.enabled == [Self.other])
        #expect(device.isGranted == alreadyGranted)
        #expect(device.changes.contains { $0.hasPrefix("pm revoke") } == !alreadyGranted)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("with TalkBack the only service, off deletes the list, as Android ships it")
    func offDeletesEmptyList() async throws {
        let device = Device()
        let backend = AndroidBackend(host: try Self.host(device, directory: try Self.directory())) { _, _ in }
        _ = try await backend.setScreenReader(true, on: Self.phone)
        _ = try await backend.setScreenReader(false, on: Self.phone)
        #expect(device.changes.last { $0.hasPrefix("settings") } == "settings delete secure enabled_accessibility_services")
    }

    @Test("TalkBack a person turned on is left as it is: on changes nothing but notes it, so input goes past it, and session stop leaves it on and says nothing")
    func personTurnedItOn() async throws {
        let device = Device(services: [Self.talkBack], granted: true)
        let directory = try Self.directory()
        let host = try Self.host(device, directory: directory)
        let backend = AndroidBackend(host: host) { _, _ in }
        let change = try await backend.setScreenReader(true, on: Self.phone)
        #expect(change == ScreenReaderChange(previous: true, current: true, resetBySessionStop: false))
        #expect(device.changes.isEmpty)
        #expect(!backend.screenReaderIsRecorded(on: Self.phone))
        #expect(backend.screenReaderIsNoted(Self.phone.rawValue))
        #expect(AndroidBackend.recordedPhoneState(host: host).isEmpty, "session status lists only what Offsider turned on")
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host) == RecordResetOutcome())
        #expect(device.enabled == [Self.talkBack])
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("TalkBack someone enabled that never started is an error, and is never recorded as Offsider's")
    func enabledButNotStarted() async throws {
        let device = Device(services: [Self.talkBack], granted: true, binds: false)
        let directory = try Self.directory()
        let error = await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: try Self.host(device, directory: directory)) { _, _ in }.setScreenReader(true, on: Self.phone) }
        #expect(error?.hint == "offsider screen-reader off --device \(Self.phone.rawValue)")
        #expect(device.changes.isEmpty)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("another AVD's record on the same port is not this emulator's: nothing is noted, and its permission flag is not inherited")
    func anotherAVDsRecord() async throws {
        let device = Device(granted: true)
        let directory = try Self.directory()
        let host = try Self.emulatorHost(device, arguments: #""qemu" "-avd" "Offsider_E2E" "-no-audio""#, directory: directory)
        try Self.store(directory).save(AndroidScreenReaderRecord(serial: Self.emulator.rawValue, avd: "Someone_Elses_AVD", component: Self.talkBack, turnedOn: true, grantedNotifications: true))
        let backend = AndroidBackend(host: host) { _, _ in }
        #expect(!backend.screenReaderIsNoted(Self.emulator.rawValue))
        #expect(!backend.screenReaderIsRecorded(on: Self.emulator))
        #expect(AndroidBackend.screenReaderNote(host: host, serial: Self.emulator.rawValue) == nil)
        _ = try await backend.setScreenReader(true, on: Self.emulator)
        #expect(Self.store(directory).load(serial: Self.emulator.rawValue)?.grantedNotifications == false, "a person granted it on this AVD, so off must not revoke it")
        #expect(AndroidBackend.screenReaderNote(host: host, serial: Self.emulator.rawValue) == true)
    }

    @Test("an image without TalkBack is not supported, and nothing is changed or recorded")
    func notInstalled() async throws {
        let device = Device(installed: false)
        let directory = try Self.directory()
        let error = await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: try Self.host(device, directory: directory)) { _, _ in }.setScreenReader(true, on: Self.phone) }
        #expect(error?.reason == .notSupported)
        #expect(device.changes.isEmpty)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("an emulator started with sound is refused before any change, as TalkBack would speak on the Mac")
    func emulatorWithSound() async throws {
        let device = Device()
        let directory = try Self.directory()
        let host = try Self.emulatorHost(device, arguments: #""qemu" "-avd" "Offsider_E2E" "-no-metrics""#, directory: directory)
        let error = await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.emulator) }
        #expect(error?.reason == .notSupported)
        #expect(error?.message.contains("offsider boot Offsider_E2E") == true)
        #expect(error?.hint == "offsider shutdown Offsider_E2E")
        #expect(device.changes.isEmpty)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("a silent emulator is recorded under its AVD name, so the record follows the AVD and not the port")
    func silentEmulator() async throws {
        let device = Device()
        let directory = try Self.directory()
        let host = try Self.emulatorHost(device, arguments: #""qemu" "-avd" "Offsider_E2E" "-no-metrics" "-no-audio""#, directory: directory)
        _ = try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.emulator)
        #expect(Self.store(directory).load(serial: Self.emulator.rawValue)?.avd == "Offsider_E2E")
        #expect(AndroidBackend.recordedPhoneState(host: host).map(\.screenReader) == [true])
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host, serial: "Offsider_E2E").reset == [Self.emulator.rawValue])
        #expect(device.enabled.isEmpty)
        #expect(device.isGranted == false)
    }

    @Test("a prompt Offsider cannot answer ahead of time leaves TalkBack off, with no record")
    func grantRefused() async throws {
        let device = Device(refusesGrant: true)
        let directory = try Self.directory()
        await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: try Self.host(device, directory: directory)) { _, _ in }.setScreenReader(true, on: Self.phone) }
        #expect(device.enabled.isEmpty)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("TalkBack that never starts is an error, and what was changed for it is undone")
    func neverStarts() async throws {
        let device = Device(services: [Self.other], binds: false)
        let directory = try Self.directory()
        let error = await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: try Self.host(device, directory: directory)) { _, _ in }.setScreenReader(true, on: Self.phone) }
        #expect(error?.reason == .commandFailed)
        #expect(device.enabled == [Self.other])
        #expect(device.isGranted == false)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("on with nowhere to record is refused before any change")
    func noStore() async throws {
        let device = Device()
        var host = try Self.host(device, directory: try Self.directory())
        host.screenReaderRecordDirectory = { _ in nil }
        await #expect(throws: ScreenReaderError.self) { try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.phone) }
        #expect(device.changes.isEmpty)
    }

    // MARK: session stop

    @Test("session stop turns off what Offsider turned on, once, and revokes what it granted")
    func reset() async throws {
        let device = Device(services: [Self.other])
        let directory = try Self.directory()
        let host = try Self.host(device, directory: directory)
        _ = try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.phone)
        #expect(AndroidBackend.recordedPhoneState(host: host, serial: Self.phone.rawValue).map(\.screenReader) == [true])
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host, serial: Self.phone.rawValue).reset == [Self.phone.rawValue])
        #expect(device.enabled == [Self.other])
        #expect(device.isGranted == false)
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host, serial: Self.phone.rawValue) == RecordResetOutcome())
    }

    @Test("TalkBack a person already turned off is not reported, but the permission Offsider granted is still revoked")
    func resetAfterOffByHand() async throws {
        let device = Device()
        let directory = try Self.directory()
        let host = try Self.host(device, directory: directory)
        _ = try await AndroidBackend(host: host) { _, _ in }.setScreenReader(true, on: Self.phone)
        _ = device.reply("settings delete secure enabled_accessibility_services")
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host) == RecordResetOutcome())
        #expect(device.isGranted == false)
        #expect(Self.store(directory).all().isEmpty)
    }

    @Test("a device that is away keeps its record and is named, and a phone no longer allowed is sent nothing")
    func resetAwayOrUnpermitted() async throws {
        let device = Device(services: [Self.talkBack], granted: true)
        let directory = try Self.directory()
        let host = try Self.host(device, directory: directory)
        let store = Self.store(directory)
        try store.save(AndroidScreenReaderRecord(serial: "OTHERPHONE1", avd: nil, component: Self.talkBack, turnedOn: true))
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host) == RecordResetOutcome(notConnected: ["OTHERPHONE1"]))
        store.remove(serial: "OTHERPHONE1")
        try store.save(AndroidScreenReaderRecord(serial: Self.phone.rawValue, avd: nil, component: Self.talkBack, turnedOn: true))
        #expect(await AndroidBackend.resetRecordedScreenReaders(host: host, permits: { _ in false }) == RecordResetOutcome(skipped: [Self.phone.rawValue]))
        #expect(device.enabled == [Self.talkBack])
        #expect(device.changes.isEmpty)
    }
}

private final class RecordChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    var values: [Bool] { lock.withLock { seen } }
    func note(_ value: Bool) { lock.withLock { seen.append(value) } }
}
