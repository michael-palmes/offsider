import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Login credential")
struct LoginCredentialTests {
    private let password = "s3cret-token"
    private let username = "ada@example.com"

    @Test("login builds type and turnstile through the parser, then replaces the placeholder text")
    func parsedCommandsKeepTheirOptionGroups() throws {
        let email = FakeUI.node(.textField, id: "email-field", label: "Email")
        let typing = try LoginCommand.typingCommand(text: password, field: email, deviceID: "DEVICE")
        #expect(try typing.resolvedText() == password)
        #expect(typing.intoID == "email-field")
        #expect(typing.replace)
        #expect(typing.appOption.bundleID == nil)

        let secure = FakeUI.node(.secureTextField, label: "Password")
        let byLabel = try LoginCommand.typingCommand(text: password, field: secure, deviceID: "DEVICE")
        #expect(byLabel.intoLabel == "Password")

        let turnstile = try LoginCommand.turnstileCommand(timeout: 15, deviceID: "DEVICE")
        #expect(turnstile.timeout == 15)
        #expect(turnstile.elementID == nil)
        #expect(turnstile.deviceOption.explicitID == "DEVICE")
    }

    @Test("a credential withholds its values, and a value the keyboard cannot type is refused")
    func model() throws {
        let credential = try #require(LoginCredential(username: "  \(username)  ", password: password))
        #expect(credential.username == username)
        #expect(credential.description == "<credential withheld>")
        #expect(String(reflecting: credential) == "<credential withheld>")
        #expect(!"\(credential)".contains(password))
        #expect(LoginCredential(username: username, password: "s3cret token") != nil)
        #expect(LoginCredential(username: "café", password: password) == nil)
        #expect(LoginKey(rawValue: "dev")?.rawValue == "dev")
        #expect(LoginKey(rawValue: "-dev") == nil)
        #expect(LoginKey(rawValue: "default") == nil)
        let account = LoginCredential.account(app: "com.example.app", key: "dev")
        #expect(LoginCredential.parseAccount(account)?.app == "com.example.app")
        #expect(LoginCredential.parseAccount(account)?.key == "dev")
        #expect(LoginCredential.parseAccount(LoginCredential.linkAccount(member: "com.example.android")) == nil)
        #expect(LoginCredential.parseAccount(LoginCredential.account(app: "com.example.app", key: LoginCredential.defaultAccountKey))?.key == "*")
        let round = LoginCredential(storageData: credential.storageData())
        #expect(round == credential)

        let refused = refusal(username: "café", password: password)
        #expect(refused.contains("Nothing was saved."))
        #expect(!refused.contains("caf"))
        #expect(!refused.contains(password))
    }

    @Test("status names the username for that app only, and never the password")
    func statusHidesThePassword() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        try store.save(credential, app: "com.example.app", key: "dev", isDefault: true)
        try store.save(try #require(LoginCredential(username: "other@example.com", password: password)), app: "com.other.app", key: "dev", isDefault: true)

        let text = try CredentialCommand.perform(.status, app: "com.example.app", key: "dev", json: false, store: store) { credential }
        #expect(text.contains(username))
        #expect(!text.contains("other@example.com"))
        #expect(!text.contains(password))

        let json = try CredentialCommand.perform(.status, app: "com.example.app", key: "dev", json: true, store: store) { credential }
        #expect(json.contains("\"username\":\"\(username)\""))
        #expect(json.contains("\"saved\":true"))
        #expect(!json.contains("\"password\""))
        #expect(!json.contains(password))

        let set = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa", json: false, store: store) { credential }
        #expect(set.contains(username))
        #expect(!set.contains(password))
    }

    @Test("login with several keys lists the keys and not the usernames")
    func severalKeys() throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try #require(LoginCredential(username: username, password: password)), app: "com.example.app", key: "dev", isDefault: false)
        try store.save(try #require(LoginCredential(username: "bea@example.com", password: password)), app: "com.example.app", key: "qa", isDefault: false)
        do {
            _ = try LoginCommand.resolveKey(nil, app: "com.example.app", canonical: "com.example.app", device: "DEVICE", store: store)
            Issue.record("expected the keys to be listed")
        } catch let error as CLIError {
            #expect(error.reason == .selectorAmbiguous)
            #expect(error.failureMessage.contains("dev"))
            #expect(error.failureMessage.contains("qa"))
            #expect(!error.failureMessage.contains(username))
            #expect(!error.failureMessage.contains(password))
            #expect(!error.failureMessage.contains("login default"))
        }
        #expect(try LoginCommand.resolveKey(nil, app: "com.example.app", canonical: "com.example.app", device: "DEVICE", store: one(store)) == "dev")
    }

