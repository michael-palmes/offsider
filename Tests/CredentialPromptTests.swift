import ArgumentParser
import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Credential prompts", .serialized)
struct CredentialPromptTests {
    @Test("a bad answer names the fix without repeating a password")
    func answerProblems() {
        #expect(CredentialScreen.usernameProblem("  ") != nil)
        #expect(CredentialScreen.usernameProblem("café") == PromptScreen.untypeable)
        #expect(CredentialScreen.usernameProblem(" ada@example.com ") == nil)
        let long = String(repeating: "x", count: 129)
        #expect(CredentialScreen.passwordProblem(long)?.contains(long) == false)
        #expect(CredentialScreen.passwordProblem("s3cret token") == nil)
        #expect(CredentialScreen.nameProblem("dev", taken: ["dev"])?.contains("already saved") == true)
        #expect(CredentialScreen.nameProblem("Default", taken: []) != nil)
        #expect(CredentialScreen.nameProblem("bad name", taken: []) != nil)
        #expect(CredentialScreen.nameProblem(" qa ", taken: ["dev"]) == nil)
    }

    @Test("the terminal report has emoji and a next step, and no colour codes when colour is off")
    func styledReports() {
        let saved = CredentialReport(action: "set", app: "com.example.app", key: "dev", username: "ada@example.com", saved: true, isDefault: true)
        let text = saved.styledText(style: .plain, device: "--device DEVICE")
        #expect(text.hasPrefix("✅ Saved the dev login for com.example.app"))
        #expect(text.contains("offsider login dev --device DEVICE"))
        #expect(!text.contains("\u{1B}"))
        #expect(saved.styledText(style: TerminalStyle(colours: true), device: "").contains("\u{1B}["))
        #expect(saved.styledText(style: .plain, device: "").hasSuffix("offsider login dev"))

        let empty = CredentialReport(action: "status", app: "com.example.app", saved: false)
        #expect(empty.styledText(style: .plain, device: "").contains("offsider credential set --app com.example.app"))
        let unnamed = CredentialReport(action: "status", app: "com.example.app", key: LoginCredential.defaultAccountKey, saved: false).styledText(style: .plain, device: "")
        #expect(unnamed.contains("No login named default saved for com.example.app"))
        #expect(unnamed.contains("offsider credential status --app com.example.app"))
        let missing = CredentialReport(action: "status", app: "com.example.app", key: "qa", saved: false).styledText(style: .plain, device: "")
        #expect(missing.contains("offsider credential set qa --app com.example.app"))
        let kept = CredentialReport(action: "remove", app: "com.example.app", key: LoginCredential.defaultAccountKey, saved: false).styledText(style: .plain, device: "")
        #expect(kept.contains("No login named default was saved for com.example.app"))
    }

