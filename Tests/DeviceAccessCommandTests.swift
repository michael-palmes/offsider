import ArgumentParser
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

/// A pseudo-terminal whose far end types once the prompt switches echo off, and keeps what the prompt drew.
final class AccessTerminal: @unchecked Sendable {
    let primary: Int32
    let secondary: Int32
    private let lock = NSLock()
    private var drawn = Data()

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
        }
    }

    /// Everything drawn so far, without escape sequences.
    var transcript: String {
        let text = lock.withLock { String(decoding: drawn, as: UTF8.self) }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func echoing(_ on: Bool, tries: Int) {
        var settings = termios()
        for _ in 0..<tries {
            if tcgetattr(secondary, &settings) == 0, (settings.c_lflag & tcflag_t(ECHO) != 0) == on { return }
            usleep(1000)
        }
    }

    /// Sends each answer after the prompt has gone raw again, then waits for it to leave raw mode.
    func type(_ answers: [String]) {
        Thread.detachNewThread { [self] in
            for answer in answers {
                echoing(false, tries: 5000)
                usleep(20_000)
                _ = answer.withCString { write(primary, $0, strlen($0)) }
                echoing(true, tries: 300)
            }
        }
    }

    deinit {
        close(secondary)
        close(primary)
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

@Suite("device-access", .serialized)
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
        return (output, terminal.transcript)
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
        #expect(error?.userFacingDescription.contains("Ask the user to run `offsider device-access allow` in their own terminal.") == true)
        #expect(presence.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.file(home)))
    }

    @Test("allow writes the entry only after the right suffix and the presence check, then seals it")
    func allowWritesAfterSuffixAndPresence() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let terminal = try AccessTerminal()
        terminal.type(["\r", "0000\r", "0ABC\r"])
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
            "Withdraw  offsider device-access remove --device \(PolicyFixtures.phone)", "Next      offsider doctor --device \(PolicyFixtures.phone)",
        ])
        #expect(Set(closing.map { $0.prefix { $0 == " " }.count }).count == 1)
        #expect(terminal.transcript.contains(DeviceAccessAllow.suffixMismatch))
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
        terminal.type(["\r", "\r", "0ABC\r"])
        let seal = MemorySeal()
        let command = try DeviceAccessAllow.parse(["--device", PolicyFixtures.phone, "--team", "ABCDE12345"])
        let output = try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(RecordingPresence()) {
                try await command.perform(context: Self.context(home: home, seal: seal, terminal: terminal))
            }
        }
        #expect(output.contains("Allowed Test iPhone until 22 Sep 02:14, any app."))
        #expect(terminal.transcript.contains("Test iPhone · any app · 12 hours · team ABCDE12345") || terminal.transcript.contains("Test iPhone - any app - 12 hours - team ABCDE12345"))
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
        terminal.type(["\r", "\r", "\r", "0abc\r"])
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
        #expect(error?.hint == "offsider device-access allow")

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
        #expect(refused.1?.userFacingDescription.contains("run `offsider device-access allow` in their own terminal and choose \(PolicyFixtures.phone)") == true)
        #expect(refused.1?.hint == "offsider device-access allow")
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

    static let wifiRow = DeviceSummary(
        id: "00008140-0000000000000DEF", platform: .ios, state: "Booted", name: "Wireless iPad", osVersion: "iOS 27.2", deviceType: "iPad Air", kind: .physical, connection: "network"
    )
    static let androidRow = DeviceSummary(
        id: PolicyFixtures.serial, platform: .android, state: "device", name: "Test Pixel", osVersion: "Android 16", deviceType: "Pixel 9", kind: .physical, connection: "usb"
    )

    @Test("picking the device, team and app from menus writes them with no suffix prompt, after the preamble and the steps in order")
    func menuPickWritesChoices() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let presence = RecordingPresence()
        let apps = [
            InstalledApp(id: "com.apple.mobilesafari", name: "Safari"),
            InstalledApp(id: "com.mpalmes.offsider.playground", name: "Offsider Playground"),
        ]
        let (output, transcript) = try await Self.allow([], answers: ["1", "\r", "2", "\r"], context: { terminal in
            Self.context(home: home, seal: seal, terminal: terminal, devices: { [Self.row, Self.wifiRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] }, apps: { _ in apps })
        }, presence: presence)
        let entry = try #require(try Self.entries(home).first)
        #expect(entry.team == "ABCDE12345")
        #expect(entry.apps == ["com.mpalmes.offsider.playground"])
        #expect(entry.expires == PolicyFixtures.now.addingTimeInterval(12 * 3_600))
        #expect(seal.isIntact(try DeviceAllowListStore(directory: UserConfigDirectory(home: home)).load()))
        #expect(presence.reasons == ["allow Offsider to drive Test iPhone (\(PolicyFixtures.phone))"])
        #expect(output.contains("Next      offsider doctor --device \(PolicyFixtures.phone)"))
        #expect(!transcript.contains(DeviceAccessAllow.suffixLabel))
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
        let (_, transcript) = try await Self.allow([], answers: ["1", "\r", "\r", "\r", "2"], context: { terminal in
            Self.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [Self.row, Self.androidRow] }, teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] })
        })
        let shown = transcript.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { $0.contains(PolicyFixtures.phone) || $0.contains(PolicyFixtures.serial) }
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { $0.hasSuffix("Withdraw  offsider device-access remove --device \(PolicyFixtures.phone)") || $0.hasSuffix("Next      offsider doctor --device \(PolicyFixtures.phone)") })
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

    @Test("status on a terminal draws the screen; --json, --device and piped output stay the text agents parse")
    func statusScreenOnlyOnATerminal() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry(apps: ["com.example.app"])])
        let context = Self.context(home: home, seal: seal)
        let screen = (style: TerminalStyle(colours: false), width: 72)
        let drawn = try DeviceAccessStatus.parse([]).perform(context: context, screen: screen).0
        #expect(drawn.contains(AccessStatusScreen.title))
        #expect(drawn.contains("    📱  Test iPhone  com.example.app · until 15:13\n"))
        #expect(drawn.hasSuffix("  Withdraw  offsider device-access remove --device \(PolicyFixtures.phone)\n"))
        let piped = try DeviceAccessStatus.parse([]).perform(context: context).0
        #expect(piped == "Managed policy: none.\nios  \(PolicyFixtures.phone)  Test iPhone: allowed until 2026-09-21T15:13:20Z, apps com.example.app\n")
        for arguments in [["--json"], ["--device", PolicyFixtures.phone], ["--device", PolicyFixtures.phone, "--json"]] {
            let command = try DeviceAccessStatus.parse(arguments)
            #expect(try command.perform(context: context, screen: screen).0 == command.perform(context: context).0)
        }
        #expect(try DeviceAccessStatus.parse(["--json"]).perform(context: context).0.hasPrefix("{"))
    }

    @Test("the device step shows an allowed device dim with its allowance, never offers it, and offers the rest")
    func allowedDeviceShownNotOffered() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        try Self.seed(home, seal: seal, [PolicyFixtures.entry()])
        let (output, transcript) = try await Self.allow(["--expires", "2h"], answers: ["1", "\r"], context: { terminal in
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
        let transcript = terminal.transcript
        #expect(transcript.contains("\(AllowScreen.deviceQuestion) (R rescan, Q quit)"))
        #expect(transcript.contains(AllowScreen.allAllowed))
        #expect(transcript.contains("Withdraw  offsider device-access remove --device \(PolicyFixtures.phone)"))
        #expect(try Self.entries(home).count == 1)
    }

    @Test("device-access alone prints the status")
    func defaultsToStatus() throws {
        #expect(try DeviceAccessCommand.parseAsRoot([]) is DeviceAccessStatus)
    }

    @Test("a simulator or emulator ID is refused: they need no allowance")
    func virtualRefused() {
        #expect(throws: CLIError.self) { try DeviceAccessCommand.physicalKey("ABCDEF00-0000-4000-8000-00000000ABCD") }
        #expect(throws: CLIError.self) { try DeviceAccessCommand.physicalKey("emulator-5554") }
    }
}
