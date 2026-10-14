import Darwin
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// A seal kept in memory, so tests never touch the login Keychain.
final class MemorySeal: DeviceAllowListSealing, @unchecked Sendable {
    private let lock = NSLock()
    private var digest: Data?

    init(sealing data: Data? = nil) {
        digest = data.map { Self.digest(of: $0) }
    }

    func storedDigest() throws -> Data? { lock.withLock { digest } }
    func store(digest: Data) throws { lock.withLock { self.digest = digest } }
}

final class RecordingPresence: PresenceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reasons: [String] = []
    let failure: (any Error)?

    init(failing failure: (any Error)? = nil) {
        self.failure = failure
    }

    func confirm(reason: String) async throws {
        lock.withLock { reasons.append(reason) }
        if let failure { throw failure }
    }
}

/// A pseudo-terminal whose far end types once the prompt switches echo off.
final class AccessTerminal: @unchecked Sendable {
    let primary: Int32
    let secondary: Int32

    init() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { throw POSIXError(.ENOTTY) }
        self.primary = primary
        self.secondary = secondary
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while read(primary, &buffer, buffer.count) > 0 {}
        }
    }

    /// Sends each answer after the prompt has gone raw again.
    func type(_ answers: [String]) {
        Thread.detachNewThread { [self] in
            for answer in answers {
                var settings = termios()
                for _ in 0..<5000 {
                    if tcgetattr(secondary, &settings) == 0, settings.c_lflag & tcflag_t(ECHO) == 0 { break }
                    usleep(1000)
                }
                usleep(20_000)
                _ = answer.withCString { write(primary, $0, strlen($0)) }
            }
        }
    }

    deinit {
        close(secondary)
        close(primary)
    }
}

@Suite("device-access", .serialized)
@MainActor
struct DeviceAccessCommandTests {
    static let row = DeviceSummary(
        id: PolicyFixtures.phone, platform: .ios, state: "Booted", name: "Test iPhone", osVersion: "iOS 27.2", deviceType: "iPhone 17 Pro", kind: .physical, connection: "usb"
    )

    static func context(home: String, seal: MemorySeal, terminal: AccessTerminal? = nil, stopped: @escaping @Sendable (String) -> [String] = { _ in [] }) -> DeviceAccessContext {
        DeviceAccessContext(
            store: { DeviceAllowListStore(directory: UserConfigDirectory(home: home)) },
            seal: seal,
            managed: FakeManagedPreferences(),
            now: { PolicyFixtures.now },
            physicalDevices: { [row] },
            stopSessions: { stopped($0) },
            promptDescriptor: terminal?.secondary
        )
    }

    static func file(_ home: String) -> String { home + "/.config/offsider/allowed-devices.json" }

