import ArgumentParser
import Foundation
import OffsiderAndroid
@testable import OffsiderCore
import Testing
@testable import Offsider

/// A simulator's preferences as `simctl spawn` would change them, with every call kept in order.
final class FakeSimulatorPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var volume: Double?
    private var calls: [[String]] = []
    private var failing: String?
    private var stuck: Bool
    private var devices: String?
    var beforeWrite: (@Sendable () -> Void)?

    init(enabled: Bool = false, volume: Double? = nil, failing: String? = nil, stuck: Bool = false, devices: String? = nil) {
        self.enabled = enabled
        self.volume = volume
        self.failing = failing
        self.stuck = stuck
        self.devices = devices
    }

    var state: (enabled: Bool, volume: Double?) { lock.withLock { (enabled, volume) } }
    /// Each call from `defaults` or `notifyutil` on, such as `defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool true`.
    var commands: [String] { lock.withLock { calls.map { $0.drop { $0 != "defaults" && $0 != "notifyutil" && $0 != "list" }.joined(separator: " ") } } }
    var writes: [String] { commands.filter { !$0.hasPrefix("defaults export") && !$0.hasPrefix("list") } }

    var run: @Sendable ([String]) async throws -> String {
        { [self] arguments in
            let isWrite = arguments.contains("write") || arguments.contains("delete")
            if isWrite { beforeWrite?() }
            return try lock.withLock {
                calls.append(arguments)
                if let failing, arguments.contains(failing) { throw ScreenReaderError("refused") }
                if arguments == SimulatorScreenReaders.listArguments {
                    guard let devices else { throw ScreenReaderError("no list") }
                    return devices
                }
                if arguments.contains("export") {
                    var object: [String: Any] = ["OtherKey": 1]
                    if enabled { object[SimulatorScreenReader.enabledKey] = true }
                    if let volume { object[SimulatorScreenReader.volumeKey] = volume }
                    return String(decoding: try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
                }
                if arguments.contains("write"), arguments.contains(SimulatorScreenReader.enabledKey), !stuck { enabled = arguments.last == "true" }
                if arguments.contains("write"), arguments.contains(SimulatorScreenReader.volumeKey) { volume = Double(arguments.last ?? "") }
                if arguments.contains("delete") {
                    guard volume != nil else { throw ScreenReaderError("does not exist") }
                    volume = nil
                }
                return ""
            }
        }
    }

    func reader(_ udid: String = ScreenReaderTests.udid) -> SimulatorScreenReader {
        var reader = SimulatorScreenReader(udid: udid, run: run)
        reader.pause = { _ in }
        return reader
    }
}

@Suite("screen-reader")
struct ScreenReaderTests {
    static let udid = "00000000-0000-0000-0000-000000000001"
    static let other = "00000000-0000-0000-0000-000000000002"

    static func store() throws -> ScreenReaderRecordStore {
        try #require(ScreenReaderRecordStore.privateStore(create: true, root: try makePrivateLockRoot()))
    }

