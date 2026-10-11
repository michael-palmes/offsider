import ArgumentParser
import Foundation
@testable import OffsiderCore
import Testing
@testable import Offsider

@Suite("lease")
struct LeaseCommandTests {
    static let avd = (platform: DevicePlatform.android, key: "Offsider_E2E")
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func store() throws -> DeviceLeaseStore {
        DeviceLeaseStore(root: try makePrivateLockRoot())
    }

    static func set(_ label: String, store: DeviceLeaseStore, at now: Date = now, minutes: Int = 240, force: Bool = false, json: Bool = false) throws -> String {
        try LeaseCommand.perform(.set, target: avd, label: label, minutes: minutes, force: force, json: json, store: store, now: now, pid: 77)
    }

    @Test("set, show and release round-trip, keyed by the AVD name")
    func roundTrip() throws {
        let store = try Self.store()
        let text = try Self.set("PR 123", store: store)
        #expect(text.hasPrefix("Leased Offsider_E2E to 'PR 123' until "))
        #expect(text.hasSuffix("Run `export OFFSIDER_LEASE='PR 123'` so `offsider doctor` knows this session holds it."))
        let shown = try LeaseCommand.perform(.show, target: nil, label: nil, minutes: 0, force: false, json: true, store: store, now: Self.now, pid: 0)
        #expect(shown == #"{"version":1,"leases":[{"platform":"android","device":"Offsider_E2E","label":"PR 123","since":"2026-09-21T14:13:20Z","expiresAt":"2026-09-21T18:13:20Z","owner":null}]}"#)
        let released = try LeaseCommand.perform(.release, target: Self.avd, label: nil, minutes: 0, force: false, json: true, store: store, now: Self.now, pid: 0)
        #expect(released.contains(#""action":"release","platform":"android","device":"Offsider_E2E","lease":{"label":"PR 123""#))
        #expect(store.lease(platform: .android, key: Self.avd.key, now: Self.now) == nil)
        #expect(try LeaseCommand.perform(.release, target: Self.avd, label: nil, minutes: 0, force: false, json: false, store: store, now: Self.now, pid: 0) == "Offsider_E2E was not leased.")
    }

