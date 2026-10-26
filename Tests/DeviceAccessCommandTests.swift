import ArgumentParser
import Darwin
import Foundation
@testable import Offsider
@testable import OffsiderCore
import OffsiderIOSDevice
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

/// A pseudo-terminal whose far end types once the prompt switches echo off, and keeps what the prompt drew.
final class AccessTerminal: @unchecked Sendable {
    let primary: Int32
    let secondary: Int32
    private let lock = NSLock()
    private var drawn = Data()
    private var secondaryOpen = true
    private let drained = DispatchSemaphore(value: 0)

    init() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { throw POSIXError(.ENOTTY) }
        self.primary = primary
        self.secondary = secondary
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = read(primary, &buffer, buffer.count)
                guard count > 0 else { break }
                lock.withLock { drawn.append(contentsOf: buffer[0..<count]) }
            }
            drained.signal()
        }
    }

    /// Closes this end once the prompt is done, waits for the reader to take everything the prompt drew, and returns it.
    func finish() -> String {
        closeSecondary()
        _ = drained.wait(timeout: .now() + PseudoTerminal.patience)
        return transcript
    }

    private func closeSecondary() {
        lock.withLock {
            guard secondaryOpen else { return }
            secondaryOpen = false
            close(secondary)
        }
    }

    /// Everything drawn so far, without escape sequences.
    var transcript: String {
        let text = lock.withLock { String(decoding: drawn, as: UTF8.self) }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func echoing(_ on: Bool, within seconds: TimeInterval) {
        var settings = termios()
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard tcgetattr(secondary, &settings) == 0 else { return }
            if (settings.c_lflag & tcflag_t(ECHO) != 0) == on { return }
            usleep(1000)
        } while Date() < deadline
    }

    /// Sends each answer after the prompt has gone raw again, then waits for it to leave raw mode.
    func type(_ answers: [String]) {
        Thread.detachNewThread { [self] in
            for answer in answers {
                // A key typed before the first raw switch is flushed, and a full parallel run can hold the prompt back for many seconds.
                echoing(false, within: PseudoTerminal.patience)
                usleep(20_000)
                _ = answer.withCString { write(primary, $0, strlen($0)) }
                echoing(true, within: 0.3)
            }
        }
    }

    deinit {
        closeSecondary()
        close(primary)
    }
}

/// A presence check that passes the first time and fails after.
final class OncePresence: PresenceChecking, @unchecked Sendable {
    private let calls = CallCounter()

    func confirm(reason: String) async throws {
        if calls.tick() > 0 { throw PersonPresence.error(for: .userCancel) }
    }
}

/// Counts calls from any thread.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    /// The number of calls before this one.
    func tick() -> Int { lock.withLock { defer { calls += 1 }; return calls } }
}

@Suite("devices add, remove and status", .serialized)
@MainActor
struct DeviceAccessCommandTests {
    static let row = DeviceSummary(
        id: PolicyFixtures.phone, platform: .ios, state: "Booted", name: "Test iPhone", osVersion: "iOS 27.2", deviceType: "iPhone 17 Pro", kind: .physical, connection: "usb"
    )

    static func context(
        home: String, seal: MemorySeal, terminal: AccessTerminal? = nil,
        devices: @escaping @Sendable () -> [DeviceSummary] = { [row] },
        teams: @escaping @Sendable () -> [SigningTeam] = { [] },
        apps: @escaping @Sendable (DeviceSummary) throws -> [InstalledApp] = { _ in [] },
        stopped: @escaping @Sendable (String) -> [String] = { _ in [] }
    ) -> DeviceAccessContext {
        DeviceAccessContext(
            store: { DeviceAllowListStore(directory: UserConfigDirectory(home: home)) },
            seal: seal,
            managed: FakeManagedPreferences(),
            now: { PolicyFixtures.now },
            physicalDevices: { (devices(), []) },
            stopSessions: { stopped($0) },
            signingTeams: teams,
            installedApps: { try apps($0) },
            promptDescriptor: terminal?.secondary,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    /// Runs `allow` with `answers` typed at the terminal and a presence check that passes.
    static func allow(_ arguments: [String], answers: [String], context: (AccessTerminal) -> DeviceAccessContext, presence: RecordingPresence = RecordingPresence()) async throws -> (output: String, transcript: String) {
        let terminal = try AccessTerminal()
        terminal.type(answers)
        let command = try DeviceAccessAllow.parse(arguments)
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(presence) {
                try await command.perform(context: context(terminal))
            }
        }
        return (output, terminal.finish())
    }

    static func entries(_ home: String) throws -> [DeviceAllowance] {
        try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).load().list.entries
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
        #expect(error?.userFacingDescription.contains("Ask the user to run `offsider devices add` in their own terminal.") == true)
        #expect(presence.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.file(home)))
    }

