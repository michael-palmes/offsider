import Foundation
@testable import Offsider
@testable import OffsiderCore
import Security
import Testing

/// A seal the login Keychain will not read, as when it is locked or there is no screen to ask on.
private struct UnreadableSeal: DeviceAllowListSealing {
    let failure: any Error
    func storedDigest() throws -> Data? { throw failure }
    func store(digest: Data) throws { throw failure }
}

private struct UnreadableGuardSeal: GuardSealing {
    let failure: any Error
    func stored() throws -> GuardSealRecord? { throw failure }
    func store(_ record: GuardSealRecord) throws { throw failure }
}

@Suite("Unattended mode and an unreadable Keychain")
@MainActor
struct UnattendedTests {
    static var locked: SealKeychainFailure {
        KeychainAccess.$isLocked.withValue({ true }) { SealKeychainFailure(what: "the device allow-list seal", operation: "read", status: errSecInteractionNotAllowed) }
    }

    static func snapshot(_ entries: [DeviceAllowance]) -> DeviceAllowListSnapshot {
        let list = DeviceAllowList(entries: entries)
        return DeviceAllowListSnapshot(list: list, data: list.encoded())
    }

    @Test("OFFSIDER_UNATTENDED is on for any value but 0, false, no and off, and unset never turns it on", arguments: [
        (nil, false), ("", false), ("0", false), ("false", false), ("NO", false), (" off ", false),
        ("1", true), ("true", true), ("yes", true), ("on", true), ("ture", true),
    ] as [(String?, Bool)])
    func variable(value: String?, on: Bool) {
        #expect(UnattendedMode.isOn(environment: value.map { [UnattendedMode.variable: $0] } ?? [:]) == on)
    }

    @Test("unattended, a Touch ID confirm refuses at once with the rerun for a person, and nobody is asked")
    func confirmRefuses() async {
        let presence = RecordingPresence()
        let error = await Unattended.$isOn.withValue(true) {
            await Unattended.$arguments.withValue({ ["login", "tester", "--device", "emulator-5554"] }) {
                await PersonPresence.$current.withValue(presence) {
                    await #expect(throws: CLIError.self) { try await PersonPresence.confirm(reason: "type a saved login") }
                    return try? await PersonPresence.confirm(reason: "type a saved login")
                }
            }
        }
        #expect(error == nil)
        #expect(presence.reasons.isEmpty)
        let refusal = Unattended.$isOn.withValue(true) {
            Unattended.$arguments.withValue({ ["login", "tester", "--device", "emulator-5554"] }) { PersonPresence.unattendedRefusal(reason: "type a saved login") }
        }
        #expect(refusal.reason == .personRequired)
        #expect(refusal.userFacingDescription.hasPrefix("OFFSIDER_UNATTENDED is on, so Offsider did not ask a person to type a saved login."))
        #expect(refusal.ask == "Can you run `offsider login tester --device emulator-5554` at the Mac and confirm with Touch ID?")
    }

    @Test("attended, the confirm still reaches the person")
    func confirmAttended() async throws {
        let presence = RecordingPresence()
        try await Unattended.$isOn.withValue(false) {
            try await PersonPresence.$current.withValue(presence) { try await PersonPresence.confirm(reason: "type a saved login") }
        }
        #expect(presence.reasons == ["type a saved login"])
    }

    @Test("unattended, a terminal step refuses even at a terminal")
    func terminalRefuses() {
        Unattended.$isOn.withValue(true) {
            PersonPresence.$terminal.withValue({ true }) {
                #expect(throws: CLIError.self) { try PersonPresence.requireTerminal(instead: "Ask the user.") }
            }
        }
    }

    @Test("a rerun ask never spells out a mask selector or a token, and names the step in plain words instead")
    func rerunAskRedacts() {
        let ask = Unattended.$arguments.withValue({ ["screenshot", "--mask-text", "jane@example.com"] }) { Unattended.runAsk(then: "confirm with Touch ID") }
        #expect(ask == "Can you run this Offsider step again at the Mac and confirm with Touch ID?")
        #expect(Unattended.$arguments.withValue({ ["tap", "--label", "Sign in"] }) { Unattended.currentCommand() } == "offsider tap --label 'Sign in'")
    }

    @Test("wake --unlock on a phone in personal use asks the person to unlock it, not to rerun", arguments: [true])
    func wakeAsk(_: Bool) async {
        let consent = Wake.unlockConsent(whole: false)
        do {
            try await Unattended.$isOn.withValue(true) { try await consent("Pixel 9") }
            Issue.record("expected a refusal")
        } catch let error as CLIError {
            #expect(error.reason == .personRequired)
            #expect(error.ask == "Can you unlock Pixel 9?")
        } catch {
            Issue.record("\(error)")
        }
    }

    // MARK: - Keychain

