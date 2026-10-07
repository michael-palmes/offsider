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
        #expect(shown == #"{"version":1,"leases":[{"platform":"android","device":"Offsider_E2E","label":"PR 123","since":"2026-09-21T14:13:20Z","expiresAt":"2026-09-21T18:13:20Z"}]}"#)
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

    @Test("doctor's lease check passes when free or this session's, warns for another session, and names a lock holder")
    func doctorVerdicts() {
        let lease = DeviceLease(label: "PR 123", created: Self.now, expires: Self.now.addingTimeInterval(3600), pid: 1)
        #expect(DeviceLeaseRules.lease(nil, sessionLabel: nil, holder: nil) == (.pass, "Not leased", nil))
        #expect(DeviceLeaseRules.lease(lease, sessionLabel: "PR 123", holder: nil).status == .pass)
        let other = DeviceLeaseRules.lease(lease, sessionLabel: "PR 456", holder: DeviceLockHolder(pid: 42, command: "tap", startedAt: nil))
        #expect(other.status == .warn)
        #expect(other.detail.hasPrefix("Leased to another session: 'PR 123' since "))
        #expect(other.detail.hasSuffix("; held now by pid 42 (offsider tap)"))
        #expect(other.hint?.contains("offsider list-devices") == true)
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
