import ArgumentParser
import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

private let iosApp = "com.mpalmes.offsider.playground"
private let androidApp = "com.mpalmes.offsider.playground.rn"

/// Answers for a login saved to several apps; counts each password read.
private final class SharedAnswers: SharedCredentialQuestions {
    var change: LoginSetChoice = .create
    var name = "qa"
    var replace = true
    let answer = LoginCredential(username: "ada@example.com", password: "s3cret")!
    private(set) var reads = 0
    private(set) var asked: [String] = []

    func loginToChange(entries: [LoginCredentialSummary]) throws -> LoginSetChoice { change }
    func replaces(_ entry: LoginCredentialSummary) throws -> Bool { replace }
    func newName(taken: [String]) throws -> String {
        asked.append("name")
        return name
    }
    func credential() throws -> LoginCredential {
        reads += 1
        return answer
    }
    func context() throws -> LoginContextEdit { LoginContextEdit() }
    func sharedLoginToChange(_ names: [LoginSharedName]) throws -> LoginSetChoice {
        asked.append("change " + names.map { "\($0.key):\($0.apps.joined(separator: ","))" }.joined(separator: " "))
        return change
    }
    func replacesShared(key: String, apps: [String]) throws -> Bool {
        asked.append("replace \(key) for \(apps.joined(separator: ","))")
        return replace
    }
}

@Suite("credential add for several apps")
struct CredentialAddTests {
    static let ios = LoginTarget(id: iosApp, platform: .ios)
    static let android = LoginTarget(id: androidApp, platform: .android)

    static func saved(_ store: MemoryLoginCredentialStore, _ app: String, key: String = LoginCredential.defaultAccountKey, isDefault: Bool = true) throws {
        try store.save(LoginCredential(username: "old@example.com", password: "old")!, app: app, key: key, isDefault: isDefault)
    }

    // MARK: Rules