    @Test("a locked Keychain and a prompt nobody may answer are named, and an attended decline keeps its words")
    func keychainBlocks() {
        KeychainAccess.$isLocked.withValue({ true }) {
            #expect(KeychainAccess.block(for: errSecAuthFailed, unattended: false) == .locked)
            #expect(KeychainAccess.block(for: errSecInteractionNotAllowed, unattended: false) == .locked)
            #expect(KeychainAccess.block(for: errSecItemNotFound, unattended: true) == nil)
        }
        KeychainAccess.$isLocked.withValue({ false }) {
            #expect(KeychainAccess.block(for: errSecAuthFailed, unattended: false) == nil)
            #expect(KeychainAccess.block(for: errSecAuthFailed, unattended: true) == .needsPerson)
            #expect(KeychainAccess.block(for: errSecInteractionNotAllowed, unattended: false) == .needsPerson)
            #expect(KeychainAccess.block(for: errSecDuplicateItem, unattended: true) == nil)
        }
    }

    @Test("a saved login the locked Keychain will not give up is keychain_locked with the unlock step, never macOS's text or a prompt to allow")
    func loginLocked() {
        let failure = KeychainAccess.$isLocked.withValue({ true }) {
            Unattended.$arguments.withValue({ ["login", "--device", "emulator-5554"] }) {
                LoginKeychainFailure(operation: "read", app: "com.mpalmes.offsider.playground.rn", key: "tester", status: errSecAuthFailed)
            }
        }
        #expect(failure.reason == .keychainLocked)
        #expect(failure.failureMessage.contains("the login Keychain is locked"))
        #expect(!failure.failureMessage.contains("allow it when macOS asks"))
        #expect(failure.ask == "Can you unlock the login Keychain on this Mac, then run `offsider login --device emulator-5554`?")
        let unlock = KeychainAccess.$isLocked.withValue({ true }) { KeychainFailure(operation: "read", device: "emulator-5554", status: errSecAuthFailed) }
        #expect(unlock.reason == .keychainLocked)
        let declined = KeychainAccess.$isLocked.withValue({ false }) {
            Unattended.$isOn.withValue(false) { LoginKeychainFailure(operation: "read", app: "com.example.app", key: "tester", status: errSecAuthFailed) }
        }
        #expect(declined.reason == .commandFailed)
        #expect(declined.failureMessage.contains("allow it when macOS asks"))
    }

    @Test("unattended, a login macOS would have to ask about refuses as person_required with Always Allow as the step")
    func loginNeedsPerson() {
        let failure = KeychainAccess.$isLocked.withValue({ false }) {
            Unattended.$isOn.withValue(true) {
                Unattended.$arguments.withValue({ ["login", "--device", "emulator-5554"] }) {
                    LoginKeychainFailure(operation: "read", app: "com.example.app", key: "tester", status: errSecAuthFailed)
                }
            }
        }
        #expect(failure.reason == .personRequired)
        #expect(failure.failureMessage.contains("OFFSIDER_UNATTENDED is on"))
        #expect(failure.ask == "Can you run `offsider login --device emulator-5554` at the Mac and choose Always Allow when macOS asks?")
    }

    // MARK: - Seals

    @Test("an allow-list seal the Keychain will not read refuses as seal_unreadable, told apart from a list changed outside Offsider")
    func allowListSealUnreadable() throws {
        let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial)
        let snapshot = Self.snapshot([entry])
        let seal = UnreadableSeal(failure: Self.locked)
        #expect(seal.reading(snapshot) == .unreadable("the login Keychain is locked"))
        #expect(!seal.isIntact(snapshot))
        #expect(UnreadableSeal(failure: Self.locked).reading(.missing) == .intact)

        let policy = PhysicalDevicePolicy(managed: .none, list: snapshot.list, sealUnreadable: "the login Keychain is locked")
        #expect(!policy.sealIntact)
        #expect(policy.decision(platform: .android, key: entry.key, now: PolicyFixtures.now) == .refused(.sealUnreadable("the login Keychain is locked")))
        #expect(DeviceRefusal.sealUnreadable("x").code == "seal_unreadable")
        #expect(AccessStatusScreen.warning(policy, now: PolicyFixtures.now) == AccessStatusScreen.sealUnreadable)

        let error = CLIError.deviceNotAllowed(name: "Test Pixel", key: entry.key, refusal: .sealUnreadable("the login Keychain is locked"), audience: .agent)
        #expect(error.reason == .keychainLocked)
        #expect(error.userFacingDescription.contains("could not be read from the login Keychain (the login Keychain is locked)"))
        #expect(!error.userFacingDescription.contains("changed outside Offsider"))
        #expect(error.hint == nil)
        #expect(error.ask?.hasPrefix("Can you unlock the login Keychain on this Mac") == true)