    @Test("another label's live lease is refused with device_leased (exit 8) unless --force")
    func conflict() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store)
        do {
            _ = try Self.set("PR 456", store: store)
            Issue.record("expected device_leased")
        } catch let error as CLIError {
            #expect(error.reason == .deviceLeased)
            #expect(error.exitCode == .deviceBusy)
            #expect(error.userFacingDescription.hasPrefix("Offsider_E2E is leased to 'PR 123' since "))
            #expect(error.hint == "offsider lease show --device Offsider_E2E")
        }
        #expect(store.lease(platform: .android, key: Self.avd.key, now: Self.now)?.label == "PR 123")
        _ = try Self.set("PR 456", store: store, force: true)
        #expect(store.lease(platform: .android, key: Self.avd.key, now: Self.now)?.label == "PR 456")
    }

    @Test("the same label renews: the start stays and the expiry moves")
    func renew() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store)
        let later = Self.now.addingTimeInterval(600)
        let text = try Self.set("PR 123", store: store, at: later, minutes: 60)
        #expect(text.hasPrefix("Renewed the lease on Offsider_E2E to 'PR 123'"))
        let lease = try #require(store.lease(platform: .android, key: Self.avd.key, now: later))
        #expect(lease.created == Self.now)
        #expect(lease.expires == later.addingTimeInterval(3600))
    }

    @Test("an expired lease is pruned when read, so another label may take the device")
    func expiry() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store, minutes: 1)
        let later = Self.now.addingTimeInterval(61)
        #expect(store.all(now: later).isEmpty)
        _ = try Self.set("PR 456", store: store, at: later)
        #expect(store.lease(platform: .android, key: Self.avd.key, now: later)?.label == "PR 456")
    }

    @Test("of two setters racing for a free device, the second waits for the first's write and is refused with device_leased")
    func concurrentSetters() throws {
        let root = try makePrivateLockRoot()
        let first = DeviceLeaseStore(root: root)
        let second = DeviceLeaseStore(root: root)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let outcomes = LeaseOutcomes()
        let group = DispatchGroup()
        func claim(_ label: String, _ existing: DeviceLease?) throws -> DeviceLease {
            try LeaseCommand.claim(existing, key: Self.avd.key, label: label, minutes: 240, force: false, now: Self.now, pid: 77)
        }

        DispatchQueue.global().async(group: group) {
            outcomes.record("PR 123") {
                try first.set(platform: .android, key: Self.avd.key, now: Self.now) { existing in
                    entered.signal()
                    release.wait()
                    return try claim("PR 123", existing)
                }
            }
        }
        entered.wait()
        DispatchQueue.global().async(group: group) {
            outcomes.record("PR 456") { try second.set(platform: .android, key: Self.avd.key, now: Self.now) { try claim("PR 456", $0) } }
        }
        Thread.sleep(forTimeInterval: 0.3)
        release.signal()
        group.wait()

        #expect(outcomes.winners == ["PR 123"])
        #expect(outcomes.refusals == [.deviceLeased])
        #expect(first.lease(platform: .android, key: Self.avd.key, now: Self.now)?.label == "PR 123")
    }

    @Test("a reader removing a lease it saw expire never deletes the fresh lease written after its read")
    func expiredRemovalKeepsFreshLease() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store, minutes: 1)
        let later = Self.now.addingTimeInterval(61)
        _ = try Self.set("PR 456", store: store, at: later)

        store.removeExpired(named: DeviceLeaseStore.fileName(platform: .android, key: Self.avd.key), now: later)

        #expect(store.lease(platform: .android, key: Self.avd.key, now: later)?.label == "PR 456")
    }

    @Test("usage errors exit 64", arguments: [
        (["lease", "set", "--device", "Pixel_9"], "lease set needs --label <text>"),
        (["lease", "set", "--device", "Pixel_9", "--label", ""], "--label must be 1 to 80 printable characters."),
        (["lease", "set", "--device", "Pixel_9", "--label", String(repeating: "x", count: 81)], "--label must be 1 to 80 printable characters."),
        (["lease", "set", "--device", "Pixel_9", "--label", "x", "--ttl", "0"], "--ttl must be from 1 to 1440 minutes; got 0."),
        (["lease", "set", "--device", "Pixel_9", "--label", "x", "--ttl", "1441"], "--ttl must be from 1 to 1440 minutes; got 1441."),
        (["lease", "show", "--label", "x"], "--label goes with set, not show."),
        (["lease", "release", "--force", "--device", "Pixel_9"], "--force goes with set, not release."),
        (["lease", "grab", "--device", "Pixel_9"], "Unknown action 'grab'. Use set, release or show."),
    ])
    func usage(arguments: [String], message: String) {
        do {
            _ = try OffsiderCommand.parseAsRoot(arguments)
            Issue.record("expected a usage error for \(arguments)")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains(message), "\(OffsiderCommand.message(for: error))")
        }
    }

    @Test("set and release need a device, from --device or OFFSIDER_DEVICE; show lists every lease whatever OFFSIDER_DEVICE says")
    func deviceSource() throws {
        try DeviceDefault.$environment.withValue({ nil }) {
            #expect(throws: (any Error).self) { try OffsiderCommand.parseAsRoot(["lease", "release"]) }
        }
        try DeviceDefault.$environment.withValue({ "Pixel_9" }) {
            let release = try #require(try OffsiderCommand.parseAsRoot(["lease", "release"]) as? LeaseCommand)
            #expect(release.device == "Pixel_9")
            let show = try #require(try OffsiderCommand.parseAsRoot(["lease", "show"]) as? LeaseCommand)
            #expect(show.device == nil)
        }
    }

    @Test("stable keys: an emulator serial resolves to its AVD, a phone keeps its serial, a UDID is uppercased")
    func stableKeys() {
        #expect(StableDeviceKey.of(BootedDevice(id: DeviceID(rawValue: "emulator-5554", platform: .android), name: "Offsider_E2E")) == "Offsider_E2E")
        #expect(StableDeviceKey.of(BootedDevice(id: DeviceID(rawValue: "emulator-5554", platform: .android), name: "emulator-5554")) == nil)
        #expect(StableDeviceKey.of(id: "ZY22FAKE01")! == (.android, "ZY22FAKE01"))
        #expect(StableDeviceKey.of(id: "abcdef00-0000-4000-8000-00000000abcd")! == (.ios, "ABCDEF00-0000-4000-8000-00000000ABCD"))
        #expect(StableDeviceKey.of(id: "emulator-5554") == nil)
    }

    @Test("list-devices shows a lease on the emulator running its AVD and on the shut-down AVD row")
    func listDevicesLease() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store)
        let running = DeviceSummary(id: "emulator-5554", platform: .android, state: "Booted", name: "Offsider_E2E", osVersion: nil, deviceType: nil, kind: .emulator, avd: "Offsider_E2E")
        let other = DeviceSummary(id: "emulator-5556", platform: .android, state: "Booted", name: "Work", osVersion: nil, deviceType: nil, kind: .emulator, avd: "Work")
        let rows = ListDevices.withLeases([running, other], store: store, now: Self.now)
        #expect(rows[0].lease?.label == "PR 123")
        #expect(rows[1].lease == nil)
        #expect(ListDevices.leaseNotes(rows).count == 1)
        #expect(ListDevices.leaseNotes(rows)[0].hasPrefix("emulator-5554 is leased to 'PR 123' until "))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceListRenderer.json(rows).utf8)) as? [String: Any])
        let lease = try #require((object["devices"] as? [[String: Any]])?.first?["lease"] as? [String: Any])
        #expect(lease["label"] as? String == "PR 123")
        #expect(lease["expiresAt"] as? String == "2026-09-21T18:13:20Z")
    }

    @Test("doctor's lease check passes when free or OFFSIDER_LEASE matches, warns when it names another label, and names a lock holder")
    func doctorVerdicts() {
        let lease = DeviceLease(label: "PR 123", created: Self.now, expires: Self.now.addingTimeInterval(3600), pid: 1)
        func verdict(_ lease: DeviceLease?, _ label: String?, holder: DeviceLockHolder? = nil) -> DoctorRules.Verdict {
            DeviceLeaseRules.lease(lease, device: Self.avd.key, sessionLabel: label, ancestors: [], processes: FakeProcesses().processTable, holder: holder)
        }
        #expect(verdict(nil, nil) == (.pass, "Not leased", nil))
        #expect(verdict(lease, "PR 123").status == .pass)
        let other = verdict(lease, "PR 456", holder: DeviceLockHolder(pid: 42, command: "tap", startedAt: nil))
        #expect(other.status == .warn)
        #expect(other.detail.hasPrefix("Leased to another session: 'PR 123' since "))
        #expect(other.detail.hasSuffix("; held now by pid 42 (offsider tap)"))
        #expect(other.hint?.contains("offsider list-devices") == true)
    }

    // MARK: Session owner

    /// `lease set` run by the session `node` (100) through `zsh` (200), as `FakeProcesses` scripts them.
    static func setBySession(_ label: String = "PR 123", store: DeviceLeaseStore, processes: FakeProcesses, shell: Int32 = 200, at now: Date = now, json: Bool = false) throws -> String {
        try LeaseCommand.perform(
            .set, target: avd, label: label, minutes: 240, force: false, json: json, store: store, now: now, pid: shell,
            owner: ProcessAncestry.owner(from: shell, in: processes.processTable)
        )
    }

    /// Doctor's `device.lease` as a command running at `selfPID` sees it.
    static func doctor(_ store: DeviceLeaseStore, processes: FakeProcesses, selfPID: Int32, sessionLabel: String? = nil) -> DoctorCheckResult {
        Doctor.leaseCheck(
            platform: .android, key: avd.key, lockID: "emulator-5554", store: store, sessionLabel: sessionLabel,
            processes: processes.processTable, selfPID: selfPID, now: now, holder: { _ in nil }
        )
    }

    @Test("lease set records the session above its shell, says doctor will know it, and --json shows the owner")
    func setRecordsOwner() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        let text = try Self.setBySession(store: store, processes: processes)
        #expect(text.hasPrefix("Leased Offsider_E2E to 'PR 123' until "))
        #expect(text.hasSuffix(" for this session (node, pid 100); `offsider doctor` recognises it from any command this session runs. From another session, set OFFSIDER_LEASE='PR 123'."))
        let owner = try #require(store.lease(platform: .android, key: Self.avd.key, now: Self.now)?.owner)
        #expect(owner == ProcessIdentity(pid: 100, startTime: 100_000, name: "node"))

        let json = try Self.setBySession(store: store, processes: processes, json: true)
        #expect(json.hasSuffix(#""owner":{"pid":100,"name":"node","startedAt":"1970-01-01T00:00:00Z"}}}"#))
    }

    @Test("renewing with the same label from another session moves the lease to that session and keeps its start")
    func renewalMovesOwner() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        processes.add(pid: 500, name: "claude", parent: 1)
        processes.add(pid: 600, name: "zsh", parent: 500)
        _ = try Self.setBySession(store: store, processes: processes)
        let later = Self.now.addingTimeInterval(600)
        let text = try Self.setBySession(store: store, processes: processes, shell: 600, at: later)
        #expect(text.hasPrefix("Renewed the lease on Offsider_E2E to 'PR 123'"))
        #expect(text.contains("for this session (claude, pid 500)"))
        let lease = try #require(store.lease(platform: .android, key: Self.avd.key, now: later))
        #expect(lease.owner?.pid == 500)
        #expect(lease.created == Self.now)
    }

    @Test("a lease file keeps its owner across a write and read, and an older file without one parses with none")
    func ownerFileFormat() throws {
        let owner = ProcessIdentity(pid: 4242, startTime: 1_790_000_000_123_456, name: "claude")
        let lease = DeviceLease(label: "PR 123", created: Self.now, expires: Self.now.addingTimeInterval(60), pid: 77, owner: owner)
        #expect(DeviceLease.parse(lease.fileContents) == lease)
        let legacy = try #require(DeviceLease.parse("label=PR 123\ncreated=1790000000\nexpires=1790000060\npid=77\n"))
        #expect(legacy.owner == nil)
        #expect(legacy.label == "PR 123")
        #expect(DeviceLease.parse("label=PR 123\ncreated=1790000000\nexpires=1790000060\npid=77\nowner=garbled\n")?.owner == nil)
    }

    @Test("doctor passes a lease its own session set, from a later shell of that session with no OFFSIDER_LEASE")
    func doctorRecognisesOwnSession() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        _ = try Self.setBySession(store: store, processes: processes)
        processes.remove(pid: 200)
        processes.add(pid: 210, name: "zsh", parent: 100)
        processes.add(pid: 310, name: "offsider", parent: 210)
        let check = Self.doctor(store, processes: processes, selfPID: 310)
        #expect(check.status == .pass)
        #expect(check.detail.hasPrefix("This session's lease: 'PR 123' since "))
    }

    @Test("an OFFSIDER_LEASE naming another label warns even inside the session that set the lease")
    func sessionLabelBeatsOwner() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        _ = try Self.setBySession(store: store, processes: processes)
        let check = Self.doctor(store, processes: processes, selfPID: 300, sessionLabel: "PR 456")
        #expect(check.status == .warn)
        #expect(check.detail.hasPrefix("Leased to another session: 'PR 123' since "))
    }

    @Test("another live session's lease warns with its owner, and OFFSIDER_LEASE set to the label passes it")
    func doctorWarnsForOtherSession() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        processes.add(pid: 500, name: "claude", parent: 1)
        processes.add(pid: 600, name: "zsh", parent: 500)
        processes.add(pid: 700, name: "offsider", parent: 600)
        _ = try Self.setBySession(store: store, processes: processes)
        let check = Self.doctor(store, processes: processes, selfPID: 700)
        #expect(check.status == .warn)
        #expect(check.detail.hasPrefix("Leased to 'PR 123' by another session (node, pid 100) since "))
        #expect(check.hint == "If you set this lease, add OFFSIDER_LEASE='PR 123' to this command; otherwise choose another device from `offsider list-devices`.")
        #expect(Self.doctor(store, processes: processes, selfPID: 700, sessionLabel: "PR 123").status == .pass)
    }

    @Test("a lease whose session has ended, or whose pid now belongs to another process, says how to renew or take it")
    func doctorWarnsForEndedSession() throws {
        for reuse in [false, true] {
            let store = try Self.store()
            let processes = FakeProcesses()
            _ = try Self.setBySession(store: store, processes: processes)
            processes.remove(pid: 100)
            if reuse { processes.add(pid: 100, name: "node", parent: 1, startTime: 999) }
            processes.add(pid: 500, name: "claude", parent: 1)
            processes.add(pid: 600, name: "zsh", parent: 500)
            let check = Self.doctor(store, processes: processes, selfPID: 600)
            #expect(check.status == .warn)
            #expect(check.detail.hasPrefix("Leased to 'PR 123' by a session that has ended (node, pid 100) since "))
            #expect(check.hint == "If it was yours, `offsider lease set --device Offsider_E2E --label 'PR 123'` renews it for this session; otherwise `lease set --force` with your own label takes it over.")
        }
    }

    @Test("a lease from an older Offsider, with no owner, warns as another session's unless OFFSIDER_LEASE matches")
    func doctorLegacyLease() throws {
        let store = try Self.store()
        _ = try Self.set("PR 123", store: store)
        let processes = FakeProcesses()
        let check = Self.doctor(store, processes: processes, selfPID: 300)
        #expect(check.status == .warn)
        #expect(check.detail.hasPrefix("Leased to another session: 'PR 123' since "))
        #expect(Self.doctor(store, processes: processes, selfPID: 300, sessionLabel: "PR 123").status == .pass)
    }

    @Test("list-devices --json marks a lease mine only for the session that holds it")
    func listDevicesMine() throws {
        let store = try Self.store()
        let processes = FakeProcesses()
        processes.add(pid: 500, name: "claude", parent: 1)
        processes.add(pid: 600, name: "zsh", parent: 500)
        _ = try Self.setBySession(store: store, processes: processes)
        let row = DeviceSummary(id: "emulator-5554", platform: .android, state: "Booted", name: "Offsider_E2E", osVersion: nil, deviceType: nil, kind: .emulator, avd: "Offsider_E2E")
        func mine(selfPID: Int32, label: String? = nil) throws -> Bool? {
            let rows = ListDevices.withLeases([row], store: store, now: Self.now, sessionLabel: label, processes: processes.processTable, selfPID: selfPID)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceListRenderer.json(rows).utf8)) as? [String: Any])
            return ((object["devices"] as? [[String: Any]])?.first?["lease"] as? [String: Any])?["mine"] as? Bool
        }
        #expect(try mine(selfPID: 300) == true)
        #expect(try mine(selfPID: 600) == false)
        #expect(try mine(selfPID: 600, label: "PR 123") == true)
    }
}

/// Which labels a set of racing `lease set` calls left holding the device, and why the others were refused.
final class LeaseOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var won: [String] = []
    private var refused: [FailureReason?] = []

    func record(_ label: String, _ body: () throws -> Any) {
        do {
            _ = try body()
            lock.withLock { won.append(label) }
        } catch {
            lock.withLock { refused.append((error as? CLIError)?.reason) }
        }
    }

    var winners: [String] { lock.withLock { won } }
    var refusals: [FailureReason?] { lock.withLock { refused } }
}
