import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Saved login confirm always")
@MainActor
struct ConfirmAlwaysTests {
    static let app = "com.example.app"
    static let testDevice = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)

    static func credential() throws -> LoginCredential {
        try #require(LoginCredential(username: "ada@example.com", password: "s3cret-token"))
    }

    /// A login saved as `stored`, its unencrypted mirror holding `mirror` (nil writes no context).
    static func store(_ stored: StoredLogin, mirror: LoginContext?) throws -> MemoryLoginCredentialStore {
        let store = MemoryLoginCredentialStore()
        try store.saveStored(stored, app: app, key: "dev", isDefault: true, context: mirror)
        return store
    }

    static func describe(_ settings: LoginSettingsEdit, store: MemoryLoginCredentialStore, person: Bool = false) throws -> String {
        try CredentialCommand.perform(.describe, app: app, key: "dev", settings: settings, personConfirmed: person, json: true, store: store) { try credential() }
    }

    /// One `login dev` on the test device; `wholeDevice` is what a test device's allowance gives `perform`.
    static func signIn(
        _ store: MemoryLoginCredentialStore, wholeDevice: Bool = true, presence: FakePresence
    ) async -> (error: (any Error)?, backend: FakeDeviceBackend) {
        let node = UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes(package: app)))
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: testDevice.rawValue, roots: [node])])
        do {
            try await PersonPresence.$current.withValue(presence) {
                _ = try await LoginCommand.perform(
                    on: DeviceRouter.Route(backend: backend, device: testDevice), profile: nil, key: "dev", timeout: 5, logger: OffsiderLogger(), store: store,
                    wholeDevice: wholeDevice
                )
            }
            return (nil, backend)
        } catch {
            return (error, backend)
        }
    }

    /// The form check is the first step after the Keychain gates, so `selector_not_found` means every gate passed.
    static func passedTheGates(_ error: (any Error)?) -> Bool {
        (error as? CLIError)?.reason == .selectorNotFound
    }

    @Test("an agent marks a login always with no person, and always turns confirm on")
    func agentSetsAlways() throws {
        let store = try Self.store(StoredLogin(credential: try Self.credential()), mirror: nil)
        let parsed = try CredentialCommand.parse(["describe", "dev", "--confirm-always", "--app", Self.app])
        #expect(parsed.settingsEdit.loosening.isEmpty)

        let text = try Self.describe(parsed.settingsEdit, store: store)
        #expect(text.contains(#""confirm":true,"confirmAlways":true"#))
        let saved = try #require(try store.loadStored(app: Self.app, key: "dev"))
        #expect(saved.confirm && saved.confirmAlways)
        guard case .saved(let mirror)? = store.context(app: Self.app, key: "dev") else {
            Issue.record("no mirror")
            return
        }
        #expect(mirror.confirm && mirror.confirmAlways)

        let added = MemoryLoginCredentialStore()
        _ = try CredentialCommand.perform(.set, app: Self.app, key: "qa", settings: LoginSettingsEdit(confirmAlways: true), json: true, store: added) { try Self.credential() }
        #expect(try added.loadStored(app: Self.app, key: "qa")?.confirmAlways == true)
    }

    @Test("clearing always without a person is person_required and saves nothing; with one, each flag clears what it says")
    func clearingNeedsAPerson() throws {
        let always = StoredLogin(credential: try Self.credential(), confirmAlways: true)
        for flag in ["--no-confirm-always", "--no-confirm"] {
            let store = try Self.store(always, mirror: LoginContext().mirroring(always))
            let settings = try CredentialCommand.parse(["describe", "dev", flag, "--app", Self.app]).settingsEdit
            #expect(!settings.loosening.isEmpty, "\(flag) must need a person")
            let refused = #expect(throws: CLIError.self) { try Self.describe(settings, store: store) }
            #expect(refused?.reason == .personRequired)
            #expect(refused?.failureMessage.hasSuffix("Nothing was saved.") == true)
            #expect(try store.loadStored(app: Self.app, key: "dev") == always)
            #expect(store.context(app: Self.app, key: "dev") == .saved(LoginContext(confirmAlways: true)))
        }

        let plain = try Self.store(always, mirror: nil)
        _ = try Self.describe(LoginSettingsEdit(confirmAlways: false), store: plain, person: true)
        let kept = try #require(try plain.loadStored(app: Self.app, key: "dev"))
        #expect(kept.confirm && !kept.confirmAlways)

        let off = try Self.store(always, mirror: nil)
        _ = try Self.describe(LoginSettingsEdit(confirm: false), store: off, person: true)
        let cleared = try #require(try off.loadStored(app: Self.app, key: "dev"))
        #expect(!cleared.confirm && !cleared.confirmAlways)
    }

    @Test("contradictory confirm flags are a one-line usage error; confirm with no-confirm-always is fine", arguments: [
        ["--confirm-always", "--no-confirm"], ["--no-confirm", "--confirm-always"], ["--confirm-always", "--no-confirm-always"],
    ])
    func contradictions(_ flags: [String]) throws {
        do {
            _ = try CredentialCommand.parse(["describe", "dev"] + flags + ["--app", Self.app])
            Issue.record("parsed \(flags)")
        } catch {
            let message = CredentialCommand.message(for: error)
            #expect(message.contains("contradict each other: pass one."), "\(message)")
            #expect(!message.contains("\n"))
            #expect(CredentialCommand.exitCode(for: error) == .validationFailure)
        }
        let plain = try CredentialCommand.parse(["describe", "dev", "--confirm", "--no-confirm-always", "--app", Self.app])
        #expect(plain.settingsEdit == LoginSettingsEdit(confirm: true, confirmAlways: false))
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["status", "--confirm-always", "--app", Self.app]) }
    }

    @Test("on a test device a login marked always asks exactly once, and a refused ask reads and types nothing")
    func alwaysAsksOnTestDevice() async throws {
        let always = StoredLogin(credential: try Self.credential(), confirmAlways: true)
        let store = try Self.store(always, mirror: LoginContext().mirroring(always))

        let person = FakePresence()
        let signedIn = await Self.signIn(store, presence: person)
        #expect(Self.passedTheGates(signedIn.error), "stopped by \(String(describing: signedIn.error))")
        #expect(person.reasons == ["type the saved login dev into \(Self.app) on \(PolicyFixtures.serial)"])

        let before = store.decrypts
        let declined = FakePresence(failure: PersonPresence.error(for: .userCancel))
        let refused = await Self.signIn(store, presence: declined)
        #expect((refused.error as? CLIError)?.reason == .personRequired)
        #expect(declined.reasons.count == 1)
        #expect(store.decrypts == before)
        #expect(refused.backend.session.calls.isEmpty)
    }

    @Test("a plain confirm login still signs in on a test device with no ask, and asks on another phone")
    func plainConfirmSkipsTestDevice() async throws {
        let plain = StoredLogin(credential: try Self.credential(), confirm: true, devices: .any)
        let store = try Self.store(plain, mirror: LoginContext().mirroring(plain))
        let test = FakePresence()
        let onTest = await Self.signIn(store, presence: test)
        #expect(Self.passedTheGates(onTest.error))
        #expect(test.reasons.isEmpty)

        let other = FakePresence()
        _ = await Self.signIn(store, wholeDevice: false, presence: other)
        #expect(other.reasons.count == 1)
    }

    @Test("a mirror that says not always, or a newer or damaged one, still asks once from the encrypted item", arguments: [
        Data(#"{"v":2,"confirm":true}"#.utf8), Data(#"{"v":2}"#.utf8), Data(#"{"v":9}"#.utf8), Data("not json".utf8),
    ])
    func encryptedItemDecides(_ mirror: Data) async throws {
        let store = try Self.store(StoredLogin(credential: try Self.credential(), confirmAlways: true), mirror: nil)
        store.slots[LoginCredential.account(app: Self.app, key: "dev")]?.context = mirror

        let person = FakePresence()
        let signedIn = await Self.signIn(store, presence: person)
        #expect(Self.passedTheGates(signedIn.error), "stopped by \(String(describing: signedIn.error))")
        #expect(person.reasons.count == 1)

        let declined = FakePresence(failure: PersonPresence.error(for: .userCancel))
        let refused = await Self.signIn(store, presence: declined)
        #expect((refused.error as? CLIError)?.reason == .personRequired)
        #expect(refused.backend.session.calls.isEmpty)
    }

    @Test("status shows always in a few words to a person and an agent, and as confirmAlways in --json")
    func statusShowsAlways() throws {
        let always = StoredLogin(credential: try Self.credential(), confirmAlways: true)
        let store = try Self.store(always, mirror: LoginContext(about: "Admin on staging").mirroring(always))
        func status(_ key: String?, json: Bool, styled: TerminalOutput? = nil) throws -> String {
            try CredentialCommand.perform(.status, app: Self.app, key: key, json: json, styled: styled, store: store) { try Self.credential() }
        }

        let one = try #require(try JSONSerialization.jsonObject(with: Data(try status("dev", json: true).utf8)) as? [String: Any])
        #expect(one["confirm"] as? Bool == true)
        #expect(one["confirmAlways"] as? Bool == true)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(try status(nil, json: true).utf8)) as? [String: Any])
        let users = try #require(list["users"] as? [[String: Any]])
        #expect(users.first?["confirmAlways"] as? Bool == true)

        #expect(try status(nil, json: false).contains("  asks you first, even on test devices"))
        let person = try status(nil, json: false, styled: TerminalOutput(style: .plain, device: ""))
        #expect(person.contains("🔏 asks you first, even on test devices"))
        #expect(!person.unicodeScalars.contains("\u{FE0F}"))

        let plain = try Self.store(StoredLogin(credential: try Self.credential(), confirm: true), mirror: LoginContext(confirm: true))
        let plainJSON = try CredentialCommand.perform(.status, app: Self.app, key: "dev", json: true, store: plain) { try Self.credential() }
        #expect(plainJSON.contains(#""confirm":true"#))
        #expect(!plainJSON.contains("confirmAlways"))
    }

    @Test("an item or mirror saved before always existed reads as not always, and a bad value is refused")
    func storedFormat() throws {
        let old = try #require(StoredLogin(storageData: Data(#"{"v":2,"username":"a","password":"x1","links":[],"confirm":true,"devices":"virtual","webLogin":false}"#.utf8)))
        #expect(old.confirm && !old.confirmAlways)
        #expect(!old.asksFirst(wholeDevice: true) && old.asksFirst(wholeDevice: false))

        let always = StoredLogin(credential: try Self.credential(), confirmAlways: true)
        let object = try #require(try JSONSerialization.jsonObject(with: always.storageData()) as? [String: Any])
        #expect(object["v"] as? Int == 2)
        #expect(object["confirmAlways"] as? Bool == true)
        #expect(StoredLogin(storageData: always.storageData()) == always)
        #expect(always.asksFirst(wholeDevice: true))
        #expect(StoredLogin(storageData: Data(#"{"v":2,"username":"a","password":"x1","confirmAlways":"yes"}"#.utf8)) == nil)

        #expect(LoginContext.read(Data(#"{"v":2,"confirm":true}"#.utf8)) == .saved(LoginContext(confirm: true)))
        let mirror = LoginContext(confirmAlways: true)
        #expect(String(decoding: mirror.storageData(), as: UTF8.self) == #"{"v":2,"confirm":true,"confirmAlways":true}"#)
        #expect(LoginContext.read(mirror.storageData()) == .saved(mirror))
        #expect(LoginContext.read(Data(#"{"v":2,"confirmAlways":1}"#.utf8)) == .damaged)
    }
}