    static func devices(_ rows: [(udid: String, state: String, dataPath: String?)]) -> String {
        let list = rows.map { row -> [String: Any] in
            var device: [String: Any] = ["udid": row.udid, "state": row.state, "name": "Test Phone"]
            device["dataPath"] = row.dataPath
            return device
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": list]]), as: UTF8.self)
    }

    // MARK: The record

    @Test("a record is kept per simulator, comes back as saved, and goes when removed")
    func recordRoundTrip() throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid.lowercased(), volume: 0.5))
        try store.save(ScreenReaderRecord(udid: Self.other, volume: nil))
        #expect(store.load(udid: Self.udid) == ScreenReaderRecord(udid: Self.udid, volume: 0.5))
        #expect(store.all().map(\.udid) == [Self.udid, Self.other])
        store.remove(udid: Self.udid)
        #expect(store.load(udid: Self.udid) == nil)
        #expect(store.all().map(\.volume) == [nil])
    }

    @Test("a file that is not this simulator's record is removed, and a name that is no UDID is never a file name")
    func foreignRecord() throws {
        let store = try Self.store()
        let name = try #require(ScreenReaderRecordStore.fileName(udid: Self.udid))
        try OffsiderPrivateDirectory.writeAtomically(ScreenReaderRecord(udid: Self.other, volume: nil).encoded(), named: name, in: store.directory)
        #expect(store.load(udid: Self.udid) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory + "/" + name))
        #expect(ScreenReaderRecordStore.fileName(udid: "../../etc") == nil)
        try OffsiderPrivateDirectory.writeAtomically(Data("{}".utf8), named: "ios-notes.json", in: store.directory)
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory + "/ios-notes.json"))
        #expect(throws: ScreenReaderError.self) { try store.save(ScreenReaderRecord(udid: "emulator-5554", volume: nil)) }
    }

    // MARK: On and off

    @Test("on saves the record before any write, silences VoiceOver, turns it on and posts the change")
    func on() async throws {
        let store = try Self.store()
        let fake = FakeSimulatorPreferences(volume: 0.8)
        let recordedAtFirstWrite = RecordSeen()
        fake.beforeWrite = { recordedAtFirstWrite.note(store.load(udid: Self.udid) != nil) }
        let change = try await fake.reader().set(true, store: store)
        #expect(change == ScreenReaderChange(previous: false, current: true, resetBySessionStop: true))
        #expect(recordedAtFirstWrite.first == true)
        #expect(fake.writes == [
            "defaults write com.apple.Accessibility VoiceOverTouchVolume -float 0",
            "defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool true",
            "notifyutil -p com.apple.accessibility.cache.vot",
        ])
        #expect(store.load(udid: Self.udid) == ScreenReaderRecord(udid: Self.udid, volume: 0.8))
    }

    @Test("on where a person already turned it on changes nothing and records nothing, so session stop leaves it")
    func alreadyOn() async throws {
        let store = try Self.store()
        let fake = FakeSimulatorPreferences(enabled: true)
        let change = try await fake.reader().set(true, store: store)
        #expect(change == ScreenReaderChange(previous: true, current: true, resetBySessionStop: false))
        #expect(fake.writes.isEmpty)
        #expect(store.all().isEmpty)
    }

    @Test("on over a record left by a reader turned off by hand keeps the volume first recorded, so off still restores it")
    func staleRecordKeepsVolume() async throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid, volume: 0.8))
        let fake = FakeSimulatorPreferences(enabled: false, volume: 0)
        _ = try await fake.reader().set(true, store: store)
        #expect(store.load(udid: Self.udid)?.volume == 0.8)
        _ = try await fake.reader().set(false, store: store)
        #expect(fake.state.volume == 0.8)
    }

    @Test("a record removed while the reader was being turned on is saved again, so the reader is never on without one")
    func recordRemovedMidway() async throws {
        let store = try Self.store()
        let fake = FakeSimulatorPreferences()
        fake.beforeWrite = { store.remove(udid: Self.udid) }
        _ = try await fake.reader().set(true, store: store)
        #expect(fake.state.enabled)
        #expect(store.load(udid: Self.udid) != nil)
    }

    @Test("on with nowhere to record is refused before any write")
    func noStore() async {
        let fake = FakeSimulatorPreferences()
        await #expect(throws: ScreenReaderError.self) { try await fake.reader().set(true, store: nil) }
        #expect(fake.writes.isEmpty)
        #expect(!fake.state.enabled)
    }

    @Test("a write that fails leaves the reader off, the volume as it was and no record")
    func failedWrite() async throws {
        let store = try Self.store()
        let fake = FakeSimulatorPreferences(failing: "true")
        await #expect(throws: ScreenReaderError.self) { try await fake.reader().set(true, store: store) }
        #expect(fake.state.enabled == false && fake.state.volume == nil)
        #expect(store.all().isEmpty)
    }

    @Test("a setting that never takes is an error, and the record stays while it cannot be read as off")
    func neverTakes() async throws {
        let store = try Self.store()
        let stuckOff = FakeSimulatorPreferences(stuck: true)
        let error = await #expect(throws: ScreenReaderError.self) { try await stuckOff.reader().set(true, store: store) }
        #expect(error?.message.contains("did not turn VoiceOver on in time") == true)
        #expect(store.all().isEmpty, "it reads off, so nothing is left to undo")

        try store.save(ScreenReaderRecord(udid: Self.udid, volume: nil))
        let stuckOn = FakeSimulatorPreferences(enabled: true, volume: 0, stuck: true)
        await #expect(throws: ScreenReaderError.self) { try await stuckOn.reader().set(false, store: store) }
        #expect(store.load(udid: Self.udid) != nil)
    }

    @Test("off turns it off, puts the volume back and drops the record", arguments: [0.8, nil] as [Double?])
    func off(volume: Double?) async throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid, volume: volume))
        let fake = FakeSimulatorPreferences(enabled: true, volume: 0)
        let change = try await fake.reader().set(false, store: store)
        #expect(change == ScreenReaderChange(previous: true, current: false, resetBySessionStop: false))
        #expect(fake.state.enabled == false && fake.state.volume == volume)
        #expect(fake.writes.last == "notifyutil -p com.apple.accessibility.cache.vot")
        #expect(store.all().isEmpty)
    }

    @Test("off for a reader a person turned on leaves its volume alone, and off when it is off writes nothing")
    func offByHand() async throws {
        let store = try Self.store()
        let byHand = FakeSimulatorPreferences(enabled: true, volume: 0.6)
        _ = try await byHand.reader().set(false, store: store)
        #expect(byHand.state.enabled == false && byHand.state.volume == 0.6)
        let alreadyOff = FakeSimulatorPreferences()
        #expect(try await alreadyOff.reader().set(false, store: store) == ScreenReaderChange(previous: false, current: false, resetBySessionStop: false))
        #expect(alreadyOff.writes.isEmpty)
    }

    @Test("the setting is read from the exported preferences, and anything else is no answer")
    func parse() {
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>VoiceOverTouchEnabled</key><true/><key>VoiceOverTouchVolume</key><real>0.25</real></dict></plist>"#
        #expect(SimulatorScreenReader.parse(plist) == .init(enabled: true, volume: 0.25))
        #expect(SimulatorScreenReader.parse(#"<plist version="1.0"><dict/></plist>"#) == .init(enabled: false, volume: nil))
        #expect(SimulatorScreenReader.parse("Unable to lookup in current state: Shutdown") == nil)
    }

    // MARK: session stop

    @Test("session stop turns off a recorded reader on a booted simulator and leaves one nobody recorded")
    func resetBooted() async throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid, volume: nil))
        let fake = FakeSimulatorPreferences(enabled: true, volume: 0, devices: Self.devices([(Self.udid, "Booted", nil), (Self.other, "Booted", nil)]))
        let outcome = await SimulatorScreenReaders.resetRecorded(store: store, udid: nil, run: fake.run)
        #expect(outcome == ScreenReaderResetOutcome(reset: [Self.udid]))
        #expect(fake.state.enabled == false && fake.state.volume == nil)
        #expect(fake.commands.allSatisfy { !$0.contains(Self.other) })
        #expect(store.all().isEmpty)

        let unrecorded = FakeSimulatorPreferences(enabled: true, devices: Self.devices([(Self.udid, "Booted", nil)]))
        #expect(await SimulatorScreenReaders.resetRecorded(store: store, udid: nil, run: unrecorded.run) == ScreenReaderResetOutcome())
        #expect(unrecorded.commands.isEmpty, "with no record, nothing is asked of any simulator")
        #expect(unrecorded.state.enabled)
    }

    @Test("a shut-down simulator's reader is turned off in its preference file, keeping every other setting")
    func resetShutDown() async throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid, volume: 0.4))
        let data = try makePrivateLockRoot()
        let path = SimulatorScreenReaders.preferencesPath(dataPath: data)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let before: [String: Any] = [SimulatorScreenReader.enabledKey: true, SimulatorScreenReader.volumeKey: 0, "ReduceMotionEnabled": true]
        try PropertyListSerialization.data(fromPropertyList: before, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        let fake = FakeSimulatorPreferences(devices: Self.devices([(Self.udid, "Shutdown", data)]))
        let outcome = await SimulatorScreenReaders.resetRecorded(store: store, udid: Self.udid.lowercased(), run: fake.run)
        #expect(outcome.reset == [Self.udid])
        #expect(fake.commands == ["list devices -j"], "a simulator that is off is sent nothing")
        let after = try #require(UntrustedRead.propertyList(atPath: path))
        #expect(after[SimulatorScreenReader.enabledKey] as? Bool == false)
        #expect(after[SimulatorScreenReader.volumeKey] as? Double == 0.4)
        #expect(after["ReduceMotionEnabled"] as? Bool == true)
        #expect(store.all().isEmpty)
    }

    @Test("a deleted simulator only loses its record, and one between states or unlisted keeps it and is named")
    func resetOthers() async throws {
        let store = try Self.store()
        try store.save(ScreenReaderRecord(udid: Self.udid, volume: nil))
        try store.save(ScreenReaderRecord(udid: Self.other, volume: nil))
        let fake = FakeSimulatorPreferences(enabled: true, devices: Self.devices([(Self.other, "Booting", nil)]))
        let outcome = await SimulatorScreenReaders.resetRecorded(store: store, udid: nil, run: fake.run)
        #expect(outcome == ScreenReaderResetOutcome(failed: [Self.other]))
        #expect(store.all().map(\.udid) == [Self.other])

        let unreadable = FakeSimulatorPreferences(enabled: true)
        #expect(await SimulatorScreenReaders.resetRecorded(store: store, udid: nil, run: unreadable.run).failed == [Self.other])
        #expect(await SimulatorScreenReaders.resetRecorded(store: store, udid: Self.udid, run: unreadable.run) == ScreenReaderResetOutcome(), "another device's stop leaves this record alone")
        #expect(store.all().count == 1)
    }

    @Test("session stop names a reader it turned off, one it could not, and status lists one recorded")
    func sessionRows() throws {
        let stopped = DeviceSessionRow.stopped(runners: [], brokers: [], inputs: [Self.udid], readers: [Self.udid])
        #expect(DeviceSessionRow.stoppedText(stopped, device: Self.udid) == "Stopped the input session and screen reader on \(Self.udid).\n")
        let left = DeviceSessionRow.left(reverses: [], postures: RecordResetOutcome(), readers: [Self.other])
        #expect(left.map(\.why) == [.failed])
        #expect(left[0].sentence == "Offsider could not remove the screen reader on \(Self.other). Run `offsider session stop --device \(Self.other)` to try again.")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.stoppedJSON(stopped, left: left).utf8)) as? [String: Any])
        #expect((object["stopped"] as? [[String: Any]])?.first?["screenReader"] as? Bool == true)
        #expect((object["notRemoved"] as? [[String: Any]])?.first?["screenReader"] as? Bool == true)

        let rows = DeviceSessionRow.rows(runners: [], brokers: [], readers: [Self.udid])
        #expect(DeviceSessionRow.text(rows) == "\(Self.udid)\n  screen reader  recorded, may be gone\n")
        let status = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.json(rows).utf8)) as? [String: Any])
        let recorded = try #require((status["sessions"] as? [[String: Any]])?.first?["recorded"] as? [String: Any])
        #expect(recorded["screenReader"] as? Bool == true && recorded["airplane"] as? Bool == false)
    }

    // MARK: The command

    @Test("an iPhone, an iPad and a network adb connection are refused before routing, with nothing sent", arguments: [IOSDeviceFixtures.phone, "192.168.1.20:5555"])
    func refusedBeforeRouting(device: String) {
        let error = #expect(throws: CLIError.self) { try ScreenReaderCommand.requireSupported(device, gate: Self.gate(testDevice: true)) }
        #expect(error?.reason == .notSupported)
        #expect(error?.errorDescription?.contains("Nothing was sent.") == true)
    }

    static let phoneSerial = "R58M123ABC"

    static func gate(testDevice: Bool, managed: ManagedDevicePolicy = .none) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: [
            DeviceAllowance(platform: .android, key: phoneSerial, name: "Test phone", added: PolicyFixtures.added, expires: nil, apps: [], testDevice: testDevice),
        ])), now: PolicyFixtures.now)
    }

    @Test("a phone in personal use is refused before routing, and a test device, an emulator, a simulator and a name the router must look up pass")
    func testDevicesOnly() throws {
        let error = #expect(throws: CLIError.self) { try ScreenReaderCommand.requireSupported(Self.phoneSerial, gate: Self.gate(testDevice: false)) }
        #expect(error?.reason == .notSupported)
        #expect(error?.errorDescription?.contains("in personal use, not a test device") == true)
        #expect(error?.errorDescription?.contains("Nothing was sent.") == true)
        try ScreenReaderCommand.requireSupported(Self.phoneSerial, gate: Self.gate(testDevice: true))
        for device in [Self.udid, "emulator-5554", "Offsider_E2E"] {
            try ScreenReaderCommand.requireSupported(device, gate: Self.gate(testDevice: false))
        }
    }

    @Test("the value is on, off or nothing")
    func arguments() throws {
        #expect(try ScreenReaderCommand.parse(["on", "--device", Self.udid]).target() == true)
        #expect(try ScreenReaderCommand.parse(["OFF", "--device", Self.udid]).target() == false)
        #expect(try ScreenReaderCommand.parse(["--device", Self.udid]).target() == nil)
        #expect(throws: (any Error).self) { try ScreenReaderCommand.parse(["loud", "--device", Self.udid]) }
    }

    @Test("on Android, turning it on says who turns it off, and that input still works as usual")
    func androidNotices() {
        let id = DeviceID(rawValue: "emulator-5554", platform: .android)
        let set = ScreenReaderCommand.notices(ScreenReaderChange(previous: false, current: true, resetBySessionStop: true), set: true, on: id)
        #expect(set.first?.agentText?.contains("`offsider session stop --device emulator-5554`") == true)
        #expect(set.first?.agentText?.contains("TalkBack is on") == true)
        #expect(set.first?.agentText?.contains("input goes past TalkBack, so tap, swipe and the rest work as usual") == true)
        let byHand = ScreenReaderCommand.notices(ScreenReaderChange(previous: true, current: true, resetBySessionStop: false), set: true, on: id)
        #expect(byHand.first?.agentText?.contains("session stop leaves it on") == true)
    }

    @Test("session stop names an Android reader it could not turn off, one on a device that is away and one no longer allowed, and status lists one recorded")
    func androidSessionRows() throws {
        let left = DeviceSessionRow.left(reverses: [], postures: RecordResetOutcome(), talkBacks: RecordResetOutcome(failed: ["emulator-5554"], notConnected: ["Offsider_E2E_Fold"], skipped: [Self.phoneSerial]))
        #expect(left.map(\.why) == [.failed, .notConnected, .notAllowed])
        #expect(left.map(\.screenReader) == [true, true, true])
        #expect(left[1].sentence == "The screen reader on Offsider_E2E_Fold stays until it is connected and you run `offsider session stop --device Offsider_E2E_Fold`.")
        let rows = DeviceSessionRow.rows(runners: [], brokers: [], recorded: [RecordedPhoneState(serial: "emulator-5554", reverses: [], posture: false, screenReader: true)])
        #expect(DeviceSessionRow.text(rows) == "emulator-5554\n  screen reader  recorded, may be gone\n")
        let status = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.json(rows).utf8)) as? [String: Any])
        let recorded = try #require((status["sessions"] as? [[String: Any]])?.first?["recorded"] as? [String: Any])
        #expect(recorded["screenReader"] as? Bool == true)
    }

    @Test("doctor warns while TalkBack is enabled, says who turns it off and how to make input reach the app, and is quiet for any other service")
    func androidDoctor() {
        let talkBack = AndroidBackend.screenReaderComponents[0]
        let ours = Doctor.talkBackCheck(serial: "emulator-5554", enabledServices: ["com.example/com.example.Service", talkBack], note: true)
        #expect(ours.map(\.id) == [.deviceScreenReader])
        #expect(ours.first?.status == .warn)
        #expect(ours.first?.detail.contains("`session stop` turns it off") == true)
        #expect(ours.first?.hint == "offsider screen-reader off --device emulator-5554")
        let noted = Doctor.talkBackCheck(serial: "emulator-5554", enabledServices: [talkBack], note: false)
        #expect(noted.first?.detail.contains("`session stop` leaves it.") == true && noted.first?.detail.contains("only select") == false)
        let theirs = Doctor.talkBackCheck(serial: "emulator-5554", enabledServices: [talkBack], note: nil)
        #expect(theirs.first?.detail.contains("`session stop` leaves it and an emulator's taps only select") == true)
        #expect(theirs.first?.detail.contains("offsider screen-reader on --device emulator-5554") == true)
        #expect(Doctor.talkBackCheck(serial: "emulator-5554", enabledServices: ["com.example/com.example.Service"], note: nil).isEmpty)
        #expect(Doctor.talkBackCheck(serial: "emulator-5554", enabledServices: [], note: true).isEmpty)
    }

    @Test("turning it on says who turns it off, and that a simulator's input is unchanged")
    func notices() {
        let id = DeviceID(rawValue: Self.udid, platform: .ios)
        let set = ScreenReaderCommand.notices(ScreenReaderChange(previous: false, current: true, resetBySessionStop: true), set: true, on: id)
        #expect(set.first?.agentText?.contains("`offsider session stop --device \(Self.udid)`") == true)
        #expect(set.first?.agentText?.contains("input works as usual") == true)
        let byHand = ScreenReaderCommand.notices(ScreenReaderChange(previous: true, current: true, resetBySessionStop: false), set: true, on: id)
        #expect(byHand.first?.agentText?.contains("session stop leaves it on") == true)
        #expect(ScreenReaderCommand.notices(ScreenReaderChange(previous: true, current: false, resetBySessionStop: false), set: true, on: id).isEmpty)
        #expect(ScreenReaderCommand.notices(ScreenReaderChange(previous: true, current: true, resetBySessionStop: true), set: false, on: id).isEmpty)
    }

    @Test("--json names the setting, what it was, the service and who resets it, in schema order")
    func json() {
        let id = DeviceID(rawValue: Self.udid, platform: .ios)
        #expect(DeviceStateReport.screenReader("on", current: true, previous: false, service: "VoiceOver", resetBySessionStop: true, on: id)
            == #"{"version":1,"action":"on","device":"\#(Self.udid)","platform":"ios","screenReader":"on","previous":"off","service":"VoiceOver","resetBySessionStop":true}"#)
        #expect(DeviceStateReport.screenReader("show", current: false, previous: nil, service: "VoiceOver", resetBySessionStop: false, on: id).contains(#""previous":null"#))
    }

    // MARK: doctor

    @Test("doctor warns while a reader is on, names who turns it off, and says nothing while it is off")
    func doctor() async {
        let recordedOn = await Doctor.screenReaderCheck(udid: Self.udid, recorded: { _ in true }, read: { _ in true })
        #expect(recordedOn.map(\.id) == [.deviceScreenReader])
        #expect(recordedOn.first?.status == .warn)
        #expect(recordedOn.first?.detail.contains("turned it on, so `session stop` turns it off") == true)
        #expect(recordedOn.first?.hint == "offsider screen-reader off --device \(Self.udid)")

        let byHand = await Doctor.screenReaderCheck(udid: Self.udid, recorded: { _ in false }, read: { _ in true })
        #expect(byHand.first?.detail.contains("did not turn it on") == true)

        let shutDown = await Doctor.screenReaderCheck(udid: Self.udid, recorded: { _ in true }, read: { _ in nil })
        #expect(shutDown.first?.hint == "offsider session stop --device \(Self.udid)")
        #expect(shutDown.first?.detail.contains("could not be read") == true)

        #expect(await Doctor.screenReaderCheck(udid: Self.udid, recorded: { _ in true }, read: { _ in false }).isEmpty)
        #expect(await Doctor.screenReaderCheck(udid: Self.udid, recorded: { _ in false }, read: { _ in nil }).isEmpty)
        #expect(await Doctor.screenReaderCheck(udid: nil).isEmpty)
    }
}

private final class RecordSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func note(_ value: Bool) { lock.withLock { values.append(value) } }
    var first: Bool? { lock.withLock { values.first } }
}