        let changed = PhysicalDevicePolicy(managed: .none, list: snapshot.list, sealIntact: false)
        #expect(changed.decision(platform: .android, key: entry.key, now: PolicyFixtures.now) == .refused(.listChanged))
    }

    @Test("an unreadable seal reads as unreadable, and devices add or remove refuses before dropping the other devices")
    func gateAndAdd() throws {
        let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial)
        let snapshot = Self.snapshot([entry])
        let detail = "the login Keychain is locked"
        let seal = KeychainAccess.$isLocked.withValue({ true }) {
            UnreadableSeal(failure: SealKeychainFailure(what: "the device allow-list seal", operation: "read", status: errSecInteractionNotAllowed))
        }
        let reading = seal.reading(snapshot)
        #expect(reading == .unreadable(detail))
        let unreadable = UnreadableSeal(failure: CLIError(errorDescription: detail))
        #expect(throws: CLIError.self) { try DeviceAccess.requireReadableSeal(snapshot, seal: unreadable) }
        #expect(throws: Never.self) { try DeviceAccess.requireReadableSeal(.missing, seal: unreadable) }
    }

    @Test("a phone's warm helper stops at the first recheck that cannot read the seal, naming it")
    func brokerStopsOnUnreadableSeal() async {
        let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial)
        let flip = Flag()
        let fresh = DevicePolicyGate(policy: {
            flip.isSet
                ? PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]), sealUnreadable: "the login Keychain is locked")
                : PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))
        }, now: { PolicyFixtures.now })
        var stops: [String] = []
        var waits = 0
        await AndroidSessionServe.watchAllowance(serial: entry.key, gate: fresh, audit: CommandAudit(), sleep: { _ in
            waits += 1
            if waits == 2 { flip.set() }
        }, stop: { stops.append($0) })
        #expect(waits == 2)
        #expect(stops == ["seal_unreadable"])
    }

    @Test("an app guard seal the Keychain will not read is named, never mistaken for approvals changed outside Offsider")
    func guardSealUnreadable() {
        let approvals = GuardApprovals().approving(GuardConfig(apps: ["com.example.app"], rules: [AppGuardTests.order]), source: nil, now: Date(timeIntervalSince1970: 0))
        let snapshot = GuardApprovalsSnapshot(approvals: approvals, data: approvals.encoded())
        let seal = UnreadableGuardSeal(failure: CLIError(errorDescription: "the login Keychain is locked"))
        let check = seal.check(snapshot)
        #expect(!check.intact)
        #expect(check.unreadable == "the login Keychain is locked")
        #expect(seal.check(.missing).unreadable == nil)
    }

    // MARK: - Evidence runs

    @Test("a refusal only a person can clear goes into the run as one line with its step, and run status counts it")
    func queuedInRun() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let queue = PersonStepQueue(environment: fixture.environment(), command: "tap", arguments: ["--label", "Buy now", "--mask-text", "secret"])
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        await PersonStepQueue.$current.withValue(queue) {
            await #expect(throws: CLIError.self) {
                try await CommandScope().run {
                    throw CLIError(errorDescription: "nobody was asked", reason: .personRequired, ask: "Can you tap “Buy now” on <DEVICE_NAME> yourself?")
                }
            }
            await #expect(throws: CLIError.self) {
                try await CommandScope().run { throw CLIError(errorDescription: "an ordinary failure", reason: .commandFailed) }
            }
        }
        queue.record(ask: "Can you unlock Test Pixel?", exit: 1, reason: "person_required", device: device)
        let lines = fixture.manifest()
        #expect(lines.count == 2)
        #expect(lines.map(\.reason) == ["person_required", "person_required"])
        #expect(lines[0].ask == "Can you tap “Buy now” on the device yourself?")
        #expect(lines[0].args == ["--label", "Buy now", "--mask-text", "<6 characters>"])
        #expect(lines[1].device == "emulator-5554" && lines[1].platform == "android")
        #expect(lines[0].file == nil && lines[0].n == nil)
        let status = try RunRegistry.status(all: false, in: fixture.environment())
        #expect(status.runs.first?.personSteps == 2)
        #expect(status.runs.first?.text(timeZone: RunFixture.timeZone).contains("0 files, 2 steps waiting for a person") == true)
        #expect(RunStatusEntry.jsonLine(runs: status.runs, ended: [], timeZone: RunFixture.timeZone).contains("\"personSteps\":2"))
    }

    @Test("with no run, a refusal writes nothing")
    func noRunNoLine() throws {
        let fixture = try RunFixture()
        PersonStepQueue(environment: fixture.environment(), command: "tap", arguments: []).record(ask: "Can you unlock it?", exit: 1, reason: "person_required", device: nil)
        #expect(fixture.manifest().isEmpty)
    }

    // MARK: - Doctor

    @Test("doctor reads an unreadable Keychain as unknown, never as no unlock code saved")
    func doctorUnlockCodeUnreadable() {
        let reading = AwakeReading(screen: .on, lockScreen: .hidden, credential: "pin", userUnlocked: true)
        let verdict = AndroidDoctorRules.lock(
            reading, unlockCode: UnlockCodeFact(saved: false, lastAttempt: nil, unreadable: "the login Keychain is locked"), deviceID: "emulator-5554", codeKey: "Offsider_E2E"
        )
        #expect(verdict.0 == .warn)
        #expect(verdict.1.contains("code saved: unknown, as the login Keychain is locked"))
        #expect(!verdict.1.contains("code saved: no"))
        #expect(verdict.2 == "Unlock the login Keychain on this Mac, then run doctor again.")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
