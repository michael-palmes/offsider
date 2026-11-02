import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Posture on a USB foldable phone", .serialized)
@MainActor
struct AndroidPhonePostureTests {
    static let serial = "R58M123ABC"
    static let phone = DeviceID(rawValue: serial, platform: .android)
    static let boot = "4f1d2b8e-0000-4000-8000-000000000001"

    /// A Samsung foldable held open: `cmd device_state` as One UI prints it, with an override a command can set or reset.
    final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        private var override: Int?
        var bootID: String
        var connected = true
        /// `cmd device_state` set and reset calls exit non-zero and change nothing.
        var refusesChange = false
        /// A set lands, then the link drops before its status arrives.
        var dropsAfterSet = false
        /// A set never lands, and the link drops.
        var dropsBeforeSet = false
        private(set) var commands: [String] = []

        init(override: Int? = nil, bootID: String = AndroidPhonePostureTests.boot) {
            self.override = override
            self.bootID = bootID
        }

        var currentOverride: Int? { lock.withLock { override } }

        static let names = [0: "CLOSE", 1: "TENT", 2: "HALF_FOLDED", 3: "OPEN"]

        static func state(_ id: Int) -> String {
            "DeviceState{identifier=\(id), name='\(names[id] ?? "OPEN")', app_accessible=true, cancel_when_requester_not_on_top=false}"
        }

        var stateText: String {
            lock.withLock {
                guard let override else { return "Committed state: \(Self.state(3))\n" }
                return "Committed state: \(Self.state(override))\n----------------------\nBase state: \(Self.state(3))\nOverride state: \(Self.state(override))\n"
            }
        }