    @Test("the first saved login is the default, and a joined bundle id uses it")
    func defaultAndJoin() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        let saved = try CredentialCommand.perform(.set, app: "com.example.app", key: "dev", json: false, store: store) { credential }
        #expect(saved.contains("default"))
        #expect(!saved.contains(password))
        #expect(try LoginCommand.resolveKey(nil, app: "com.example.app", canonical: "com.example.app", device: "DEVICE", store: store) == "dev")

        let added = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa", json: false, store: store) {
            try #require(LoginCredential(username: "bea@example.com", password: password))
        }
        #expect(added.contains("qa"))
        #expect(!added.contains("default login"))
        #expect(try store.defaultKey(app: "com.example.app") == "dev")
        #expect(try LoginCommand.resolveKey(nil, app: "com.example.app", canonical: "com.example.app", device: "DEVICE", store: store) == "dev")

        let linked = try CredentialCommand.join(foreground: "com.example.android", requested: nil, interactive: false, json: false, store: store) { _ in "" }
        #expect(linked.contains("com.example.android"))
        #expect(linked.contains("com.example.app"))
        #expect(!linked.contains(password))
        #expect(!linked.contains(username))
        let canonical = try store.canonical(of: "com.example.android")
        #expect(canonical == "com.example.app")
        #expect(try LoginCommand.resolveKey(nil, app: "com.example.android", canonical: canonical, device: "DEVICE", store: store) == "dev")
        #expect(try store.load(app: canonical, key: "dev")?.username == username)
        #expect(try store.load(app: "com.example.android", key: "dev") == nil)

        try store.save(credential, app: "com.other.app", key: "dev", isDefault: true)
        let owns = refusalOfJoin(store: store, foreground: "com.other.app")
        #expect(owns.contains("own saved logins"))
        #expect(owns.contains("Nothing was linked."))
        #expect(!owns.contains(password))
        let needsApp = refusalOfJoin(store: store, foreground: "com.third.app")
        #expect(needsApp.contains("Pass --app"))
        #expect(needsApp.contains("Nothing was linked."))
    }

    @Test("a second save without a terminal does not overwrite, and does not read a password")
    func secondSaveRefusesWithoutAChoice() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        try store.save(credential, app: "com.example.app", key: "dev", isDefault: true)
        var read = false
        do {
            _ = try CredentialCommand.perform(.set, app: "com.example.app", key: nil, update: false, interactive: false, json: false, store: store) {
                read = true
                return credential
            }
            Issue.record("expected the second save to refuse")
        } catch let error as CLIError {
            #expect(error.reason == .usage)
            #expect(error.failureMessage.contains("--update"))
            #expect(error.failureMessage.contains("Nothing was saved."))
            #expect(!error.failureMessage.contains(password))
            #expect(!error.failureMessage.contains(username))
        }
        #expect(!read)
        let menu = LoginDirectory.setMenu(app: "com.example.app", entries: try store.list(app: "com.example.app"))
        #expect(menu.contains(username))
        #expect(!menu.contains(password))
        #expect(LoginDirectory.interpretSetChoice("u", entries: try store.list(app: "com.example.app")) == .update(key: "dev"))
        #expect(LoginDirectory.interpretSetChoice("n", entries: try store.list(app: "com.example.app")) == .create)
        #expect(LoginDirectory.setIntent(entries: [], tag: nil, update: false, interactive: false) == .write(key: LoginCredential.defaultAccountKey, makeDefault: true))
    }

    @Test("credential takes --device, and --app does not require one")
    func parsing() throws {
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["set", "dev"]) }
        let bound = try CredentialCommand.parse(["set", "dev", "--app", "com.example.app"])
        #expect(bound.app == "com.example.app")
        let bare = try CredentialCommand.parse(["set", "--app", "com.example.app"])
        #expect(bare.key == nil)
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["set", "default", "--app", "com.example.app"]) }
        let joining = try CredentialCommand.parse(["join", "--device", "DEVICE"])
        #expect(joining.action == "join")
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["join", "--app", "com.example.app"]) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["status", "--stdin", "--app", "com.example.app"]) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["set", "Bad Key", "--app", "com.example.app"]) }
        let login = try LoginCommand.parse(["dev", "--device", "DEVICE", "--turnstile", "off", "--timeout", "5"])
        #expect(login.turnstile == .off)
        #expect(login.timeout == 5)
        try DeviceDefault.$environment.withValue({ "DEVICE" }) {
            let parsed = try CredentialCommand.parse(["status"])
            #expect(parsed.device.resolved?.id == "DEVICE")
        }
    }

    @Test("login reads the Keychain between the keychain callbacks, so a macOS prompt never runs under the watchdog")
    @MainActor
    func keychainReadsSitOutsideTheWatchdog() async throws {
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let app = UINode(
            role: .application,
            frame: UIFrame(x: 0, y: 0, width: 400, height: 800),
            native: .android(AndroidNativeAttributes(package: "com.example.app"))
        )
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: device.rawValue, roots: [app])])
        let store = MemoryLoginCredentialStore()
        var paused = false
        var reads = 0
        var readsWhileArmed = 0
        store.onRead = {
            reads += 1
            if !paused { readsWhileArmed += 1 }
        }
        await #expect(throws: CLIError.self) {
            _ = try await LoginCommand.perform(
                on: DeviceRouter.Route(backend: backend, device: device), profile: nil, mode: .off, key: "dev",
                timeout: 5, logger: OffsiderLogger(), store: store,
                keychainWillRead: { paused = $0 == "com.example.app" }, keychainDidRead: { paused = false }
            )
        }
        #expect(reads > 0)
        #expect(readsWhileArmed == 0)
        #expect(!paused)
    }

    private func refusal(username: String, password: String) -> String {
        do {
            _ = try CredentialCommand.credential(username: username, password: password)
            return ""
        } catch {
            return "\(error)"
        }
    }

    private func refusalOfJoin(store: MemoryLoginCredentialStore, foreground: String) -> String {
        do {
            return try CredentialCommand.join(foreground: foreground, requested: nil, interactive: false, json: false, store: store) { _ in "" }
        } catch {
            return "\(error)"
        }
    }

    private func one(_ store: MemoryLoginCredentialStore) -> MemoryLoginCredentialStore {
        store.slots = store.slots.filter { LoginCredential.parseAccount($0.key)?.key == "dev" }
        return store
    }
}