    @Test("add --device writes the entry after the presence check alone, asks nothing about the ID, then seals it")
    func allowWritesAfterPresence() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["\r"])
        let seal = MemorySeal()
        let presence = RecordingPresence()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone.lowercased(), "--app", "com.mpalmes.offsider.playground", "--expires", "2h"])
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(presence) {
                try await command.perform(context: Self.context(home: home, seal: seal, terminal: terminal))
            }
        }
        #expect(output.contains("Allowed Test iPhone until 16:14, com.mpalmes.offsider.playground only."))
        let closing = output.split(separator: "\n").suffix(2).map(String.init)
        #expect(closing.map { $0.trimmingCharacters(in: .whitespaces) } == [
            "Withdraw  offsider devices remove --device \(PolicyFixtures.phone)", "Next      offsider doctor --device \(PolicyFixtures.phone)",
        ])
        #expect(Set(closing.map { $0.prefix { $0 == " " }.count }).count == 1)
        let transcript = terminal.finish()
        #expect(!transcript.contains("of its ID"))
        #expect(transcript.contains("Test iPhone"))
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
        terminal.type(["\r", "\r", "\r"])
        let seal = MemorySeal()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone, "--team", "ABCDE12345"])
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(RecordingPresence()) {
                try await command.perform(context: Self.context(home: home, seal: seal, terminal: terminal))
            }
        }
        #expect(output.contains("Allowed Test iPhone until 22 Sep 02:14, any app."))
        let transcript = terminal.finish()
        #expect(transcript.contains("Test iPhone · any app · 12 hours · team ABCDE12345") || transcript.contains("Test iPhone - any app - 12 hours - team ABCDE12345"))
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
        terminal.type(["\r", "\r", "\r", "\r"])
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
        #expect(error?.hint == "offsider devices add")

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

    @Test("remove with no --device lets a person choose from the allowed devices, and withdraws only that one")
    func removePicksFromAllowed() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        let seal = MemorySeal()
        let pixel = DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test Pixel", added: PolicyFixtures.added, expires: nil, apps: [])
        try store.update({ $0.list.adding(PolicyFixtures.entry()).adding(pixel) }, commit: { try seal.seal($0) })
        let terminal = try AccessTerminal()
        terminal.type(["2"])
        var context = Self.context(home: home, seal: seal, terminal: terminal)
        context.interactive = { true }
        let removal = try await DeviceAccessRemove.parse([]).remove(context: context)
        let transcript = terminal.finish()
        #expect(transcript.contains(DeviceAccessRemove.removeQuestion))
        #expect(transcript.contains("Test Pixel") && transcript.contains("until removed"))
        #expect(removal.text.hasPrefix("Removed Test Pixel (\(PolicyFixtures.serial)) from the allow-list"))
        #expect(try store.load().list.entries.map(\.key) == [PolicyFixtures.phone])
    }

    @Test("remove with no --device and no terminal exits 64 and names where to find the ID")
    func removeNeedsDeviceWithoutTerminal() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        let seal = MemorySeal()
        try store.update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
        let error = await #expect(throws: CLIError.self) {
            _ = try await DeviceAccessRemove.parse([]).remove(context: Self.context(home: home, seal: seal))
        }
        #expect(error?.reason == .usage)
        #expect(error?.hint == "offsider devices status")
        #expect(try store.load().list.entries.count == 1)
    }

    @Test("remove with nothing allowed says so and changes nothing")
    func removeWithNothingAllowed() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var context = Self.context(home: home, seal: MemorySeal())
        context.interactive = { true }
        let removal = try await DeviceAccessRemove.parse([]).remove(context: context)
        #expect(removal.text == DeviceAccessRemove.nothingAllowed)
        #expect(!FileManager.default.fileExists(atPath: Self.file(home)))
    }

    @Test("status --device exits 7 with device_not_allowed for a device no one allowed, and 0 for one that is")
    func statusExitCodes() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let refused = try DeviceAccessStatus.parse(["--device", PolicyFixtures.phone, "--json"]).perform(context: Self.context(home: home, seal: seal))
        #expect(refused.1?.reason == .deviceNotAllowed)
        #expect(refused.1?.exitCode == .deviceUnavailable)
        #expect(refused.1?.userFacingDescription.contains("run `offsider devices add` in their own terminal and choose \(PolicyFixtures.phone)") == true)
        #expect(refused.1?.hint == "offsider devices add")
        #expect(refused.0.contains("\"allowed\": false"))

        try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
        let allowed = try DeviceAccessStatus.parse(["--device", PolicyFixtures.phone]).perform(context: Self.context(home: home, seal: seal))
        #expect(allowed.1 == nil)
        #expect(allowed.0.hasSuffix("\(PolicyFixtures.phone) is allowed until 2026-09-21T15:13:20Z.\n"))
    }

    @Test("--expires takes minutes, hours, days up to 30 or never")
    func expiry() throws {
        #expect(try DeviceAccess.expiry("12h") == 43_200)
        #expect(try DeviceAccess.expiry("30d") == 2_592_000)
        #expect(try DeviceAccess.expiry("never") == nil)
        for bad in ["31d", "0h", "12", "h", "-1m", "soon"] {
            #expect(throws: (any Error).self) { try DeviceAccess.expiry(bad) }
        }
    }

    static let wifiRow = DeviceSummary(
        id: "00008140-0000000000000DEF", platform: .ios, state: "Booted", name: "Wireless iPad", osVersion: "iOS 27.2", deviceType: "iPad Air", kind: .physical, connection: "network"
    )
    static let androidRow = DeviceSummary(
        id: PolicyFixtures.serial, platform: .android, state: "device", name: "Test Pixel", osVersion: "Android 16", deviceType: "Pixel 9", kind: .physical, connection: "usb"
    )

    @Test("picking the device, team and app from menus writes them, after the preamble and the steps in order")
    func menuPickWritesChoices() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let presence = RecordingPresence()
        let apps = [
            InstalledApp(id: "com.apple.mobilesafari", name: "Safari"),
            InstalledApp(id: "com.mpalmes.offsider.playground", name: "Offsider Playground"),
        ]
        let (output, transcript) = try await Self.allow([], answers: ["1", "\r", "1", "\r"], context: { terminal in
            Self.context(home: home, seal: seal, terminal: terminal, devices: { [Self.row, Self.wifiRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] }, apps: { _ in apps })
        }, presence: presence)
        let entry = try #require(try Self.entries(home).first)
        #expect(entry.team == "ABCDE12345")
        #expect(entry.apps == ["com.mpalmes.offsider.playground"])
        #expect(entry.expires == PolicyFixtures.now.addingTimeInterval(12 * 3_600))
        #expect(seal.isIntact(try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).load()))
        #expect(presence.reasons == ["allow Offsider to drive Test iPhone (\(PolicyFixtures.phone))"])
        #expect(output.contains("Next      offsider doctor --device \(PolicyFixtures.phone)"))
        #expect(!transcript.contains("Safari"))
        #expect(transcript.contains("📲  Wireless iPad  \(AllowScreen.wifiOnly)") || transcript.contains("[iPad]    Wireless iPad  \(AllowScreen.wifiOnly)"))
        for receipt in ["Device    Test iPhone", "Team      Example Team", "App       Offsider Playground", "How long  12 hours"] {
            #expect(transcript.contains(receipt))
        }
        let order = [
            AllowScreen.title, "1/4 \(AllowScreen.deviceQuestion)", "Device    Test iPhone", "2/4 \(AllowScreen.teamQuestion)", "Example Team  ABCDE12345 (Recommended)",
            "3/4 \(AllowScreen.appQuestion)", "4/4 \(AllowScreen.expiryQuestion)", "12 hours (Recommended)", "Allowed Test iPhone",
        ].map { transcript.range(of: $0).map { transcript.distance(from: transcript.startIndex, to: $0.lowerBound) } }
        #expect(!order.contains(nil))
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
    }

    @Test("the full ID shows only in the closing commands; rows show its last four characters")
    func fullIDOnlyAtTheEnd() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (_, transcript) = try await Self.allow([], answers: ["1", "\r", "\r", "\r", "\r", "2"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] })
        })
        let shown = transcript.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { $0.contains(PolicyFixtures.phone) || $0.contains(PolicyFixtures.serial) }
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { $0.hasSuffix("Withdraw  offsider devices remove --device \(PolicyFixtures.phone)") || $0.hasSuffix("Next      offsider doctor --device \(PolicyFixtures.phone)") })
        let ellipsis = TerminalStyle.detect(isTerminal: true).ellipsis
        #expect(transcript.contains("Test iPhone  \(ellipsis)\(PolicyFixtures.phone.suffix(4))"))
        #expect(transcript.contains("Test Pixel   \(ellipsis)\(PolicyFixtures.serial.suffix(4))"))
    }

    @Test("Q at the offer of another device ends the run, keeping the device already allowed")
    func quitAtTheNextDeviceKeepsTheFirst() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, transcript) = try await Self.allow([], answers: ["1", "\r", "1", "\r", "q"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] })
        })
        #expect(try Self.entries(home).map(\.key) == [PolicyFixtures.phone])
        #expect(output.contains("Allowed Test iPhone"))
        #expect(transcript.contains(AllowScreen.anotherQuestion))
        #expect(!transcript.contains(AllowScreen.cancelled))
    }

    @Test("after one device is allowed, the walkthrough offers the other connected one and allows it in the same run")
    func offersTheNextDevice() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        let (output, transcript) = try await Self.allow([], answers: ["1", "\r", "1", "\r", "1", "1", "\r"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] }, apps: { _ in [] })
        }, presence: presence)
        let entries = try Self.entries(home)
        #expect(entries.map(\.key).sorted() == [PolicyFixtures.phone, PolicyFixtures.serial].sorted())
        #expect(presence.reasons.count == 2)
        #expect(transcript.contains(AllowScreen.anotherQuestion))
        #expect(transcript.components(separatedBy: AllowScreen.anotherQuestion).count == 2)
        #expect(output.contains("Allowed Test iPhone") && output.contains("Allowed Test Pixel"))
    }

    @Test("Escape on a later device keeps the one already allowed: its receipt, one line saying it stays, and no error")
    func cancelLaterDeviceKeepsTheFirst() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, transcript) = try await Self.allow([], answers: ["1", "\r", "1", "\r", "1", "\u{1B}"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] })
        })
        #expect(try Self.entries(home).map(\.key) == [PolicyFixtures.phone])
        #expect(output.contains("Allowed Test iPhone"))
        #expect(transcript.contains("Cancelled; Test iPhone stays allowed."))
        #expect(!transcript.contains(AllowScreen.cancelled))
    }

    @Test("a later device that fails keeps the one already allowed, and the error says so with the failure's exit code")
    func failedLaterDeviceKeepsTheFirst() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["1", "\r", "1", "\r", "1", "1", "\r"])
        let context = Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] })
        let interrupted = await #expect(throws: DeviceAccessAllow.Interrupted.self) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(OncePresence()) {
                    _ = try await DeviceAccessAllow.parse([]).perform(context: context)
                }
            }
        }
        let failure = try #require(interrupted?.failure as? ReportedFailure)
        #expect(failure.exitCode == PersonPresence.error(for: .userCancel).exitCode)
        #expect(failure.userFacingDescription.hasSuffix("; Test iPhone stays allowed."))
        #expect(!failure.userFacingDescription.contains("Nothing saved"))
        #expect(interrupted?.output.contains("Allowed Test iPhone") == true)
        #expect(try Self.entries(home).map(\.key) == [PolicyFixtures.phone])
    }

    @Test("--team signs the iPhone and is skipped for a later Android phone, while --expires still applies to both")
    func teamSkippedForLaterPhone() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, _) = try await Self.allow(["--team", "ABCDE12345", "--expires", "2h"], answers: ["1", "1", "1", "1"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] })
        })
        let entries = try Self.entries(home)
        #expect(entries.first { $0.platform == .ios }?.team == "ABCDE12345")
        #expect(entries.first { $0.platform == .android }.map { $0.team == nil } == true)
        #expect(entries.allSatisfy { $0.expires == PolicyFixtures.now.addingTimeInterval(2 * 3_600) })
        #expect(output.contains("Allowed Test Pixel"))
    }

    @Test("a device and app named with escape sequences and newlines draw as one sanitised row, receipt and summary line each")
    func deviceTextIsSanitised() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let phone = DeviceSummary(
            id: PolicyFixtures.serial, platform: .android, state: "device", name: "Test\u{1B}[2J\nPixel", osVersion: "Android 16", deviceType: "Pixel 9", kind: .physical, connection: "usb"
        )
        let (output, transcript) = try await Self.allow([], answers: ["1", "1", "\r"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [phone] }, apps: { _ in [InstalledApp(id: "com.example.evil", name: "Evil\u{1B}]0;title\u{07}\nApp\u{202E}")] })
        })
        let lines = transcript.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        #expect(lines.contains { $0.contains("Evil?]0;title??App?") && $0.contains("com.example.evil") })
        #expect(lines.contains { $0.hasSuffix("App       Evil?]0;title??App?") })
        #expect(lines.contains { $0.contains("Test?[2J?Pixel") && $0.contains("com.example.evil only") && $0.hasSuffix("12 hours") })
        #expect(!transcript.contains("\u{1B}]0;title"))
        #expect(output.contains("Allowed Test?[2J?Pixel until"))
        #expect(try Self.entries(home).map(\.apps) == [["com.example.evil"]])
        #expect(try Self.entries(home).map(\.name) == ["Test?[2J?Pixel"])
    }

    @Test("the status screen and the device picker draw a device's own text with every control and bidi character as ?")
    func statusAndPickerSanitise() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let entry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test\u{2028}iPhone", added: PolicyFixtures.added, expires: nil, apps: ["com.example.app"])
        try Self.seed(home, seal: seal, [entry])
        let drawn = try await Self.status([], context: Self.context(home: home, seal: seal), person: true).out
        #expect(drawn.contains("Test?iPhone  com.example.app"))
        #expect(!drawn.contains("\u{2028}"))
        let simulator = DeviceSummary(id: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios, state: "Booted", name: "Sim\u{200F}\u{9B}31m", osVersion: "iOS\n27", deviceType: nil, kind: .simulator, connection: nil)
        #expect(DevicePickerScreen.deviceRow(simulator).columns == ["Sim??31m", "iOS?27"])
        #expect(DevicePickerScreen.using(simulator, style: .plain).hasPrefix("Using Sim??31m ·"))
    }

    @Test("Done ends the run with the one allowance, and a single connected device is never asked about")
    func doneEndsTheRun() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (_, transcript) = try await Self.allow([], answers: ["1", "\r", "1", "\r", "2"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] }, apps: { _ in [] })
        })
        #expect(try Self.entries(home).map(\.key) == [PolicyFixtures.phone])
        #expect(transcript.contains(AllowScreen.anotherQuestion))
        let single = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: single) }
        let (_, alone) = try await Self.allow([], answers: ["1", "\r", "1", "\r"], context: { terminal in
            Self.context(home: single, seal: MemorySeal(), terminal: terminal, devices: { [Self.row] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] }, apps: { _ in [] })
        })
        #expect(try Self.entries(single).count == 1)
        #expect(!alone.contains(AllowScreen.anotherQuestion))
    }

    @Test("a phone with no team step: three steps, and a failed app listing falls back to typing without failing the allow")
    func androidSkipsTeamAndSurvivesListingFailure() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let teamsRead = CallCounter()
        let (_, transcript) = try await Self.allow([], answers: ["1", "\r", "\r"], context: { terminal in
            Self.context(
                home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.androidRow] },
                teams: { _ = teamsRead.tick(); return [] },
                apps: { _ in throw CLIError(errorDescription: "The phone is locked.", reason: .commandFailed) }
            )
        })
        let entry = try #require(try Self.entries(home).first)
        #expect(entry.platform == .android)
        #expect(entry.apps.isEmpty)
        #expect(entry.team == nil)
        #expect(transcript.contains("1/3 \(AllowScreen.deviceQuestion)"))
        #expect(transcript.contains("2/3 App ID (Return for any app): "))
        #expect(transcript.contains("3/3 \(AllowScreen.expiryQuestion)"))
        #expect(!transcript.contains("Team"))
        #expect(teamsRead.count == 0)
        #expect(transcript.contains("Could not read its apps (The phone is locked)."))
    }

    @Test("with no device on USB it waits; R looks again and the device found then is allowed")
    func rescanFindsDevice() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let scans = CallCounter()
        let (_, transcript) = try await Self.allow(["--app", "com.mpalmes.offsider.playground", "--expires", "2h", "--team", "ABCDE12345"], answers: ["r", "1"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { scans.tick() == 0 ? [] : [Self.row] })
        })
        #expect(transcript.contains(AllowScreen.noDevice))
        #expect(transcript.contains("\(AllowScreen.deviceQuestion) (R rescan, Q quit)"))
        #expect(transcript.contains("1/1 \(AllowScreen.deviceQuestion)"))
        #expect(try Self.entries(home).map(\.key) == [PolicyFixtures.phone])
        #expect(scans.count == 2)
    }

    @Test("choosing 7 days from the expiry menu writes a 7-day allowance")
    func expiryMenuSevenDays() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try await Self.allow(["--app", "com.mpalmes.offsider.playground", "--team", "ABCDE12345"], answers: ["1", "4"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal)
        })
        #expect(try Self.entries(home).first?.expires == PolicyFixtures.now.addingTimeInterval(7 * 86_400))
    }

    @Test("a typed duration is checked, and asked again until it is one")
    func expiryTyped() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (_, transcript) = try await Self.allow(["--app", "com.mpalmes.offsider.playground", "--team", "ABCDE12345"], answers: ["1", "6", "soon\r", "45m\r"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal)
        })
        #expect(transcript.contains("A duration takes <n>m, <n>h, <n>d or never"))
        #expect(try Self.entries(home).first?.expires == PolicyFixtures.now.addingTimeInterval(45 * 60))
    }

    static func seed(_ home: String, seal: MemorySeal, _ entries: [DeviceAllowance]) throws {
        try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).update({ current in
            entries.reduce(current.list) { $0.adding($1) }
        }, commit: { try seal.seal($0) })
    }

    /// What `status` writes for a person at an 80-column terminal, or for an agent.
    static func status(_ arguments: [String], context: DeviceAccessContext, person: Bool) async throws -> ConsoleCapture {
        let capture = ConsoleCapture()
        let console = person ? capture.console(out: .person(), err: .person()) : capture.console(out: .agent, err: .agent)
        try await DeviceAccessContext.$current.withValue(context) {
            try await Console.$current.withValue(console) { try await DeviceAccessStatus.parse(arguments).run() }
        }
        return capture
    }

    @Test("status shows a person the list under a header, an agent the text it always read; --json and --device read the same for both")
    func statusScreenOnlyForAPerson() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry(apps: ["com.example.app"])])
        let context = Self.context(home: home, seal: seal)
        let person = try await Self.status([], context: context, person: true)
        #expect(person.out.hasPrefix("🔐  \(AccessStatusScreen.title)"))
        #expect(person.out.contains("\n  ● Test iPhone  com.example.app  until 15:13\n"))
        #expect(person.out.hasSuffix("offsider devices remove --device \(PolicyFixtures.phone)  withdraw it\n"))
        let agent = try await Self.status([], context: context, person: false)
        #expect(agent.out == "Managed policy: none.\nios  \(PolicyFixtures.phone)  Test iPhone: allowed until 2026-09-21T15:13:20Z, apps com.example.app\n")
        #expect(agent.err.isEmpty)
        for arguments in [["--json"], ["--device", PolicyFixtures.phone], ["--device", PolicyFixtures.phone, "--json"]] {
            let expected = try DeviceAccessStatus.parse(arguments).perform(context: context).0
            #expect(try await Self.status(arguments, context: context, person: true).out == expected)
            #expect(try await Self.status(arguments, context: context, person: false).out == expected)
        }
        #expect(try DeviceAccessStatus.parse(["--json"]).perform(context: context).0.hasPrefix("{"))
    }

    @Test("a list changed outside Offsider warns a person on stderr with the command that allows again; an agent reads it in the text")
    func statusWarnsAPerson() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.seed(home, seal: MemorySeal(), [PolicyFixtures.entry()])
        let context = Self.context(home: home, seal: MemorySeal())
        let person = try await Self.status([], context: context, person: true)
        #expect(person.err.contains("⚠️  \(AccessStatusScreen.listChanged)\n    Try  \(AccessStatusScreen.allowCommand)\n"))
        #expect(person.out.contains(AccessStatusScreen.nothingAllowed))
        #expect(!person.err.contains("Next"))
        let agent = try await Self.status([], context: context, person: false)
        #expect(agent.err.isEmpty)
        #expect(agent.out.contains("was changed outside Offsider"))
    }

    @Test("the device step shows an allowed device dim with its allowance, never offers it, and offers the rest")
    func allowedDeviceShownNotOffered() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry()])
        let (output, transcript) = try await Self.allow(["--expires", "2h"], answers: ["1", "\r", "\r"], context: { terminal in
            Self.context(home: home, seal: seal, terminal: terminal, devices: { [Self.row, Self.androidRow] })
        })
        #expect(transcript.contains("Test iPhone  allowed · any app · until 15:13") || transcript.contains("Test iPhone  allowed - any app - until 15:13"))
        #expect(output.contains("Allowed Test Pixel"))
        #expect(try Self.entries(home).map(\.key).sorted() == [PolicyFixtures.phone, PolicyFixtures.serial].sorted())
        #expect(!transcript.contains(AllowScreen.anotherQuestion))
    }

    @Test("with every connected device allowed, the device step offers only rescan and quit and names the withdraw command")
    func everyDeviceAllowed() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry()])
        let terminal = try AccessTerminal()
        terminal.type(["\r", "q"])
        await #expect(throws: ExitCode(130)) {
            try await PersonPresence.$terminal.withValue({ true }) {
                _ = try await DeviceAccessAllow.parse([]).perform(context: Self.context(home: home, seal: seal, terminal: terminal, devices: { [Self.row] }))
            }
        }
        let transcript = terminal.finish()
        #expect(transcript.contains("\(AllowScreen.deviceQuestion) (R rescan, Q quit)"))
        #expect(transcript.contains(AllowScreen.allAllowed))
        #expect(transcript.contains("Withdraw  offsider devices remove --device \(PolicyFixtures.phone)"))
        #expect(try Self.entries(home).count == 1)
    }

    @Test("devices lists, and add, remove and status are its subcommands")
    func devicesSubcommands() throws {
        #expect(try OffsiderCommand.parseAsRoot(["devices"]) is ListDevices)
        #expect(try OffsiderCommand.parseAsRoot(["devices", "--json"]) is ListDevices)
        #expect(try OffsiderCommand.parseAsRoot(["devices", "add", "--device", PolicyFixtures.phone]) is DeviceAccessAllow)
        #expect(try OffsiderCommand.parseAsRoot(["devices", "remove"]) is DeviceAccessRemove)
        #expect(try OffsiderCommand.parseAsRoot(["devices", "status", "--json"]) is DeviceAccessStatus)
        #expect(CommandPath.of(DeviceAccessAllow.self) == "devices add")
    }

    @Test("a list filter beside add, remove or status exits 64 naming the listing command, rather than being dropped", arguments: [
        (["devices", "status", "--platform", "ios"], "--platform filters the device list; devices status takes --device <id>. To list: offsider devices --platform ios"),
        (["devices", "remove", "--booted"], "--booted filters the device list; devices remove takes --device <id>. To list: offsider devices --booted"),
        (["devices", "--physical", "status", "--json"], "--physical filters the device list; devices status takes --device <id>. To list: offsider devices --physical"),
        (
            ["devices", "add", "--device", "R58M123ABC", "--booted", "--platform=android"],
            "--platform and --booted filter the device list; devices add takes --device <id>. To list: offsider devices --platform android --booted"
        ),
    ])
    func listFiltersRefused(arguments: [String], message: String) {
        do {
            let command = try OffsiderCommand.parseAsRoot(arguments)
            Issue.record("\(arguments) parsed to \(type(of: command)) instead of failing")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error) == message)
        }
    }

    @Test("the list still takes its filters, and every devices subcommand refuses them and never shows them in help")
    func everySubcommandRefusesListFilters() throws {
        let list = try #require(try OffsiderCommand.parseAsRoot(["devices", "--platform", "android", "--physical", "--booted"]) as? ListDevices)
        #expect(list.options.platform == .android && list.options.physical && list.options.booted)
        #expect(try #require(try OffsiderCommand.parseAsRoot(["list-devices", "--booted"]) as? ListDevicesAlias).options.booted)
        for subcommand in ListDevices.configuration.subcommands {
            let name = subcommand._commandName
            do {
                let command = try OffsiderCommand.parseAsRoot(["devices", name, "--booted"])
                Issue.record("devices \(name) --booted parsed to \(type(of: command)) instead of failing")
            } catch {
                #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
                #expect(OffsiderCommand.message(for: error).hasPrefix("--booted filters the device list; devices \(name) "), "\(OffsiderCommand.message(for: error))")
            }
            let help = OffsiderCommand.helpMessage(for: subcommand, columns: 200)
            #expect(!help.contains("--platform") && !help.contains("--physical") && !help.contains("--booted"), "\(help)")
        }
    }

    @Test("device-access names its new command in one line and exits 64")
    func deviceAccessRenamed() {
        #expect(ArgumentHints.hint(for: ["device-access", "allow", "--device", PolicyFixtures.phone]) == ArgumentHints.Hint(
            message: "device-access allow was renamed to devices add in 0.13.0: run offsider devices add.", isLegacy: true
        ))
        #expect(ArgumentHints.hint(for: ["device-access", "remove"])?.message.contains("run offsider devices remove") == true)
        #expect(ArgumentHints.hint(for: ["device-access"])?.message.contains("run offsider devices status") == true)
        #expect(FailureReason.legacyArgument.exitCode.rawValue == 64)
    }

    @Test("a simulator or emulator ID is refused: they need no allowance")
    func virtualRefused() {
        #expect(throws: CLIError.self) { try DeviceAccess.physicalKey("ABCDEF00-0000-4000-8000-00000000ABCD") }
        #expect(throws: CLIError.self) { try DeviceAccess.physicalKey("emulator-5554") }
    }

    // MARK: Pinned app by default

    static let apps = [
        InstalledApp(id: "com.example.bank", name: "Bank"),
        InstalledApp(id: "com.mpalmes.offsider.playground.rn", name: "Playground"),
        InstalledApp(id: "com.android.chrome", name: "Chrome"),
    ]

    @Test("the app step recommends offsider.login.json's app, else the one in front, first; Any app comes after the apps, dim with its warning")
    func appMenuOrder() {
        let policy = PhysicalDevicePolicy(managed: .none, list: .empty)
        let front = DeviceAccessAllow.appMenu(Self.apps, platform: .android, policy: policy, profile: nil, front: "com.mpalmes.offsider.playground.rn")
        #expect(front.choices == [.app(Self.apps[1]), .app(Self.apps[0]), .any, .wholeDevice, .type])
        #expect(front.recommended == 0)
        #expect(front.selected == 0)
        let rows = front.rows()
        #expect(rows[0].recommended && !rows[2].recommended && !rows[3].recommended)
        #expect(rows[2].columns == [AllowScreen.anyApp, "every app on the phone, banking and messages included"])
        #expect(rows[3].columns == ["Any app and all logs", "the phone's whole log too"])

        let profile = LoginProfile(package: "com.example.bank")
        #expect(DeviceAccessAllow.appMenu(Self.apps, platform: .android, policy: policy, profile: profile, front: "com.mpalmes.offsider.playground.rn").choices.first == .app(Self.apps[0]))

        let none = DeviceAccessAllow.appMenu(Array(Self.apps.prefix(2)), platform: .ios, policy: policy, profile: nil, front: "com.example.missing")
        #expect(none.recommended == nil)
        #expect(none.choices == [.app(Self.apps[0]), .app(Self.apps[1]), .any, .type])
        #expect(none.selected == 0)

        let empty = DeviceAccessAllow.appMenu([], platform: .ios, policy: policy, profile: nil, front: nil)
        #expect(empty.choices == [.any, .type])
        #expect(empty.selected == 1)
    }

    @Test("Return on a phone's app step pins the app in front; choosing the whole-device row saves the * pin")
    func pinnedByDefault() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try await Self.allow(["--expires", "2h"], answers: ["1", "\r"], context: { terminal in
            var context = Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.androidRow] }, apps: { _ in Self.apps })
            context.frontApp = { _ in "com.mpalmes.offsider.playground.rn" }
            return context
        })
        #expect(try Self.entries(home).map(\.apps) == [["com.mpalmes.offsider.playground.rn"]])

        let other = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: other) }
        _ = try await Self.allow(["--expires", "2h"], answers: ["1", "4"], context: { terminal in
            Self.context(home: other, seal: MemorySeal(), terminal: terminal, devices: { [Self.androidRow] }, apps: { _ in Self.apps })
        })
        #expect(try Self.entries(other).map(\.apps) == [[DeviceAllowance.wholeDevicePin]])
    }

    @Test("remove off a terminal names the exact clean command for an iPhone whose runner this Mac built")
    func removeNamesClean() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
        var context = Self.context(home: home, seal: seal)
        context.hasRunner = { _ in true }
        context.cleanRunner = { Issue.record("cleaned without asking"); return RunnerCleanupReport(udid: $0) }
        let output = try await DeviceAccessRemove.parse(["--device", PolicyFixtures.phone]).perform(context: context)
        #expect(output.hasSuffix("Uninstall Offsider's runner from it with `offsider session stop --device \(PolicyFixtures.phone) --clean`."))

        context.hasRunner = { _ in false }
        #expect(!(try await DeviceAccessRemove.parse(["--device", PolicyFixtures.phone]).perform(context: context)).contains("--clean"))
    }

    @Test("remove on a terminal asks once and cleans on Return; n keeps the runner and names the command")
    func removeAsksToClean() async throws {
        for (answer, cleans) in [("\r", true), ("n\r", false)] {
            let home = try makePolicyHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let seal = MemorySeal()
            try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).update({ $0.list.adding(PolicyFixtures.entry()) }, commit: { try seal.seal($0) })
            let terminal = try AccessTerminal()
            terminal.type([answer])
            let cleaned = CallCounter()
            var context = Self.context(home: home, seal: seal, terminal: terminal)
            context.hasRunner = { _ in true }
            context.interactive = { true }
            context.cleanRunner = { _ = cleaned.tick(); return Self.cleanReport($0) }
            let output = try await DeviceAccessRemove.parse(["--device", PolicyFixtures.phone]).perform(context: context)
            #expect(cleaned.count == (cleans ? 1 : 0))
            if cleans {
                #expect(output.hasPrefix("Uninstalled com.mpalmes.offsider.runner from \(PolicyFixtures.phone).\nDeleted 1 cached runner build for \(PolicyFixtures.phone)."))
            } else {
                #expect(output == "Kept the runner; `offsider session stop --device \(PolicyFixtures.phone) --clean` removes it later.")
            }
            #expect(terminal.transcript.contains("Also uninstall its runner? (Y/n)"))
        }
    }

    static func cleanReport(_ udid: String) -> RunnerCleanupReport {
        var report = RunnerCleanupReport(udid: udid)
        report.uninstalled = ["com.mpalmes.offsider.runner"]
        report.removedBuilds = 1
        return report
    }

    @Test("a person sees the withdrawal as a receipt above the runner question, then the clean-up as a receipt; nothing of the agent's sentence")
    func removeForAPerson() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry()])
        let terminal = try AccessTerminal()
        terminal.type(["\r"])
        var context = Self.context(home: home, seal: seal, terminal: terminal, stopped: { _ in ["runner"] })
        context.hasRunner = { _ in true }
        context.interactive = { true }
        context.cleanRunner = { Self.cleanReport($0) }
        let removal = try await DeviceAccessRemove.parse(["--device", PolicyFixtures.phone]).remove(context: context, person: true)
        let transcript = terminal.finish()
        #expect(transcript.contains("Withdrew Test iPhone"))
        #expect(transcript.contains("stopped its runner"))
        #expect(!transcript.contains("from the allow-list"))
        let capture = ConsoleCapture()
        capture.console(out: .person(), err: .person()).show(Page(removal.person, notices: removal.notices))
        #expect(capture.out.hasPrefix("✅  Cleaned up the runner on \(PolicyFixtures.phone)\n    uninstalled com.mpalmes.offsider.runner\n    deleted 1 cached build\n"))
        #expect(capture.err.contains("developer team keeps the runner's profile"))

        let none = try await DeviceAccessRemove.parse(["--device", PolicyFixtures.serial]).remove(context: Self.context(home: home, seal: seal), person: true)
        #expect(none.person.isEmpty == false)
        let nothing = ConsoleCapture()
        nothing.console(out: .person(), err: .person()).show(Page(none.person))
        #expect(nothing.out == "✅  Nothing to withdraw\n    \(PolicyFixtures.serial) was not on the list\n")
    }
}