        func reply(_ service: String) -> FakeAdbServer.Reply {
            let command = service.hasPrefix("shell,v2,raw:") ? String(service.dropFirst("shell,v2,raw:".count)) : service
            lock.withLock { commands.append(command) }
            switch command {
            case AndroidDeviceState.printStates: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.printStates)
            case AndroidDeviceState.readState: return FakeAdbServer.shell(stdout: stateText)
            case AndroidPostureRecord.bootIDScript: return FakeAdbServer.shell(stdout: bootID + "\n")
            case "\(AndroidPostureRecord.bootIDScript); \(AndroidDeviceState.readState)": return FakeAdbServer.shell(stdout: bootID + "\n" + stateText)
            case AndroidDeviceState.resetState:
                if lock.withLock({ refusesChange }) { return FakeAdbServer.shell(stderr: "refused", status: 1) }
                lock.withLock { override = nil }
                return FakeAdbServer.shell()
            default:
                if command.hasPrefix("cmd device_state state "), let id = Int(command.dropFirst("cmd device_state state ".count)) {
                    if lock.withLock({ refusesChange }) { return FakeAdbServer.shell(stderr: "refused", status: 1) }
                    if lock.withLock({ dropsBeforeSet }) { return .bytes(Data("OKAY".utf8), thenClose: true) }
                    lock.withLock { override = id }
                    return lock.withLock({ dropsAfterSet }) ? .bytes(Data("OKAY".utf8), thenClose: true) : FakeAdbServer.shell()
                }
                return FakeAdbServer.shell(stderr: "unexpected \(command)", status: 1)
            }
        }
    }

    static func directory() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-postures-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    static func host(_ phone: Phone, records: String?) throws -> AndroidHost {
        let server = FakeAdbServer(handler: { request in
            if request.service == "host:devices-l" {
                let row = phone.connected ? "\(serial)             device usb:1-1 product:q2q model:SM_F000 device:q2q transport_id:7\n" : ""
                return FakeAdbServer.okay(payload: row)
            }
            return FakeAdbServer.devices([serial], host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang }) { _, service in phone.reply(service) }(request)
        })
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.postureRecordDirectory = { _ in records }
        return host
    }

    @Test("closing a phone records the override with the phone's boot before setting it, and reset drops both")
    func closeRecordsThenReset() async throws {
        let phone = Phone()
        let records = try Self.directory()
        let backend = AndroidBackend(host: try Self.host(phone, records: records)) { _, _ in }
        try await backend.requestPosture(.closed, on: Self.phone)
        #expect(phone.currentOverride == 0)
        let record = try #require(AndroidPostureRecordStore(directory: records).load(serial: Self.serial))
        #expect(record == AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        let boot = try #require(phone.commands.firstIndex(of: AndroidPostureRecord.bootIDScript))
        let set = try #require(phone.commands.firstIndex(of: "cmd device_state state 0"))
        #expect(boot < set)

        #expect(try await backend.resetPosture(on: Self.phone))
        #expect(phone.currentOverride == nil)
        #expect(AndroidPostureRecordStore(directory: records).load(serial: Self.serial) == nil)
        #expect(try await backend.resetPosture(on: Self.phone) == false)
    }

    @Test("opening a phone Offsider closed resets the override instead of stacking another, and keeps no record")
    func openResets() async throws {
        let phone = Phone()
        let records = try Self.directory()
        let backend = AndroidBackend(host: try Self.host(phone, records: records)) { _, _ in }
        try await backend.requestPosture(.closed, on: Self.phone)
        try await backend.requestPosture(.open, on: Self.phone)
        #expect(phone.currentOverride == nil)
        #expect(phone.commands.contains(AndroidDeviceState.resetState))
        #expect(AndroidPostureRecordStore(directory: records).load(serial: Self.serial) == nil)
    }

    @Test("a reset the phone refuses keeps the record, so session stop can still take the override off")
    func refusedResetKeepsRecord() async throws {
        let phone = Phone()
        let records = try Self.directory()
        let backend = AndroidBackend(host: try Self.host(phone, records: records)) { _, _ in }
        try await backend.requestPosture(.closed, on: Self.phone)
        phone.refusesChange = true
        await #expect(throws: AndroidError.self) { try await backend.requestPosture(.open, on: Self.phone) }
        #expect(phone.currentOverride == 0)
        #expect(AndroidPostureRecordStore(directory: records).load(serial: Self.serial)?.identifier == 0)
    }

    @Test("a set the phone refuses puts back the record of the override still in place, and leaves none when there was none")
    func refusedSetRestores() async throws {
        let phone = Phone()
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        let backend = AndroidBackend(host: try Self.host(phone, records: records)) { _, _ in }
        phone.refusesChange = true
        await #expect(throws: AndroidError.self) { try await backend.requestPosture(.closed, on: Self.phone) }
        #expect(store.load(serial: Self.serial) == nil)

        phone.refusesChange = false
        try await backend.requestPosture(.closed, on: Self.phone)
        phone.refusesChange = true
        await #expect(throws: AndroidError.self) { try await backend.requestPosture(.halfOpened, on: Self.phone) }
        #expect(phone.currentOverride == 0)
        #expect(store.load(serial: Self.serial)?.identifier == 0)
    }

    @Test("a set that throws: the phone's own reading decides which record stands")
    func thrownSetAsksThePhone() async throws {
        let store = { (records: String) in AndroidPostureRecordStore(directory: records) }

        let landed = Phone(override: 0)
        let landedRecords = try Self.directory()
        try store(landedRecords).save(AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        landed.dropsAfterSet = true
        let first = AndroidBackend(host: try Self.host(landed, records: landedRecords)) { _, _ in }
        await #expect(throws: (any Error).self) { try await first.requestPosture(.halfOpened, on: Self.phone) }
        #expect(landed.currentOverride == 2)
        #expect(store(landedRecords).load(serial: Self.serial)?.identifier == 2, "the set landed, so its record stands and session stop still matches")

        let missed = Phone(override: 0)
        let missedRecords = try Self.directory()
        try store(missedRecords).save(AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        missed.dropsBeforeSet = true
        let second = AndroidBackend(host: try Self.host(missed, records: missedRecords)) { _, _ in }
        await #expect(throws: (any Error).self) { try await second.requestPosture(.halfOpened, on: Self.phone) }
        #expect(missed.currentOverride == 0)
        #expect(store(missedRecords).load(serial: Self.serial)?.identifier == 0, "the set never landed, so the earlier record is back")
    }

    @Test("without a place to record it, a phone's posture is refused and nothing is set")
    func noRecordNoOverride() async throws {
        let phone = Phone()
        let backend = AndroidBackend(host: try Self.host(phone, records: nil)) { _, _ in }
        await #expect(throws: AndroidError.self) { try await backend.requestPosture(.closed, on: Self.phone) }
        #expect(phone.currentOverride == nil)
        #expect(!phone.commands.contains { $0.hasPrefix("cmd device_state state ") && $0 != AndroidDeviceState.readState })
    }

    @Test("session stop resets the override Offsider recorded, and only while it is still that one on the same boot")
    func cleanUp() async throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        let ours = AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0)

        let set = Phone(override: 0)
        try store.save(ours)
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(set, records: records)) == RecordResetOutcome(reset: [Self.serial]))
        #expect(set.currentOverride == nil && store.load(serial: Self.serial) == nil)

        let changed = Phone(override: 2)
        try store.save(ours)
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(changed, records: records), serial: Self.serial) == RecordResetOutcome())
        #expect(changed.currentOverride == 2 && store.load(serial: Self.serial) == nil)

        let rebooted = Phone(override: 0, bootID: "4f1d2b8e-0000-4000-8000-000000000002")
        try store.save(ours)
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(rebooted, records: records)) == RecordResetOutcome())
        #expect(rebooted.currentOverride == 0 && store.load(serial: Self.serial) == nil)

        let unplugged = Phone(override: 0)
        unplugged.connected = false
        try store.save(ours)
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(unplugged, records: records)) == RecordResetOutcome(notConnected: [Self.serial]))
        #expect(store.load(serial: Self.serial) == ours)

        let refusing = Phone(override: 0)
        refusing.refusesChange = true
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(refusing, records: records)) == RecordResetOutcome(failed: [Self.serial]))
        #expect(refusing.currentOverride == 0 && store.load(serial: Self.serial) == ours)
    }

    @Test("a phone not seen for over a month has rebooted long since, so its record goes rather than being named on every stop")
    func oldRecordForgotten() async throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        try store.save(AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        let path = (records as NSString).appendingPathComponent(AndroidPostureRecord.fileName(serial: Self.serial))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -AndroidPostureRecordStore.forgottenAfter - 60)], ofItemAtPath: path)
        let unplugged = Phone(override: 0)
        unplugged.connected = false
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(unplugged, records: records)) == RecordResetOutcome())
        #expect(store.load(serial: Self.serial) == nil)
    }

    @Test("a phone no longer allowed and gone for over a month goes too; one still connected, or recent, stays named and is sent nothing")
    func oldSkippedRecordForgotten() async throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        try store.save(AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        let path = (records as NSString).appendingPathComponent(AndroidPostureRecord.fileName(serial: Self.serial))
        let phone = Phone(override: 0)
        phone.connected = false
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(phone, records: records), permits: { _ in false }) == RecordResetOutcome(skipped: [Self.serial]))

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -AndroidPostureRecordStore.forgottenAfter - 60)], ofItemAtPath: path)
        phone.connected = true
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(phone, records: records), permits: { _ in false }) == RecordResetOutcome(skipped: [Self.serial]))
        #expect(phone.commands.isEmpty)

        phone.connected = false
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(phone, records: records), permits: { _ in false }) == RecordResetOutcome())
        #expect(store.load(serial: Self.serial) == nil)
    }

    @Test("with no adb server, a recorded override is kept and named as not connected, and adb is not started")
    func noServerKeepsRecord() async throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        let ours = AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0)
        try store.save(ours)
        let server = FakeAdbServer(connect: .refuse, handler: { _ in .hang })
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.postureRecordDirectory = { _ in records }
        #expect(await AndroidBackend.resetRecordedPostures(host: host) == RecordResetOutcome(notConnected: [Self.serial]))
        #expect(store.load(serial: Self.serial) == ours)
    }

    @Test("a phone the caller does not permit is sent nothing and keeps its record")
    func unpermittedPhoneUntouched() async throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        let ours = AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0)
        try store.save(ours)
        let phone = Phone(override: 0)
        #expect(await AndroidBackend.resetRecordedPostures(host: try Self.host(phone, records: records), permits: { _ in false }) == RecordResetOutcome(skipped: [Self.serial]))
        #expect(phone.currentOverride == 0 && phone.commands.isEmpty)
        #expect(store.load(serial: Self.serial) == ours)
    }

    @Test("every record reads the same way: a corrupt one goes and a good one stays")
    func allSweeps() throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        let good = AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0)
        try store.save(good)
        try OffsiderPrivateDirectory.writeAtomically(Data("not json".utf8), named: "0000000000000000.json", in: records)
        #expect(store.all() == [good])
        #expect(!FileManager.default.fileExists(atPath: (records as NSString).appendingPathComponent("0000000000000000.json")))
    }

    @Test("a record names its phone only through a hash, and a tampered or foreign one is not read")
    func recordFile() throws {
        let records = try Self.directory()
        let store = AndroidPostureRecordStore(directory: records)
        try store.save(AndroidPostureRecord(serial: Self.serial, bootID: Self.boot, identifier: 0))
        let names = try FileManager.default.contentsOfDirectory(atPath: records)
        #expect(names.count == 1 && !names[0].contains(Self.serial))
        try Data(#"{"serial":"OTHER","bootID":"x","identifier":0,"name":"CLOSE"}"#.utf8).write(to: URL(fileURLWithPath: records).appendingPathComponent(names[0]))
        #expect(store.load(serial: Self.serial) == nil)
    }
}