final class MemoryLoginCredentialStore: LoginCredentialStoring {
    struct Slot {
        var credential: LoginCredential
        var isDefault: Bool
    }

    var slots: [String: Slot] = [:]
    var links: [String: String] = [:]
    /// Called on each read that `login` makes before it types.
    var onRead: () -> Void = {}

    func load(app: String, key: String) throws -> LoginCredential? {
        onRead()
        return slots[LoginCredential.account(app: app, key: key)]?.credential
    }

    func list(app: String) throws -> [LoginCredentialSummary] {
        slots.compactMap { account, slot in
            guard let parsed = LoginCredential.parseAccount(account), parsed.app == app else { return nil }
            return LoginCredentialSummary(key: parsed.key, username: slot.credential.username, isDefault: slot.isDefault)
        }.sorted { $0.key < $1.key }
    }

    func keys(app: String) throws -> [String] {
        try list(app: app).map(\.key)
    }

    func defaultKey(app: String) throws -> String? {
        onRead()
        return try list(app: app).first { $0.isDefault }?.key
    }

    func save(_ credential: LoginCredential, app: String, key: String, isDefault: Bool) throws {
        if isDefault {
            for (account, var slot) in slots {
                guard LoginCredential.parseAccount(account)?.app == app else { continue }
                slot.isDefault = false
                slots[account] = slot
            }
        }
        slots[LoginCredential.account(app: app, key: key)] = Slot(credential: credential, isDefault: isDefault)
    }

    func markDefault(app: String, key: String) throws {
        let account = LoginCredential.account(app: app, key: key)
        guard slots[account] != nil else { return }
        for (existing, var slot) in slots {
            guard LoginCredential.parseAccount(existing)?.app == app else { continue }
            slot.isDefault = existing == account
            slots[existing] = slot
        }
    }

    func remove(app: String, key: String) throws -> Bool {
        let removed = slots.removeValue(forKey: LoginCredential.account(app: app, key: key)) != nil
        if try keys(app: app).isEmpty { links = links.filter { $0.value != app } }
        return removed
    }

    func canonical(of app: String) throws -> String {
        onRead()
        return links[app] ?? app
    }

    func groups() throws -> [LoginAppGroup] {
        let apps = Set(slots.keys.compactMap { LoginCredential.parseAccount($0)?.app })
        return apps.sorted().map { app in
            LoginAppGroup(canonical: app, members: links.filter { $0.value == app }.map(\.key).sorted())
        }
    }

    func join(member: String, canonical: String) throws {
        links[member] = canonical
    }
}