    @Test("with nothing saved, one login becomes each app's default, saved without a name")
    func firstLoginIsEachDefault() {
        let intent = LoginDirectory.sharedSetIntent(apps: [(iosApp, []), (androidApp, [])], name: nil, update: false, interactive: false)
        #expect(intent == .write([
            LoginSharedWrite(app: iosApp, key: LoginCredential.defaultAccountKey, makeDefault: true, replaces: false),
            LoginSharedWrite(app: androidApp, key: LoginCredential.defaultAccountKey, makeDefault: true, replaces: false),
        ]))
    }

    @Test("a name saved for one app asks before replacing it there and is added to the other; without a terminal it is refused")
    func savedNameAsksFirst() {
        let apps: [(app: String, entries: [any LoginMark])] = [(iosApp, [LoginEntry(key: "qa", isDefault: true)]), (androidApp, [])]
        #expect(LoginDirectory.sharedSetIntent(apps: apps, name: "qa", update: false, interactive: true) == .confirm(key: "qa", apps: [iosApp]))
        guard case .refused(let message) = LoginDirectory.sharedSetIntent(apps: apps, name: "qa", update: false, interactive: false) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(message.contains("already saved for \(iosApp)") && message.contains("--update"))
        #expect(LoginDirectory.sharedSetIntent(apps: apps, name: "qa", update: true, interactive: false) == .write([
            LoginSharedWrite(app: iosApp, key: "qa", makeDefault: true, replaces: true),
            LoginSharedWrite(app: androidApp, key: "qa", makeDefault: true, replaces: false),
        ]))
    }

    @Test("saved logins and no name make a person choose, naming the apps that hold each; without a terminal it is refused")
    func savedLoginsNeedAChoice() {
        let apps: [(app: String, entries: [any LoginMark])] = [(iosApp, [LoginEntry(key: "qa", isDefault: true)]), (androidApp, [LoginEntry(key: "qa", isDefault: true), LoginEntry(key: "admin")])]
        #expect(LoginDirectory.sharedSetIntent(apps: apps, name: nil, update: false, interactive: true) == .choose([
            LoginSharedName(key: "qa", apps: [iosApp, androidApp]), LoginSharedName(key: "admin", apps: [androidApp]),
        ]))
        guard case .refused = LoginDirectory.sharedSetIntent(apps: apps, name: nil, update: false, interactive: false) else {
            Issue.record("expected a refusal")
            return
        }
        guard case .write(let writes) = LoginDirectory.sharedSetIntent(apps: apps, name: nil, update: true, interactive: false) else {
            Issue.record("expected writes")
            return
        }
        #expect(writes.map(\.key) == ["qa", "qa"])
        #expect(writes.allSatisfy { $0.replaces })
    }

    @Test("default is refused for an app that already has named logins, so nothing is saved anywhere")
    func defaultBesideNamedLogins() {
        let apps: [(app: String, entries: [any LoginMark])] = [(iosApp, []), (androidApp, [LoginEntry(key: "qa", isDefault: true)])]
        guard case .refused(let message) = LoginDirectory.sharedSetIntent(apps: apps, name: LoginCredential.defaultAccountKey, update: false, interactive: false) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(message.contains(androidApp) && message.contains("Nothing was saved"))
    }

    @Test("a new name beside one unmarked login marks that login the default first")
    func stampsTheSoleLogin() {
        let apps: [(app: String, entries: [any LoginMark])] = [(iosApp, [LoginEntry(key: "dev")]), (androidApp, [])]
        guard case .write(let writes) = LoginDirectory.sharedSetIntent(apps: apps, name: "qa", update: false, interactive: false) else {
            Issue.record("expected writes")
            return
        }
        #expect(writes[0] == LoginSharedWrite(app: iosApp, key: "qa", makeDefault: false, replaces: false, stampDefault: "dev"))
        #expect(writes[1].makeDefault)
    }

    // MARK: Picker

    @Test("offsider.login.json's ids come first and ticked, the apps in front next, then saved apps; system apps are never offered")
    func pickerWithProfile() {
        let profile = LoginProfile(bundleID: iosApp, package: androidApp)
        let choices = LoginAppPicker.choices(
            profile: profile,
            front: [("com.google.android.apps.nexuslauncher", .android, "Pixel 9"), ("com.example.other", .ios, "iPhone 17"), (androidApp, .android, "Pixel 9")],
            saved: ["com.example.saved", "com.android.chrome"]
        )
        #expect(choices.map(\.id) == [iosApp, androidApp, "com.example.other", "com.example.saved"])
        #expect(choices.map(\.ticked) == [true, true, false, false])
        #expect(choices.map(\.platform) == [.ios, .android, .ios, nil])
        #expect(choices[1].source == .profile)
    }

    @Test("without offsider.login.json the apps in front are ticked and saved apps are not")
    func pickerWithoutProfile() {
        let choices = LoginAppPicker.choices(profile: nil, front: [(iosApp, .ios, "iPhone 17"), (androidApp, .android, "Pixel 9")], saved: [iosApp, "com.example.saved"])
        #expect(choices.map(\.id) == [iosApp, androidApp, "com.example.saved"])
        #expect(choices.map(\.ticked) == [true, true, false])
        #expect(CredentialScreen.appRow(choices[0]).columns == [iosApp, "in front on iPhone 17"])
        #expect(LoginAppPicker.typed(" com.a.b, com.c.d  com.e.f ") == ["com.a.b", "com.c.d", "com.e.f"])
        #expect(CredentialScreen.appsProblem("", have: []) != nil)
        #expect(CredentialScreen.appsProblem("", have: [iosApp]) == nil)
        #expect(CredentialScreen.appsProblem("com.android.chrome", have: [])?.contains("browser") == true)
        #expect(CredentialScreen.appsProblem("not an id", have: []) != nil)
    }

    @Test("an Android home screen is a system app: never linked, signed in to or driven on a phone")
    func launchersDenied() {
        for launcher in ["com.google.android.apps.nexuslauncher", "com.android.launcher3", "com.sec.android.app.launcher"] {
            #expect(SystemAppDenyList.isDenied(launcher, platform: .android), "\(launcher)")
        }
        #expect(!SystemAppDenyList.isDenied(androidApp, platform: .android))
    }

    // MARK: Saving

    @Test("add with two apps reads the password once and saves the same login for each")
    func savesForEachApp() throws {
        let store = MemoryLoginCredentialStore()
        let answers = SharedAnswers()
        let text = try CredentialCommand.performMany(
            [Self.ios, Self.android], key: nil, json: false, store: store, questions: answers, readCredential: answers.credential
        )
        #expect(answers.reads == 1)
        #expect(try store.load(app: iosApp, key: LoginCredential.defaultAccountKey) == answers.answer)
        #expect(try store.load(app: androidApp, key: LoginCredential.defaultAccountKey) == answers.answer)
        #expect(text.split(separator: "\n").count == 2)
        #expect(!text.contains("s3cret"))
    }

    @Test("adding to apps with a saved login asks once whether to update it or add another, then saves the new name for both")
    func addsAnotherAcrossApps() throws {
        let store = MemoryLoginCredentialStore()
        try Self.saved(store, iosApp, key: "dev")
        let answers = SharedAnswers()
        answers.change = .create
        answers.name = "qa"
        _ = try CredentialCommand.performMany([Self.ios, Self.android], key: nil, json: true, store: store, questions: answers, readCredential: answers.credential)
        #expect(answers.asked == ["change dev:\(iosApp)", "name"])
        #expect(try store.keys(app: iosApp) == ["dev", "qa"])
        #expect(try store.keys(app: androidApp) == ["qa"])
        #expect(try store.entries(app: iosApp).first(where: \.isDefault)?.key == "dev")
        #expect(try store.entries(app: androidApp).first?.isDefault == true)
    }

    @Test("keeping a saved name reads no password and saves nothing")
    func keepingSavesNothing() throws {
        let store = MemoryLoginCredentialStore()
        try Self.saved(store, androidApp, key: "qa")
        let answers = SharedAnswers()
        answers.replace = false
        #expect(throws: PromptCancelled.self) {
            _ = try CredentialCommand.performMany([Self.ios, Self.android], key: "qa", json: false, store: store, questions: answers, readCredential: answers.credential)
        }
        #expect(answers.reads == 0)
        #expect(try store.keys(app: iosApp).isEmpty)
        #expect(try store.load(app: androidApp, key: "qa")?.username == "old@example.com")
    }

    @Test("an app linked to the other is saved once, through the app it is linked to")
    func linkedAppSavedOnce() throws {
        let store = MemoryLoginCredentialStore()
        try Self.saved(store, iosApp)
        try store.join(member: androidApp, canonical: iosApp)
        let text = try CredentialCommand.performMany(
            [Self.ios, Self.android], key: "qa", json: true, store: store, readCredential: { SharedAnswers().answer }
        )
        #expect(text.split(separator: "\n").count == 1)
        #expect(text.contains("\"also\":[\"\(androidApp)\"]"))
        #expect(try store.keys(app: androidApp).isEmpty)
        #expect(try store.keys(app: iosApp) == [LoginCredential.defaultAccountKey, "qa"])
    }

    @Test("phones apply to the Android app and an unknown one, never to an app the picker knows is iOS")
    func phonesSkipIOS() throws {
        let store = MemoryLoginCredentialStore()
        let typed = LoginTarget(id: "com.example.typed", platform: nil)
        _ = try CredentialCommand.performMany(
            [Self.ios, Self.android, typed], key: nil, settings: LoginSettingsEdit(devices: .any), personConfirmed: true, json: false, store: store,
            readCredential: { SharedAnswers().answer }
        )
        let key = LoginCredential.defaultAccountKey
        #expect(try store.loadStored(app: iosApp, key: key)?.devices == .virtual)
        #expect(try store.loadStored(app: iosApp, key: key)?.confirm == false)
        #expect(try store.loadStored(app: androidApp, key: key)?.devices == .any)
        #expect(try store.loadStored(app: androidApp, key: key)?.confirm == true)
        #expect(try store.loadStored(app: typed.id, key: key)?.devices == .any)
    }

    @Test("phones without a person, or a browser among the apps, save nothing and read no password")
    func refusalsSaveNothing() throws {
        let store = MemoryLoginCredentialStore()
        var reads = 0
        let read = { () throws -> LoginCredential in
            reads += 1
            return SharedAnswers().answer
        }
        let person = #expect(throws: CLIError.self) {
            _ = try CredentialCommand.performMany([Self.ios, Self.android], key: nil, settings: LoginSettingsEdit(devices: .any), json: false, store: store, readCredential: read)
        }
        #expect(person?.reason == .personRequired)
        let browser = #expect(throws: CLIError.self) {
            _ = try CredentialCommand.performMany([Self.ios, LoginTarget(id: "com.android.chrome", platform: nil)], key: nil, json: false, store: store, readCredential: read)
        }
        #expect(browser?.reason == .appNotAllowed)
        #expect(browser?.userFacingDescription.hasSuffix("Nothing was saved.") == true)
        #expect(reads == 0)
        #expect(store.slots.isEmpty)
    }

    @Test("--json prints one set object per app, never the password")
    func jsonPerApp() throws {
        let text = try CredentialCommand.performMany(
            [Self.ios, Self.android], key: "qa", json: true, store: MemoryLoginCredentialStore(), readCredential: { SharedAnswers().answer }
        )
        let objects = try text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(objects.map { $0["app"] as? String } == [iosApp, androidApp])
        #expect(objects.allSatisfy { $0["action"] as? String == "set" && $0["name"] as? String == "qa" && $0["password"] == nil })
    }

    @Test("a person's receipt names both apps once, with the next step")
    func styledReceipt() throws {
        let text = try CredentialCommand.performMany(
            [Self.ios, Self.android], key: nil, json: false, styled: TerminalOutput(style: .plain, device: ""), store: MemoryLoginCredentialStore(),
            readCredential: { SharedAnswers().answer }
        )
        #expect(text.hasPrefix("✅ Saved the default login for \(iosApp) and \(androidApp)"))
        #expect(text.contains("👤 ada@example.com"))
        #expect(text.hasSuffix("offsider login"))
    }

    @Test("removing a linked app unlinks it: the other app keeps its logins, and no saved login carries the link")
    func removeUnlinks() throws {
        let store = MemoryLoginCredentialStore()
        try Self.saved(store, iosApp)
        try Self.saved(store, iosApp, key: "qa", isDefault: false)
        try store.join(member: androidApp, canonical: iosApp)
        let text = try CredentialCommand.perform(.remove, app: androidApp, key: "qa", json: false, store: store) { SharedAnswers().answer }
        #expect(text.hasPrefix("Unlinked \(androidApp) from \(iosApp)."))
        #expect(try store.keys(app: iosApp) == [LoginCredential.defaultAccountKey, "qa"])
        #expect(try store.canonical(of: androidApp) == androidApp)
        for key in try store.keys(app: iosApp) {
            #expect(try store.loadStored(app: iosApp, key: key)?.links.isEmpty == true)
        }
        let json = try CredentialCommand.perform(.remove, app: androidApp, key: nil, json: true, store: store) { SharedAnswers().answer }
        #expect(json == #"{"version":2,"action":"remove","app":"\#(androidApp)","name":"default","saved":false,"removed":false}"#)
    }

    // MARK: Command line

    @Test("add is set, --app repeats only for add, and never names one app twice")
    func parsing() throws {
        let add = try CredentialCommand.parse(["add", "--app", iosApp, "--app", androidApp])
        #expect(try add.parsedAction() == .set)
        #expect(add.apps == [iosApp, androidApp])
        #expect(throws: (any Error).self) { _ = try CredentialCommand.parse(["status", "--app", iosApp, "--app", androidApp]) }
        #expect(throws: (any Error).self) { _ = try CredentialCommand.parse(["add", "--app", iosApp, "--app", iosApp]) }
    }

    @Test("add with no app and no device asks a person which apps; an agent or a pipe still needs one")
    func pickerOnlyForAPerson() {
        func parses(_ arguments: [String], person: Bool) -> Bool {
            DevicePicker.$terminal.withValue({ person }) { (try? CredentialCommand.parse(arguments)) != nil }
        }
        #expect(!parses(["add"], person: false))
        #expect(parses(["add"], person: true))
        #expect(!parses(["add", "--json"], person: true))
        #expect(!parses(["add", "--stdin"], person: true))
        #expect(!parses(["status"], person: true))
    }

    @Test("the picker takes the ticked apps with their platforms, and leaves one receipt line")
    @MainActor
    func pickerTakesTicked() async throws {
        let terminal = try AccessTerminal()
        terminal.type(["\r"])
        let context = CredentialAddContext(
            profile: { LoginProfile(bundleID: iosApp, package: androidApp) }, frontApps: { [] }, phoneAllowed: { false }, promptDescriptor: terminal.secondary
        )
        let targets = try await TerminalPrompt.runAsync(cancelled: "cancelled", descriptor: terminal.secondary) { prompt in
            try await CredentialCommand.pickApps(on: prompt, context: context, store: MemoryLoginCredentialStore())
        }
        #expect(targets == [Self.ios, Self.android])
        let transcript = terminal.finish()
        #expect(transcript.contains(CredentialScreen.appsQuestion))
        #expect(transcript.contains("offsider.login.json"))
    }
}