    @Test("allow without a terminal fails with person_required and writes nothing")
    func allowNeedsTerminal() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone])
        let error = await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ false }) {
                try await PersonPresence.$current.withValue(presence) {
                    _ = try await command.perform(context: Self.context(home: home, seal: MemorySeal()))
                }
            }
        }
        #expect(error?.reason == .personRequired)
        #expect(error?.exitCode == .failure)
        #expect(error?.userFacingDescription.contains("`offsider device-access allow --device \(PolicyFixtures.phone)`") == true)
        #expect(presence.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.file(home)))
    }

    @Test("allow writes the entry only after the right suffix and the presence check, then seals it")
    func allowWritesAfterSuffixAndPresence() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["0000\r", "0ABC\r"])
        let seal = MemorySeal()
        let presence = RecordingPresence()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone.lowercased(), "--app", "com.mpalmes.offsider.playground", "--expires", "2h"])
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(presence) {
                try await command.perform(context: Self.context(home: home, seal: seal, terminal: terminal))
            }
        }
        #expect(output.hasPrefix("Allowed Test iPhone (\(PolicyFixtures.phone)) until 2026-09-21T16:14:20Z for com.mpalmes.offsider.playground."))
        #expect(presence.reasons == ["allow Offsider to drive Test iPhone (\(PolicyFixtures.phone))"])
        let snapshot = try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).load()
        #expect(snapshot.list.entries.map(\.apps) == [["com.mpalmes.offsider.playground"]])
        #expect(seal.isIntact(snapshot))
        let policy = DevicePolicyGate.read(store: DeviceAllowListStore(directory: UserConfigDirectory(home: home)), seal: seal, managed: FakeManagedPreferences())
        #expect(policy.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .allowed(snapshot.list.entries[0]))
    }

    @Test("allow --team records the iPhone's runner team, sealed with the entry")
    func allowRecordsTeam() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["0ABC\r"])
        let seal = MemorySeal()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone, "--team", "ABCDE12345"])
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(RecordingPresence()) {
                try await command.perform(context: Self.context(home: home, seal: seal, terminal: terminal))
            }
        }
        #expect(output.contains("Team ABCDE12345 signs Offsider's runner app on it."))
        let snapshot = try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).load()
        #expect(snapshot.list.entries.map(\.team) == ["ABCDE12345"])
        #expect(seal.isIntact(snapshot))
    }

    @Test("--team takes only a 10-character team ID", arguments: ["ABC", "ABCDE-1234", "ABCDE123456"])
    func teamValidated(team: String) {
        #expect(throws: (any Error).self) { _ = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone, "--team", team]) }
    }

    @Test("a failed presence check writes nothing")
    func presenceFailureWritesNothing() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["0abc\r"])
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone])
        let error = await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(RecordingPresence(failing: PersonPresence.error(for: .userCancel))) {
                    _ = try await command.perform(context: Self.context(home: home, seal: MemorySeal(), terminal: terminal))
                }
            }
        }
        #expect(error?.reason == .personRequired)
        #expect(!FileManager.default.fileExists(atPath: Self.file(home)))
    }

    @Test("an edit made outside Offsider breaks the seal, so the gate refuses until allow runs again")
    func tamperedListRefused() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        let seal = MemorySeal()
        try store.update({ $0.list.adding(PolicyFixtures.entry(.android, key: PolicyFixtures.serial)) }, commit: { try seal.seal($0) })
        let forged = DeviceAllowList(entries: [PolicyFixtures.entry(.android, key: PolicyFixtures.serial), PolicyFixtures.entry()]).encoded()
        try OffsiderPrivateDirectory.writeAtomically(forged, named: DeviceAllowListStore.fileName, in: home + "/.config/offsider")

        let policy = DevicePolicyGate.read(store: store, seal: seal, managed: FakeManagedPreferences())
        #expect(policy.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .refused(.listChanged))
        let error = #expect(throws: CLIError.self) { try DevicePolicyGate.fixed(policy, now: PolicyFixtures.now).require(platform: .ios, key: PolicyFixtures.phone) }
        #expect(error?.reason == .deviceNotAllowed)
        #expect(error?.userFacingDescription.contains("changed outside Offsider") == true)
        #expect(error?.hint == "offsider device-access allow --device \(PolicyFixtures.phone)")

        let unsealed = DevicePolicyGate.read(store: store, seal: MemorySeal(), managed: FakeManagedPreferences())
        #expect(unsealed.decision(platform: .android, key: PolicyFixtures.serial, now: PolicyFixtures.now) == .refused(.listChanged))
    }

    @Test("remove needs no terminal, withdraws the device, reseals and stops its sessions")
    func removeWithoutTerminal() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        let seal = MemorySeal()
        try store.update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
        let command = try DeviceAccessRemove.parse(["--device", PolicyFixtures.phone])
        let output = try await PersonPresence.$terminal.withValue({ false }) {
            try await command.perform(context: Self.context(home: home, seal: seal) { _ in ["session broker", "runner"] })
        }
        #expect(output == "Removed Test iPhone (\(PolicyFixtures.phone)) from the allow-list; Offsider will not drive it again until a person allows it. Stopped its session broker and runner.")
        let snapshot = try store.load()
        #expect(snapshot.list.entries.isEmpty)
        #expect(seal.isIntact(snapshot))
    }

    @Test("status --device exits 7 with device_not_allowed for a device no one allowed, and 0 for one that is")
    func statusExitCodes() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let refused = try DeviceAccessStatus.parse(["--device", PolicyFixtures.phone, "--json"]).perform(context: Self.context(home: home, seal: seal))
        #expect(refused.1?.reason == .deviceNotAllowed)
        #expect(refused.1?.exitCode == .deviceUnavailable)
        #expect(refused.1?.userFacingDescription.contains("`offsider device-access allow --device \(PolicyFixtures.phone)`") == true)
        #expect(refused.0.contains("\"allowed\": false"))

        try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
        let allowed = try DeviceAccessStatus.parse(["--device", PolicyFixtures.phone]).perform(context: Self.context(home: home, seal: seal))
        #expect(allowed.1 == nil)
        #expect(allowed.0.hasSuffix("\(PolicyFixtures.phone) is allowed until 2026-09-21T15:13:20Z.\n"))
    }

    @Test("--expires takes minutes, hours, days up to 30 or never")
    func expiry() throws {
        #expect(try DeviceAccessCommand.expiry("12h") == 43_200)
        #expect(try DeviceAccessCommand.expiry("30d") == 2_592_000)
        #expect(try DeviceAccessCommand.expiry("never") == nil)
        for bad in ["31d", "0h", "12", "h", "-1m", "soon"] {
            #expect(throws: (any Error).self) { try DeviceAccessCommand.expiry(bad) }
        }
    }

    @Test("a simulator or emulator ID is refused: they need no allowance")
    func virtualRefused() {
        #expect(throws: CLIError.self) { try DeviceAccessCommand.physicalKey("ABCDEF00-0000-4000-8000-00000000ABCD") }
        #expect(throws: CLIError.self) { try DeviceAccessCommand.physicalKey("emulator-5554") }
    }
}
