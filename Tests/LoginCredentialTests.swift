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

    /// The key `login` would pick, from attributes only, as on a device of `platform`.
    private func chosen(_ store: MemoryLoginCredentialStore, app: String = "com.example.app", name: String? = nil, where filter: [String] = [], platform: DevicePlatform = .ios) throws -> String {
        let tags = try filter.map { try #require(LoginTag(rawValue: $0)) }
        let entries = try store.entries(app: try store.canonical(of: app))
        return try LoginCommand.resolveLogin(name, where: tags, app: app, entries: entries, device: DeviceID(rawValue: "DEVICE", platform: platform)).key
    }

    @Test("login with several keys and no default lists the names and not the usernames")
    func severalKeys() throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try #require(LoginCredential(username: username, password: password)), app: "com.example.app", key: "dev", isDefault: false)
        try store.save(try #require(LoginCredential(username: "bea@example.com", password: password)), app: "com.example.app", key: "qa", isDefault: false)
        do {
            _ = try chosen(store)
            Issue.record("expected the keys to be listed")
        } catch let error as CLIError {
            #expect(error.reason == .userAmbiguous)
            #expect(error.exitCode == .ambiguousSelector)
            #expect(error.failureMessage.contains("dev"))
            #expect(error.failureMessage.contains("qa"))
            #expect(error.users.map(\.name) == ["dev", "qa"])
            #expect(!error.failureMessage.contains(username))
            #expect(!error.failureMessage.contains(password))
            #expect(!error.failureMessage.contains("login default"))
        }
        #expect(store.decrypts == 0)
        #expect(try chosen(one(store)) == "dev")
    }

    @Test("login --where picks the one login with every tag, and none or several name the logins but never a username")
    func whereSelection() throws {
        let store = try savedPair()
        let tag = { (raw: String) in try #require(LoginTag(rawValue: raw)) }
        #expect(try store.setContext(LoginContext(about: "Admin on staging", tags: [try tag("role=admin"), try tag("env=staging"), try tag("platform=ios")]), app: "com.example.app", key: "qa-admin"))
        #expect(try store.setContext(LoginContext(tags: [try tag("role=member"), try tag("env=staging"), try tag("platform=android")]), app: "com.example.app", key: "qa-member"))
        #expect(try chosen(store, where: ["role=member"]) == "qa-member")
        #expect(try chosen(store, where: ["Role=Admin", "env=staging"]) == "qa-admin")

        let none = #expect(throws: CLIError.self) { try chosen(store, where: ["role=owner"]) }
        #expect(none?.reason == .userNotFound)
        #expect(none?.exitCode == .selectorNotFound)
        #expect(none?.users.count == 2)
        #expect(none?.hint == "offsider credential status --app com.example.app --json")

        let several = #expect(throws: CLIError.self) { try chosen(store, where: ["env=staging"], platform: .android) }
        #expect(several?.reason == .userAmbiguous)
        #expect(several?.hint == "offsider login --where env=staging --where platform=android --device DEVICE")
        #expect(several?.users == [FailureUser(name: "qa-admin", tags: ["env=staging", "platform=ios", "role=admin"], about: "Admin on staging"), FailureUser(name: "qa-member", tags: ["env=staging", "platform=android", "role=member"], about: nil)])
        for failure in [none, several].compactMap({ $0 }) {
            let envelope = ErrorEnvelope(command: "login", error: ErrorPayload(failure)).jsonLine()
            #expect(!envelope.contains("@example.com"))
            #expect(!envelope.contains(password))
        }

        #expect(try store.setContext(LoginContext(tags: [try tag("env=staging")]), app: "com.example.app", key: "qa-member"))
        let noRefinement = #expect(throws: CLIError.self) { try chosen(store, where: ["env=staging"], platform: .android) }
        #expect(noRefinement?.hint == "offsider credential status --app com.example.app --json")
        #expect(store.decrypts == 0)
    }

    @Test("--where goes with login or credential status and never beside a name, and login's version 1 JSON gains name, tags and where")
    func whereUsageAndReport() throws {
        let app = ["--app", "com.example.app"]
        #expect(throws: (any Error).self) { try LoginCommand.parse(["qa", "--where", "role=admin", "--device", "DEVICE"]) }
        #expect(throws: (any Error).self) { try LoginCommand.parse(["--where", "Role Admin", "--device", "DEVICE"]) }
        #expect(try LoginCommand.parse(["--where", "role=admin", "--where", "credit", "--device", "DEVICE"]).filters == ["role=admin", "credit"])
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["status", "qa", "--where", "role=admin"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["set", "qa", "--where", "role=admin"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["describe", "qa", "--state", "x", "--where", "role=admin"] + app) }
        _ = try CredentialCommand.parse(["status", "--where", "role=admin"] + app)

        let admin = try #require(LoginTag(rawValue: "role=admin"))
        let report = LoginReport(app: "com.example.app", key: "qa-admin", turnstile: .absent, submitLabel: "Sign in", tags: [admin], filter: [admin])
        #expect(report.jsonLine() == #"{"version":1,"ok":true,"app":"com.example.app","key":"qa-admin","identity":"filled","password":"filled","submitted":true,"name":"qa-admin","tags":["role=admin"],"where":["role=admin"],"exitCode":0,"error":null}"#)
        #expect(report.textLine().hasPrefix("com.example.app as qa-admin (chosen by --where role=admin): "))
        let unnamed = LoginReport(app: "com.example.app", key: LoginCredential.defaultAccountKey, turnstile: .off, submitLabel: nil).jsonLine()
        #expect(unnamed.hasSuffix(#""key":"*","identity":"filled","password":"filled","submitted":true,"name":"default","tags":[],"exitCode":0,"error":null}"#))
    }

    @Test("status --where is a dry run of login --where: one match prints it without a username")
    func statusWhere() throws {
        let store = try savedPair()
        #expect(try store.setContext(LoginContext(tags: [try #require(LoginTag(rawValue: "role=member"))]), app: "com.example.app", key: "qa-member"))
        let filter = [try #require(LoginTag(rawValue: "role=member"))]
        func status(_ filter: [LoginTag]) throws -> String {
            try CredentialCommand.perform(.status, app: "com.example.app", key: nil, where: filter, json: true, store: store) { try #require(LoginCredential(username: "x", password: "x")) }
        }
        #expect(try status(filter) == #"{"version":2,"action":"status","app":"com.example.app","where":["role=member"],"name":"qa-member","saved":true,"default":false,"tags":["role=member"],"signedIn":[]}"#)
        let none = #expect(throws: CLIError.self) { try status([try #require(LoginTag(rawValue: "role=owner"))]) }
        #expect(none?.exitCode == .selectorNotFound)
        #expect(store.decrypts == 0)
    }

    @Test("the first saved login is the default, and a joined bundle id uses it")
    func defaultAndJoin() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        let saved = try CredentialCommand.perform(.set, app: "com.example.app", key: "dev", json: false, store: store) { credential }
        #expect(saved.contains("default"))
        #expect(!saved.contains(password))
        #expect(try chosen(store) == "dev")

        let added = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa", json: false, store: store) {
            try #require(LoginCredential(username: "bea@example.com", password: password))
        }
        #expect(added.contains("qa"))
        #expect(!added.contains("default login"))
        #expect(try store.defaultKey(app: "com.example.app") == "dev")
        #expect(try chosen(store) == "dev")

        let linked = try CredentialCommand.join(foreground: "com.example.android", requested: nil, json: false, store: store)
        #expect(linked.contains("com.example.android"))
        #expect(linked.contains("com.example.app"))
        #expect(!linked.contains(password))
        #expect(!linked.contains(username))
        let canonical = try store.canonical(of: "com.example.android")
        #expect(canonical == "com.example.app")
        #expect(try chosen(store, app: "com.example.android") == "dev")
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
            _ = try CredentialCommand.perform(.set, app: "com.example.app", key: nil, update: false, json: false, store: store) {
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
        let entries = try store.list(app: "com.example.app")
        let menu = CredentialScreen.menuOptions(entries: entries)
        #expect(menu.contains { $0.contains(username) })
        #expect(!menu.contains { $0.contains(password) })
        #expect(LoginDirectory.setChoice(at: 0, entries: entries) == .update(key: "dev"))
        #expect(LoginDirectory.setChoice(at: entries.count, entries: entries) == .create)
        #expect(LoginDirectory.setIntent(entries: entries, name: "dev", update: false, interactive: true) == .confirm(key: "dev", makeDefault: true))
        guard case .refused(let refusal) = LoginDirectory.setIntent(entries: entries, name: "dev", update: false, interactive: false) else {
            Issue.record("expected a saved name to refuse without a terminal")
            return
        }
        #expect(refusal.contains("--update"))
        #expect(LoginDirectory.setIntent(entries: [], name: nil, update: false, interactive: false) == .write(key: LoginCredential.defaultAccountKey, makeDefault: true))
    }

    @Test("set and remove without a terminal read only item attributes, so no other user's password is decrypted")
    func nonInteractiveWritesDecryptNothing() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        try store.save(credential, app: "com.example.app", key: "qa-admin", isDefault: true)
        try store.save(credential, app: "com.example.app", key: "qa-member", isDefault: false)
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-owner", json: true, store: store) { credential }
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-member", update: true, json: true, store: store) { credential }
        #expect(throws: CLIError.self) {
            try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", json: true, store: store) { credential }
        }
        _ = try CredentialCommand.perform(.remove, app: "com.example.app", key: nil, json: true, store: store) { credential }
        #expect(store.decrypts == 0)
        #expect(try store.keys(app: "com.example.app") == ["qa-member", "qa-owner"])
    }

    @Test("a password update keeps the stored context, and remove drops it with the login")
    func contextFollowsTheItem() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: username, password: password))
        let context = LoginContext(about: "Admin on staging", tags: [try #require(LoginTag(rawValue: "role=admin"))])
        try store.save(credential, app: "com.example.app", key: "qa-admin", isDefault: true, context: context)
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", update: true, json: true, store: store) { credential }
        #expect(store.context(app: "com.example.app", key: "qa-admin") == .saved(context))
        _ = try CredentialCommand.perform(.remove, app: "com.example.app", key: "qa-admin", json: true, store: store) { credential }
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", json: true, store: store) { credential }
        #expect(store.context(app: "com.example.app", key: "qa-admin") == .saved(.empty))
    }

    private static let stamp = Date(timeIntervalSince1970: 1_791_711_000)

    private func savedPair() throws -> MemoryLoginCredentialStore {
        let store = MemoryLoginCredentialStore()
        try store.save(try #require(LoginCredential(username: username, password: password)), app: "com.example.app", key: "qa-admin", isDefault: true)
        try store.save(try #require(LoginCredential(username: "bea@example.com", password: password)), app: "com.example.app", key: "qa-member", isDefault: false)
        return store
    }

    private func describe(_ store: MemoryLoginCredentialStore, _ key: String?, _ edit: LoginContextEdit, app: String = "com.example.app", wrote: (() -> Void, () -> Void) = ({}, {})) throws -> String {
        try CredentialCommand.perform(.describe, app: app, key: key, edit: edit, json: true, store: store, now: Self.stamp, keychainWillWrite: wrote.0, keychainDidWrite: wrote.1) {
            Issue.record("describe must not ask for a password")
            return try #require(LoginCredential(username: "x", password: "x"))
        }
    }

    @Test("describe sets notes and tags without decrypting, reports only a change, and a password update keeps them")
    func describeWritesContext() throws {
        let store = try savedPair()
        let edit = try LoginContextEdit.parse(about: "Admin on staging", avoid: nil, state: nil, tag: ["role=admin", "env=staging"], untag: [], clearTags: false)
        var writing = false
        var writesInsideNotice = 0
        var writes = 0
        store.onWrite = {
            writes += 1
            if writing { writesInsideNotice += 1 }
        }
        let first = try describe(store, nil, edit, wrote: ({ writing = true }, { writing = false }))
        #expect(first == #"{"version":2,"action":"describe","app":"com.example.app","name":"qa-admin","saved":true,"changed":true,"default":true,"tags":["env=staging","role=admin"],"about":"Admin on staging","updated":"2026-10-11T09:30:00Z"}"#)
        let again = try describe(store, "qa-admin", edit, wrote: ({ writing = true }, { writing = false }))
        #expect(again.contains(#""changed":false"#))
        #expect(writes == 1)
        #expect(writesInsideNotice == 1)
        #expect(!writing)
        #expect(store.decrypts == 0)

        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", update: true, json: true, store: store) {
            try #require(LoginCredential(username: "ada.new@example.com", password: password))
        }
        guard case .saved(let kept) = store.context(app: "com.example.app", key: "qa-admin") else {
            Issue.record("expected the context to survive a password update")
            return
        }
        #expect(kept.about == "Admin on staging")
        #expect(kept.tags.map(\.rawValue) == ["env=staging", "role=admin"])
    }

    @Test("describe refuses a missing name with a set hint, several logins with no default, and never overwrites a newer context")
    func describeRefusals() throws {
        let store = try savedPair()
        let edit = LoginContextEdit(state: "3 items in the cart")
        let missing = #expect(throws: CLIError.self) { try describe(store, "qa-owner", edit) }
        #expect(missing?.exitCode == .failure)
        #expect(missing?.hint == "offsider credential set qa-owner --app com.example.app")

        store.markDefaultOff(app: "com.example.app")
        let several = #expect(throws: CLIError.self) { try describe(store, nil, edit) }
        #expect(several?.reason == .usage)
        #expect(several?.failureMessage.contains("qa-admin, qa-member") == true)

        let newer = Data(#"{"v":2,"about":"Kept"}"#.utf8)
        store.slots[LoginCredential.account(app: "com.example.app", key: "qa-member")]?.context = newer
        let refused = #expect(throws: CLIError.self) { try describe(store, "qa-member", edit) }
        #expect(refused?.exitCode == .failure)
        #expect(refused?.failureMessage.contains("newer Offsider") == true)
        #expect(store.slots[LoginCredential.account(app: "com.example.app", key: "qa-member")]?.context == newer)

        let tooMany = LoginContextEdit(tag: try (1...17).map { try #require(LoginTag(rawValue: "t\($0)")) })
        let capped = #expect(throws: CLIError.self) { try describe(store, "qa-admin", tooMany) }
        #expect(capped?.exitCode == .usage)
    }

    @Test("the version 2 status list reads no password and shows no username; status with a name decrypts and adds it")
    func statusVersionTwo() throws {
        let store = try savedPair()
        let context = LoginContext(
            about: "Admin on staging, can change team settings", avoid: "Checkout: no store credit", state: "3 items in the cart",
            tags: [try #require(LoginTag(rawValue: "role=admin")), try #require(LoginTag(rawValue: "env=staging"))], updated: Self.stamp
        )
        #expect(try store.setContext(context, app: "com.example.app", key: "qa-admin"))
        #expect(try store.setContext(LoginContext(tags: [try #require(LoginTag(rawValue: "role=member"))]), app: "com.example.app", key: "qa-member"))
        let fixture = try SignInTrackerFixture(now: Self.stamp.addingTimeInterval(1931.9996))
        defer { fixture.remove() }
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        func status(_ key: String?, json: Bool = true, app: String = "com.example.app") throws -> String {
            try CredentialCommand.perform(.status, app: app, key: key, json: json, store: store, tracker: fixture.tracker, deviceID: "emulator-5554") {
                try #require(LoginCredential(username: "x", password: "x"))
            }
        }

        let list = try status(nil)
        #expect(list == #"{"version":2,"action":"status","app":"com.example.app","signedInHere":"qa-admin","users":[{"name":"qa-admin","default":true,"tags":["env=staging","role=admin"],"about":"Admin on staging, can change team settings","avoid":"Checkout: no store credit","state":"3 items in the cart","updated":"2026-10-11T09:30:00Z","signedIn":[{"device":"Test_AVD","platform":"android","since":"2026-10-11T10:02:11Z","restarted":false}],"signedInHere":true},{"name":"qa-member","default":false,"tags":["role=member"],"signedIn":[],"signedInHere":false}]}"#)
        let text = try status(nil, json: false)
        #expect(text.contains("role=admin"))
        #expect(text.contains("Admin on staging"))
        #expect(!text.contains("@example.com"))
        #expect(store.decrypts == 0)

        let one = try status("qa-admin")
        #expect(one.contains(#""name":"qa-admin","saved":true,"default":true,"username":"\#(username)","tags":["env=staging","role=admin"]"#))
        #expect(one.contains(#""signedIn":[{"device":"Test_AVD""#))
        #expect(!one.contains(password))
        #expect(store.decrypts == 1)
        #expect(try status("qa-owner") == #"{"version":2,"action":"status","app":"com.example.app","signedInHere":"qa-admin","name":"qa-owner","saved":false}"#)

        _ = try CredentialCommand.join(foreground: "com.example.android", requested: nil, json: true, store: store)
        let joined = try status(nil, app: "com.example.android")
        #expect(joined.contains(#""app":"com.example.android","also":["com.example.app"]"#))
        #expect(joined.contains(#""about":"Admin on staging, can change team settings""#))
        #expect(joined.contains(#""signedInHere":"qa-admin""#))
        #expect(joined.contains(#""signedIn":[{"device":"Test_AVD""#))
    }

    @Test("context flags go only with set or describe, describe needs one, and a bad tag or note states the rule")
    func contextFlagUsage() throws {
        let app = ["--app", "com.example.app"]
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["status", "--tag", "role=admin"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["remove", "qa", "--about", "x"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["join", "--clear-tags", "--device", "DEVICE"]) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["describe", "qa"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["describe", "qa", "--stdin", "--state", "x"] + app) }
        #expect(throws: (any Error).self) { try CredentialCommand.parse(["describe", "qa", "--about", "ada@example.com"] + app) }
        do {
            _ = try CredentialCommand.parse(["describe", "qa", "--tag", "Role Admin"] + app)
            Issue.record("expected a bad tag to be refused")
        } catch {
            #expect(CredentialCommand.message(for: error).contains(LoginTag.rule))
            #expect(CredentialCommand.exitCode(for: error) == .validationFailure)
        }
        let describe = try CredentialCommand.parse(["describe", "qa", "--tag", "role=admin", "--tag", "credit", "--untag", "beta", "--state", ""] + app)
        #expect(try describe.contextEdit() == LoginContextEdit(state: "", tag: [try #require(LoginTag(rawValue: "role=admin")), try #require(LoginTag(rawValue: "credit"))], untag: [try #require(LoginTag(rawValue: "beta"))]))
        _ = try CredentialCommand.parse(["set", "qa", "--stdin", "--about", "Member on staging"] + app)
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

    @Test("status shows where each login was last signed in, and who is signed in on the device in hand")
    func statusShowsSignIns() throws {
        var fixture = try SignInTrackerFixture(now: Self.stamp)
        defer { fixture.remove() }
        let store = try savedPair()
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        fixture.tracker.now = { Self.stamp + 60 }
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "ZY22FAKE01")
        let tracker = fixture.tracker
        func status(_ deviceID: String?) throws -> String {
            try CredentialCommand.perform(.status, app: "com.example.app", key: nil, json: true, store: store, tracker: tracker, deviceID: deviceID) {
                try #require(LoginCredential(username: "x", password: "x"))
            }
        }

        #expect(try status("emulator-5554") == #"{"version":2,"action":"status","app":"com.example.app","signedInHere":"qa-admin","users":[{"name":"qa-admin","default":true,"tags":[],"signedIn":[{"device":"ZY22FAKE01","platform":"android","since":"2026-10-11T09:31:00Z"},{"device":"Test_AVD","platform":"android","since":"2026-10-11T09:30:00Z","restarted":false}],"signedInHere":true},{"name":"qa-member","default":false,"tags":[],"signedIn":[],"signedInHere":false}]}"#)
        let elsewhere = try #require(try JSONSerialization.jsonObject(with: Data(try status("ZY22FAKE02").utf8)) as? [String: Any])
        #expect(elsewhere["signedInHere"] is NSNull)
        let users = try #require(elsewhere["users"] as? [[String: Any]])
        #expect(users.count == 2)
        #expect(users.allSatisfy { $0["signedInHere"] as? Bool == false })
        #expect(!(try status(nil)).contains("signedInHere"))
        #expect(store.decrypts == 0)
    }

    @Test("with a device in hand every status form prints signedInHere and each listed user a boolean, false when nobody is recorded; with none both are left out")
    func signedInHereNeedsOnlyADevice() throws {
        let fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        let store = try savedPair()
        #expect(try store.setContext(LoginContext(tags: [try #require(LoginTag(rawValue: "role=admin"))]), app: "com.example.app", key: "qa-admin"))
        func status(_ key: String?, where filter: [LoginTag] = [], deviceID: String?) throws -> [String: Any] {
            let line = try CredentialCommand.perform(
                .status, app: "com.example.app", key: key, where: filter, json: true, store: store, tracker: fixture.tracker, deviceID: deviceID
            ) { try #require(LoginCredential(username: "x", password: "x")) }
            return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let admin = [try #require(LoginTag(rawValue: "role=admin"))]

        func here(_ report: [String: Any]) throws -> [String: Bool?] {
            let users = try #require(report["users"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: try users.map { (try #require($0["name"] as? String), $0["signedInHere"] as? Bool) })
        }

        for deviceID in ["emulator-5554", "ZY22FAKE02"] {
            for report in [try status(nil, deviceID: deviceID), try status("qa-member", deviceID: deviceID), try status("qa-owner", deviceID: deviceID), try status(nil, where: admin, deviceID: deviceID)] {
                #expect(report["signedInHere"] is NSNull, "\(report)")
            }
            #expect(try here(try status(nil, deviceID: deviceID)) == ["qa-admin": false, "qa-member": false])
        }
        for report in [try status(nil, deviceID: nil), try status("qa-member", deviceID: nil), try status(nil, where: admin, deviceID: nil)] {
            #expect(report.keys.contains("signedInHere") == false, "\(report)")
        }
        #expect(try here(try status(nil, deviceID: nil)) == ["qa-admin": nil, "qa-member": nil])
        #expect(try status("qa-member", deviceID: "emulator-5554")["users"] == nil)
        let signinsPath = (fixture.root as NSString).appendingPathComponent(OffsiderPrivateDirectory.signInsDirectoryName)
        #expect(!FileManager.default.fileExists(atPath: signinsPath))

        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        #expect(try status("qa-member", deviceID: "emulator-5554")["signedInHere"] as? String == "qa-admin")
        #expect(try status(nil, where: admin, deviceID: "Test_AVD")["signedInHere"] as? String == "qa-admin")
        #expect(try here(try status(nil, deviceID: "emulator-5554")) == ["qa-admin": true, "qa-member": false])
        #expect(try here(try status(nil, deviceID: "ZY22FAKE02")) == ["qa-admin": false, "qa-member": false])
    }

    @Test("signed-out clears only this device's record for the app, names who it was, and exits 0 when nothing was recorded")
    func signedOut() throws {
        let fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        let store = try savedPair()
        let tracker = fixture.tracker
        tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-member", deviceID: "ZY22FAKE01")
        tracker.record(app: "com.example.other", foreground: "com.example.other", key: "qa-admin", deviceID: "emulator-5554")
        func signOut(_ deviceID: String, app: String = "com.example.app", json: Bool = true) throws -> String {
            try CredentialCommand.perform(.signedOut, app: app, key: nil, json: json, store: store, tracker: tracker, deviceID: deviceID) {
                try #require(LoginCredential(username: "x", password: "x"))
            }
        }

        #expect(try signOut("emulator-5554") == #"{"version":2,"action":"signed-out","app":"com.example.app","device":"Test_AVD","platform":"android","name":"qa-admin","cleared":true}"#)
        #expect(try signOut("Test_AVD") == #"{"version":2,"action":"signed-out","app":"com.example.app","device":"Test_AVD","platform":"android","name":null,"cleared":false}"#)
        #expect(tracker.signedInHere(app: "com.example.app", deviceID: "ZY22FAKE01") == "qa-member")
        #expect(tracker.signedInHere(app: "com.example.other", deviceID: "emulator-5554") == "qa-admin")
        #expect(try signOut("ZY22FAKE01", json: false) == "Cleared the sign-in record of qa-member for com.example.app on ZY22FAKE01. Offsider no longer counts it as signed in there.")
        #expect(try signOut("ZY22FAKE01", json: false) == "No sign-in was recorded for com.example.app on ZY22FAKE01. Nothing was cleared.")
        #expect(store.decrypts == 0)

        _ = try CredentialCommand.join(foreground: "com.example.android", requested: nil, json: true, store: store)
        tracker.record(app: "com.example.app", foreground: "com.example.android", key: LoginCredential.defaultAccountKey, deviceID: "emulator-5554")
        let joined = try signOut("emulator-5554", app: "com.example.android")
        #expect(joined.contains(#""name":"default","cleared":true"#))

        let phone = #expect(throws: CLIError.self) { try signOut("00008130-0000000000000ABC") }
        #expect(phone?.reason == .notSupported)
    }

    @Test("signed-out needs a device, and takes no name, --where or context flags")
    func signedOutUsage() throws {
        let refused = [
            ["signed-out", "qa-admin", "--device", "emulator-5554"],
            ["signed-out", "--app", "com.example.app"],
            ["signed-out", "--where", "role=admin", "--device", "emulator-5554"],
            ["signed-out", "--tag", "role=admin", "--device", "emulator-5554"],
            ["signed-out", "--stdin", "--device", "emulator-5554"],
        ]
        try DeviceDefault.$environment.withValue({ nil }) {
            for arguments in refused {
                do {
                    _ = try CredentialCommand.parse(arguments)
                    Issue.record("expected \(arguments) to be refused")
                } catch {
                    #expect(CredentialCommand.exitCode(for: error) == .validationFailure)
                }
            }
            let parsed = try CredentialCommand.parse(["signed-out", "--app", "com.example.app", "--device", "emulator-5554"])
            #expect(try parsed.parsedAction() == .signedOut)
        }
    }

    @Test("remove clears the login's sign-in records on every device, and leaves other logins and apps alone")
    func removeClearsSignIns() throws {
        let fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        let store = try savedPair()
        let tracker = fixture.tracker
        tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "ZY22FAKE01")
        tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-member", deviceID: "ZY22FAKE02")
        tracker.record(app: "com.example.other", foreground: "com.example.other", key: "qa-admin", deviceID: "emulator-5554")

        _ = try CredentialCommand.perform(.remove, app: "com.example.app", key: "qa-admin", json: true, store: store, tracker: tracker) {
            try #require(LoginCredential(username: "x", password: "x"))
        }

        #expect(tracker.signIns(app: "com.example.app").keys.sorted() == ["qa-member"])
        #expect(tracker.signedInHere(app: "com.example.other", deviceID: "emulator-5554") == "qa-admin")
    }

    @Test("a login that finds no form records nothing, and names who Offsider last signed in here and how to switch")
    @MainActor
    func failedLoginRecordsNothing() async throws {
        let fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let app = UINode(
            role: .application,
            frame: UIFrame(x: 0, y: 0, width: 400, height: 800),
            native: .android(AndroidNativeAttributes(package: "com.example.app"))
        )
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: device.rawValue, roots: [app])])
        let store = try savedPair()
        let restarted = try fixture.restarted()

        let error = await #expect(throws: CLIError.self) {
            _ = try await LoginCommand.perform(
                on: DeviceRouter.Route(backend: backend, device: device), profile: nil, mode: .off, key: "qa-member",
                timeout: 5, logger: OffsiderLogger(), store: store, tracker: restarted
            )
        }

        #expect(error?.reason == .selectorNotFound)
        #expect(error?.userFacingDescription.contains("Offsider last signed in as qa-admin here (2025-10-09T08:53:20Z, before the device restarted)") == true)
        #expect(error?.hint == "offsider credential signed-out --device emulator-5554")
        #expect(fixture.tracker.signedInHere(app: "com.example.app", deviceID: "emulator-5554") == "qa-admin")
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
            return try CredentialCommand.join(foreground: foreground, requested: nil, json: false, store: store)
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
        /// The generic attribute's bytes, as the Keychain holds them.
        var context: Data? = nil
    }

    var slots: [String: Slot] = [:]
    var links: [String: String] = [:]
    /// Called on each read that `login` makes before it types.
    var onRead: () -> Void = {}
    /// Called on each context write, which macOS may hold for a prompt.
    var onWrite: () -> Void = {}
    /// Passwords decrypted so far.
    private(set) var decrypts = 0

    func load(app: String, key: String) throws -> LoginCredential? {
        onRead()
        guard let slot = slots[LoginCredential.account(app: app, key: key)] else { return nil }
        decrypts += 1
        return slot.credential
    }

    func list(app: String) throws -> [LoginCredentialSummary] {
        let found = mine(app)
        decrypts += found.count
        return found.map { key, slot in LoginCredentialSummary(key: key, username: slot.credential.username, isDefault: slot.isDefault) }
    }

    func keys(app: String) throws -> [String] {
        mine(app).map(\.key)
    }

    func defaultKey(app: String) throws -> String? {
        onRead()
        return mine(app).first { $0.slot.isDefault }?.key
    }

    func entries(app: String) throws -> [LoginEntry] {
        onRead()
        return mine(app).map { key, slot in LoginEntry(key: key, isDefault: slot.isDefault, stored: LoginContext.read(slot.context)) }
            .sorted { lhs, rhs in lhs.isDefault != rhs.isDefault ? lhs.isDefault : lhs.key < rhs.key }
    }

    func save(_ credential: LoginCredential, app: String, key: String, isDefault: Bool, context: LoginContext?) throws {
        if isDefault {
            for (account, var slot) in slots {
                guard LoginCredential.parseAccount(account)?.app == app else { continue }
                slot.isDefault = false
                slots[account] = slot
            }
        }
        let account = LoginCredential.account(app: app, key: key)
        let kept = slots[account]?.context
        slots[account] = Slot(credential: credential, isDefault: isDefault, context: context.map { $0.storageData() } ?? kept)
    }

    func setContext(_ context: LoginContext, app: String, key: String) throws -> Bool {
        onWrite()
        let account = LoginCredential.account(app: app, key: key)
        guard slots[account] != nil else { return false }
        slots[account]?.context = context.storageData()
        return true
    }

    /// Leaves every login for `app` unmarked, as a 0.9.0 Keychain could.
    func markDefaultOff(app: String) {
        for key in mine(app).map(\.key) {
            slots[LoginCredential.account(app: app, key: key)]?.isDefault = false
        }
    }

    /// The stored context, read as `entries` reads it.
    func context(app: String, key: String) -> LoginContextRead? {
        slots[LoginCredential.account(app: app, key: key)].map { LoginContext.read($0.context) }
    }

    private func mine(_ app: String) -> [(key: String, slot: Slot)] {
        slots.compactMap { account, slot in
            guard let parsed = LoginCredential.parseAccount(account), parsed.app == app else { return nil }
            return (parsed.key, slot)
        }.sorted { $0.key < $1.key }
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