    @Test("the styled status lists tags, notes and where each login is signed in, and no username")
    func styledStatusList() throws {
        let admin = LoginEntry(key: "qa-admin", isDefault: true, context: LoginContext(
            about: "Admin on staging", avoid: "Checkout", state: "3 items in the cart", tags: [try #require(LoginTag(rawValue: "role=admin"))]
        ))
        let signIn = LoginSignIn(device: "emulator-5554", platform: .android, since: Date(timeIntervalSince1970: 1_791_712_931), restarted: true)
        let report = CredentialReport(action: "status", app: "com.example.app", saved: true, listed: [admin, LoginEntry(key: "qa-member")], signIns: ["qa-admin": [signIn]], signedInHere: "qa-admin")
        let text = report.styledText(style: .plain, device: "")
        for expected in ["👤 qa-admin", "⭐ default", "🔖 role=admin", "💬 Admin on staging", "🚫 Checkout", "📊 3 items in the cart", "👤 qa-member", "signed in here: qa-admin"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        #expect(text.contains("📱 signed in on emulator-5554 (android) since 2026-10-11T10:02:11Z, before the device restarted"))
        #expect(!text.unicodeScalars.contains("\u{FE0F}"))
    }

    @Test("credential set adds a new name from the menu, and keeping a saved name reads no password")
    func scriptedChoices() throws {
        let store = MemoryLoginCredentialStore()
        let first = try #require(LoginCredential(username: "ada@example.com", password: "s3cret-token"))
        try store.save(first, app: "com.example.app", key: "dev", isDefault: true)

        let adding = ScriptedQuestions(choice: .create, name: "qa", credential: try #require(LoginCredential(username: "bea@example.com", password: "s3cret-token")))
        let added = try CredentialCommand.perform(.set, app: "com.example.app", key: nil, json: true, store: store, questions: adding, readCredential: adding.credential)
        #expect(added.contains("\"name\":\"qa\""))
        #expect(try store.load(app: "com.example.app", key: "qa")?.username == "bea@example.com")
        #expect(try store.defaultKey(app: "com.example.app") == "dev")

        let keeping = ScriptedQuestions(replace: false, credential: first)
        #expect(throws: PromptCancelled.self) {
            try CredentialCommand.perform(.set, app: "com.example.app", key: "qa", json: false, store: store, questions: keeping, readCredential: keeping.credential)
        }
        #expect(keeping.reads.count == 0)
        #expect(try store.load(app: "com.example.app", key: "qa")?.username == "bea@example.com")

        let replacing = ScriptedQuestions(replace: true, credential: first)
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa", json: false, store: store, questions: replacing, readCredential: replacing.credential)
        #expect(try store.load(app: "com.example.app", key: "qa")?.username == "ada@example.com")
    }

    @Test("a new login is asked what it is for and its tags after the password; an update, context flags or Escape change that")
    func newLoginContextQuestions() throws {
        let store = MemoryLoginCredentialStore()
        let credential = try #require(LoginCredential(username: "ada@example.com", password: "s3cret-token"))
        let tagged = ScriptedQuestions(credential: credential)
        tagged.contextAnswer = try CredentialScreen.contextEdit(about: " Admin on staging ", tags: "role=admin  env=staging")
        let saved = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", json: true, store: store, questions: tagged, readCredential: tagged.credential)
        #expect(tagged.contextAsks == 1)
        #expect(saved.contains(#""tags":["env=staging","role=admin"],"about":"Admin on staging""#))

        let updating = ScriptedQuestions(credential: credential)
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-admin", update: true, json: true, store: store, questions: updating, readCredential: updating.credential)
        #expect(updating.contextAsks == 0)
        let kept = LoginEntry(key: "qa-admin", stored: try #require(store.context(app: "com.example.app", key: "qa-admin")))
        #expect(kept.context.about == "Admin on staging")

        let flagged = ScriptedQuestions(credential: credential)
        _ = try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-member", edit: LoginContextEdit(about: "Member"), json: true, store: store, questions: flagged, readCredential: flagged.credential)
        #expect(flagged.contextAsks == 0)

        let escaping = ScriptedQuestions(credential: credential)
        escaping.contextAnswer = nil
        #expect(throws: PromptCancelled.self) {
            try CredentialCommand.perform(.set, app: "com.example.app", key: "qa-owner", json: true, store: store, questions: escaping, readCredential: escaping.credential)
        }
        #expect(try store.load(app: "com.example.app", key: "qa-owner") == nil)
    }

    @Test("set marks a sole unmarked login as the default only once every answer is in, so a cancelled or refused set leaves it alone")
    func defaultStampedAfterAnswers() throws {
        let store = MemoryLoginCredentialStore()
        let admin = try #require(LoginCredential(username: "admin@example.com", password: "s3cret-token"))
        try store.save(admin, app: "com.example.app", key: "qa-admin", isDefault: false)
        func set(_ questions: ScriptedQuestions, key: String? = "qa-member", reading: () throws -> LoginCredential) throws {
            _ = try CredentialCommand.perform(.set, app: "com.example.app", key: key, json: true, store: store, questions: questions, readCredential: reading)
        }

        let escapingContext = ScriptedQuestions(credential: admin)
        escapingContext.contextAnswer = nil
        #expect(throws: PromptCancelled.self) { try set(escapingContext, reading: escapingContext.credential) }
        let escapingPassword = ScriptedQuestions(choice: .create, name: "qa-member", credential: admin)
        #expect(throws: PromptCancelled.self) { try set(escapingPassword, key: nil) { throw PromptCancelled() } }
        let refused = ScriptedQuestions(credential: admin)
        #expect(throws: CLIError.self) { try set(refused) { try CredentialCommand.credential(username: "admin@example.com", password: "pass\tword") } }
        #expect(try store.defaultKey(app: "com.example.app") == nil)
        #expect(try store.load(app: "com.example.app", key: "qa-member") == nil)

        let completing = ScriptedQuestions(credential: admin)
        try set(completing, reading: completing.credential)
        #expect(try store.defaultKey(app: "com.example.app") == "qa-admin")
        #expect(try store.load(app: "com.example.app", key: "qa-member") != nil)
    }

    @Test("the about and tags answers are optional, a bad tag states the rule, and every label lines up")
    func contextAnswers() throws {
        #expect(CredentialScreen.aboutProblem("") == nil)
        #expect(CredentialScreen.aboutProblem("Signs in as qa@example.com")?.contains("email") == true)
        #expect(CredentialScreen.tagsProblem("") == nil)
        #expect(CredentialScreen.tagsProblem("role=admin credit") == nil)
        #expect(CredentialScreen.tagsProblem("role=admin Bad=Tag!")?.contains("word or key=value") == true)
        #expect(CredentialScreen.tagsProblem("platform=web")?.contains("ios or android") == true)
        #expect(CredentialScreen.tagsProblem((1...17).map { "t\($0)" }.joined(separator: " ")) != nil)
        #expect(try CredentialScreen.contextEdit(about: "  ", tags: " ").isEmpty)
        let widths = Set(CredentialScreen.promptLabels.map { TerminalText.width(CredentialScreen.padded($0)) })
        #expect(widths.count == 1)
        #expect(!CredentialScreen.promptLabels.joined().unicodeScalars.contains("\u{FE0F}"))

        let terminal = try PseudoTerminal()
        terminal.type("Admin on staging\rrole=admin Bad!\rrole=admin env=staging\r")
        let edit = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try TerminalCredentialQuestions(prompt: prompt).context()
        }
        let output = terminal.finish()
        #expect(edit.about == "Admin on staging")
        #expect(edit.tag.map(\.rawValue) == ["role=admin", "env=staging"])
        #expect(output.contains("Bad! is not a tag"))
    }

    @Test("join names both ids and offers Link or Cancel")
    func linkScreen() {
        let title = CredentialScreen.linkTitle(member: "com.example.android", canonical: "com.example.app")
        #expect(title.contains("com.example.android") && title.contains("com.example.app"))
        #expect(CredentialScreen.linkOptions.count == 2)
        #expect(CredentialScreen.linkOptions[0].hasSuffix("Link"))
        #expect(CredentialScreen.linkOptions[1].hasSuffix("Cancel"))
    }
}

private final class ScriptedQuestions: CredentialQuestions {
    var choice: LoginSetChoice = .create
    var name = "qa"
    var replace = false
    let answer: LoginCredential
    private(set) var reads: [LoginCredential] = []

    init(choice: LoginSetChoice = .create, name: String = "qa", replace: Bool = false, credential: LoginCredential) {
        self.choice = choice
        self.name = name
        self.replace = replace
        answer = credential
    }

    func loginToChange(entries: [LoginCredentialSummary]) throws -> LoginSetChoice { choice }
    func replaces(_ entry: LoginCredentialSummary) throws -> Bool { replace }
    func newName(taken: [String]) throws -> String { name }
    func credential() throws -> LoginCredential {
        reads.append(answer)
        return answer
    }

    /// The about and tags answers; nil cancels as Escape does.
    var contextAnswer: LoginContextEdit? = LoginContextEdit()
    private(set) var contextAsks = 0

    func context() throws -> LoginContextEdit {
        contextAsks += 1
        guard let contextAnswer else { throw PromptCancelled() }
        return contextAnswer
    }
}
