import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Terminal prompt", .serialized)
struct TerminalPromptTests {
    @Test("a key burst splits into text, Enter and arrows, and only a trailing escape cancels")
    func keyParsing() {
        #expect(TerminalKey.parse(Array("ada\rpw\r".utf8)) == [.text(Array("ada".utf8)), .enter, .text(Array("pw".utf8)), .enter])
        #expect(TerminalKey.parse([0x1B, 0x5B, 0x42, 0x0D]) == [.down, .enter])
        #expect(TerminalKey.parse([0x1B, 0x4F, 0x41]) == [.up])
        #expect(TerminalKey.parse([0x1B, 0x5B, 0x33, 0x7E]) == [.ignored])
        #expect(TerminalKey.parse(Array("qa".utf8) + [0x1B]) == [.text(Array("qa".utf8)), .cancel])
        #expect(TerminalKey.parse([0x03]) == [.cancel])
        #expect(TerminalKey.parse([0x1B, 0x1B]) == [.cancel, .cancel])
    }

    @Test("Left and Right parse whole in CSI and SS3 form, with or without modifiers, and Control-W is its own key")
    func editingKeyParsing() {
        #expect(TerminalKey.parse(Array("\u{1B}[D\u{1B}[C".utf8)) == [.left, .right])
        #expect(TerminalKey.parse(Array("\u{1B}OD\u{1B}OC".utf8)) == [.left, .right])
        #expect(TerminalKey.parse(Array("\u{1B}[1;5Dqa".utf8)) == [.left, .text(Array("qa".utf8))])
        #expect(TerminalKey.parse(Array("qa admin\u{17}x".utf8)) == [.text(Array("qa admin".utf8)), .deleteWord, .text(Array("x".utf8))])
    }

    @Test("a read that stops inside an escape sequence waits for the rest, and a finished one does not")
    func partialEscapeSequences() {
        #expect(TerminalKey.endsMidSequence(Array("ab".utf8) + [0x1B]))
        #expect(TerminalKey.endsMidSequence(Array("ab".utf8) + [0x1B, 0x5B]))
        #expect(TerminalKey.endsMidSequence([0x1B, 0x5B, 0x31, 0x3B]))
        #expect(TerminalKey.endsMidSequence([0x1B, 0x4F]))
        #expect(!TerminalKey.endsMidSequence([0x1B, 0x5B, 0x41, 0x61]))
        #expect(!TerminalKey.endsMidSequence([0x1B, 0x4F, 0x41]))
        #expect(!TerminalKey.endsMidSequence([0x1B, 0x78]))
        #expect(!TerminalKey.endsMidSequence(Array("ab".utf8)))
    }

    @Test("a pasted tab stays in the answer, so the password is refused instead of saved without it")
    func controlCharactersAreKept() {
        #expect(TerminalKey.parse(Array("pass\tword\r".utf8)) == [.text(Array("pass\tword".utf8)), .enter])
        #expect(CredentialScreen.passwordProblem("pass\tword") == PromptScreen.untypeable)
        #expect(PromptScreen.visible("ada\t@") == "ada?@")
    }

    @Test("the editor deletes whole characters, clears on Control-U and cancels on Control-D only when empty")
    func lineEditor() {
        let editor = LineEditor()
        #expect(editor.apply(.text(Array("pé".utf8))) == .editing)
        #expect(editor.length == 2)
        #expect(editor.apply(.backspace) == .editing)
        #expect(editor.text == "p")
        #expect(editor.apply(.endOfInput) == .editing)
        #expect(editor.apply(.clearLine) == .editing)
        #expect(editor.isEmpty)
        #expect(editor.apply(.endOfInput) == .cancelled)

        let bounded = LineEditor(capacity: 4)
        _ = bounded.apply(.text(Array("abcdef".utf8)))
        #expect(bounded.text == "abcd")
        #expect(bounded.apply(.enter) == .submitted)
    }

    @Test("Left and Right move by whole characters, typing inserts at the cursor, and Control-W deletes back over spaces, then a word")
    func lineEditorCursor() {
        let editor = LineEditor()
        _ = editor.apply(.text(Array("admn".utf8)))
        _ = editor.apply(.left)
        _ = editor.apply(.text(Array("i".utf8)))
        #expect(editor.text == "admin")
        #expect(editor.textBeforeCursor == "admi")
        _ = editor.apply(.right)
        _ = editor.apply(.right)
        #expect(editor.textBeforeCursor == "admin")

        _ = editor.apply(.text(Array(" env  ".utf8)))
        #expect(editor.apply(.deleteWord) == .editing)
        #expect(editor.text == "admin ")
        _ = editor.apply(.deleteWord)
        #expect(editor.isEmpty)

        _ = editor.apply(.text(Array("qa admin env".utf8)))
        for _ in 0..<4 { _ = editor.apply(.left) }
        _ = editor.apply(.deleteWord)
        #expect(editor.text == "qa  env")
        #expect(editor.textBeforeCursor == "qa ")
        _ = editor.apply(.backspace)
        #expect(editor.text == "qa env")
        for _ in 0..<5 { _ = editor.apply(.left) }
        _ = editor.apply(.backspace)
        _ = editor.apply(.deleteWord)
        #expect(editor.text == "qa env")
        #expect(editor.textBeforeCursor.isEmpty)

        let accented = LineEditor()
        _ = accented.apply(.text(Array("pé".utf8)))
        _ = accented.apply(.left)
        #expect(accented.textBeforeCursor == "p")
        _ = accented.apply(.right)
        #expect(accented.textBeforeCursor == "pé")
    }

    @Test("a masked editor ignores Left and Right, and its Control-W deletes everything before the cursor")
    func maskedLineEditor() {
        let editor = LineEditor(masked: true)
        _ = editor.apply(.text(Array("qwz kvx".utf8)))
        _ = editor.apply(.left)
        _ = editor.apply(.text(Array("!".utf8)))
        #expect(editor.text == "qwz kvx!")
        #expect(editor.apply(.deleteWord) == .editing)
        #expect(editor.isEmpty)
    }

    @Test("the cursor goes back to its column, up a row when the line wrapped, and stays put at the end")
    func cursorPlacement() {
        let short = TerminalText.cursorMove(width: 10, to: 7, columns: 80)
        #expect(short.sequence == "\u{1B}[8G")
        #expect(short.row == 0)
        let wrapped = TerminalText.cursorMove(width: 25, to: 5, columns: 20)
        #expect(wrapped.sequence == "\u{1B}[1A\u{1B}[6G")
        #expect(wrapped.row == 0)
        let secondRow = TerminalText.cursorMove(width: 25, to: 22, columns: 20)
        #expect(secondRow.sequence == "\u{1B}[3G")
        #expect(secondRow.row == 1)
        let full = TerminalText.cursorMove(width: 20, to: 19, columns: 20)
        #expect(full.sequence == "\u{1B}[20G")
        #expect(full.row == 0)
        let atEnd = TerminalText.cursorMove(width: 40, to: 40, columns: 20)
        #expect(atEnd.sequence.isEmpty)
        #expect(atEnd.row == 1)
    }

    @Test("the menu wraps, chooses by Enter or number, and cancels on Escape or q")
    func choiceMenu() {
        var menu = ChoiceMenu(count: 3)
        #expect(menu.apply(.up) == .moving)
        #expect(menu.selected == 2)
        #expect(menu.apply(.down) == .moving)
        #expect(menu.apply(.enter) == .chosen(0))
        #expect(menu.apply(.text(Array("2".utf8))) == .chosen(1))
        #expect(menu.apply(.text(Array("9".utf8))) == .moving)
        #expect(menu.apply(.text(Array("q".utf8))) == .cancelled)
        #expect(menu.apply(.cancel) == .cancelled)
    }

    @Test("rows count emoji as two columns, so a redraw moves back over exactly what it drew")
    func rowMaths() {
        #expect(TerminalText.width("🔑 Password") == 11)
        #expect(TerminalText.width("\u{1B}[36m📝 Update\u{1B}[0m") == 9)
        #expect(TerminalText.rows("🔑" + String(repeating: "•", count: 18), columns: 20) == 1)
        #expect(TerminalText.rows("🔑" + String(repeating: "•", count: 19), columns: 20) == 2)
        #expect(TerminalText.rows("title\n  row\n", columns: 20) == 3)
    }

    @Test("colour only on a terminal, and never with NO_COLOR or TERM=dumb")
    func colourGate() {
        #expect(TerminalStyle.detect(isTerminal: true, environment: [:]).colours)
        #expect(!TerminalStyle.detect(isTerminal: false, environment: [:]).colours)
        #expect(!TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": "1"]).colours)
        #expect(TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": ""]).colours)
        #expect(!TerminalStyle.detect(isTerminal: true, environment: ["TERM": "dumb"]).colours)
        #expect(TerminalStyle.plain.green("ok") == "ok")
    }

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
        #expect(UnlockCodeScreen.codeProblem("123") != nil)
        #expect(UnlockCodeScreen.codeProblem("1234") == nil)
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
        #expect(UnlockCodeScreen.status(name: "Pixel", device: "SERIAL", saved: true, lastAttemptFailed: true, style: .plain).contains("unlock-code set --device SERIAL"))
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

    @Test("a typed password reaches the terminal only as dots, and a mismatch asks again")
    func passwordShowsDots() throws {
        let terminal = try PseudoTerminal()
        terminal.type("ada@example.com\rs3cret-one\rs3cret-two\rs3cret-one\rs3cret-one\r")
        let answers = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            let username = try prompt.ask("👤 ", check: CredentialScreen.usernameProblem)
            let password = try prompt.askSecret("🔑 ", again: "🔁 ", check: CredentialScreen.passwordProblem)
            return [username, password]
        }
        #expect(terminal.echoes)
        let output = terminal.finish()
        #expect(answers == ["ada@example.com", "s3cret-one"])
        #expect(!output.contains("s3cret"))
        #expect(output.contains(PromptScreen.dots(10)))
        #expect(output.contains(PromptScreen.mismatch))
        #expect(output.contains("ada@example.com"))
    }

    @Test("the read buffer and every line editor are zeroed and freed after a secret is read, mismatched or cancelled")
    func secretBuffersAreZeroed() throws {
        let read = try auditingSecrets(typing: "s3cret-one\rs3cret-two\rs3cret-one\rs3cret-one\r")
        #expect(read.answer == "s3cret-one")
        #expect(read.audit.made.filter { $0 == LineEditor.defaultCapacity }.count == 4)
        #expect(read.audit.made.contains(TerminalPrompt.readSize))
        #expect(read.audit.released.count == read.audit.made.count)
        #expect(read.audit.released.allSatisfy { $0.allSatisfy { $0 == 0 } })

        let cancelled = try auditingSecrets(typing: "s3cret-one\rs3cr\u{1B}")
        #expect(cancelled.exit == 130)
        #expect(cancelled.audit.made.filter { $0 == LineEditor.defaultCapacity }.count == 2)
        #expect(cancelled.audit.made.contains(TerminalPrompt.readSize))
        #expect(cancelled.audit.released.count == cancelled.audit.made.count)
        #expect(cancelled.audit.released.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("a wiped key holds no typed bytes, and other keys are left alone")
    func keyWipe() {
        var typed = TerminalKey.text(Array("s3cret".utf8))
        typed.wipe()
        #expect(typed == .ignored)
        var enter = TerminalKey.enter
        enter.wipe()
        #expect(enter == .enter)
    }

    /// Types `keys` into a secret prompt while recording every `SecretBytes` made and freed.
    private func auditingSecrets(typing keys: String) throws -> (answer: String?, exit: Int32?, audit: SecretAudit) {
        let audit = SecretAudit()
        SecretBytes.audit = audit.record
        defer { SecretBytes.audit = nil }
        let terminal = try PseudoTerminal()
        terminal.type(keys)
        do {
            let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
                try prompt.askSecret("🔑 ", again: "🔁 ") { _ in nil }
            }
            _ = terminal.finish()
            return (answer, nil, audit)
        } catch let exit as ExitCode {
            _ = terminal.finish()
            return (nil, exit.rawValue, audit)
        }
    }

    @Test("echo and Control-C stay on while no question waits, so a slow Keychain read can still be stopped")
    func normalTerminalBetweenQuestions() throws {
        let terminal = try PseudoTerminal()
        terminal.type("ada\r")
        let states = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            let before = terminal.signals
            _ = try prompt.ask("👤 ") { _ in nil }
            return [before, terminal.signals]
        }
        _ = terminal.finish()
        #expect(states == [true, true])
    }

    @Test("Escape says nothing was saved, exits 130 and gives the terminal back")
    func escapeCancels() throws {
        let terminal = try PseudoTerminal()
        terminal.type("ada\u{1B}")
        let error = #expect(throws: ExitCode.self) {
            try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
                try prompt.ask("👤 ") { _ in nil }
            }
        }
        #expect(error?.rawValue == 130)
        #expect(terminal.echoes)
        #expect(terminal.finish().contains(PromptScreen.cancelledNothingSaved))
    }

    @Test("an arrow key split across two reads moves the cursor instead of adding a letter to the answer")
    func splitArrowKey() throws {
        let terminal = try PseudoTerminal()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            terminal.send("ab\u{1B}[")
            _ = terminal.wait(until: { settings in withUnsafeBytes(of: settings.c_cc) { $0[Int(VTIME)] } > 0 })
            terminal.send("A\r")
        }
        let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.ask("👤 ") { _ in nil }
        }
        _ = terminal.finish()
        #expect(answer == "ab")
    }

    @Test("a Left split across two reads moves the cursor instead of adding a letter to the answer")
    func splitLeftKey() throws {
        let terminal = try PseudoTerminal()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            terminal.send("ab\u{1B}[")
            _ = terminal.wait(until: { settings in withUnsafeBytes(of: settings.c_cc) { $0[Int(VTIME)] } > 0 })
            terminal.send("Dc\r")
        }
        let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.ask("👤 ") { _ in nil }
        }
        _ = terminal.finish()
        #expect(answer == "acb")
    }

    @Test("Left puts the cursor back over the typed text, and typing there inserts")
    func cursorOnATerminal() throws {
        let terminal = try PseudoTerminal()
        let placed = Recorded<Bool>()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            terminal.send("qa-amn\u{1B}[D")
            placed.append(terminal.wait(forOutput: "qa-amn\u{1B}[9G"))
            terminal.send("i\u{1B}OC\r")
        }
        let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.ask("👤 ") { _ in nil }
        }
        _ = terminal.finish()
        #expect(answer == "qa-amin")
        #expect(placed.values == [true])
    }

    @Test("a secret prompt draws only dots through Control-W, Left and Right, and never a typed character")
    func secretEditingKeys() throws {
        let terminal = try PseudoTerminal()
        let drawn = Recorded<Bool>()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            terminal.send("qwz kvx")
            drawn.append(terminal.wait(forDots: 7))
            terminal.send("\u{17}")
            drawn.append(terminal.wait(forDots: 0))
            terminal.send("vvq\u{1B}[D\u{1B}OD")
            drawn.append(terminal.wait(forDots: 3))
            terminal.send("\u{1B}[Cz\rvvqz\r")
        }
        let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.askSecret("🔑 ", again: "🔁 ") { _ in nil }
        }
        let output = terminal.finish()
        #expect(answer == "vvqz")
        #expect(drawn.values == [true, true, true])
        #expect(!output.contains { "qwzkvx".contains($0) })
    }

    @Test("a continue after a stop switches echo off again, so a password typed after bash's fg never shows")
    func continueSwitchesEchoOff() throws {
        let terminal = try PseudoTerminal()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            var cooked = termios()
            _ = tcgetattr(terminal.secondary, &cooked)
            cooked.c_lflag |= tcflag_t(ECHO | ICANON)
            _ = tcsetattr(terminal.secondary, TCSANOW, &cooked)
            kill(getpid(), SIGCONT)
            _ = terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 })
            terminal.send("s3cret\n")
        }
        let answer = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.ask("🔑 ", masked: true) { _ in nil }
        }
        let output = terminal.finish()
        #expect(answer == "s3cret")
        #expect(!output.contains("s3cret"))
        #expect(output.contains(PromptScreen.dots(6)))
    }

    @Test("Down then Enter chooses the second row")
    func menuOnATerminal() throws {
        let terminal = try PseudoTerminal()
        terminal.type("\u{1B}[B\r")
        let index = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.choose("📋 Pick one", options: ["📝 Update dev", CredentialScreen.addAnother])
        }
        #expect(index == 1)
        #expect(terminal.finish().contains(TerminalStyle.detect(isTerminal: true).picked + " " + CredentialScreen.addAnother))
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

/// Values a sender thread records for the test to check.
private final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }

    var values: [Value] { lock.withLock { stored } }
}

/// Every `SecretBytes` made, by capacity, and each one's allocation as it was freed.
private final class SecretAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SecretBytes.AuditEvent] = []

    func record(_ event: SecretBytes.AuditEvent) {
        lock.withLock { events.append(event) }
    }

    var made: [Int] {
        lock.withLock { events.compactMap { if case .made(let capacity) = $0 { capacity } else { nil } } }
    }

    var released: [[UInt8]] {
        lock.withLock { events.compactMap { if case .released(let bytes) = $0 { bytes } else { nil } } }
    }
}

/// A pseudo-terminal whose output is collected on a thread, so a prompt never blocks on a full buffer.
final class PseudoTerminal: @unchecked Sendable {
    let primary: Int32
    let secondary: Int32
    private let lock = NSLock()
    private var output: [UInt8] = []
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
                lock.withLock { output.append(contentsOf: buffer[..<count]) }
            }
            drained.signal()
        }
    }

    /// Types `keys` in one burst once the prompt has switched echo off.
    func type(_ keys: String) {
        Thread.detachNewThread { [self] in
            _ = wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 })
            send(keys)
        }
    }

    /// Waits up to 5 s for the prompt's terminal settings to pass `ready`, and says whether they did.
    func wait(until ready: (termios) -> Bool) -> Bool {
        var settings = termios()
        for _ in 0..<5000 {
            if tcgetattr(secondary, &settings) == 0, ready(settings) { return true }
            usleep(1000)
        }
        return false
    }

    /// Waits up to 5 s for `text` to appear in what the prompt drew, and says whether it did.
    func wait(forOutput text: String) -> Bool {
        poll { $0.contains(text) }
    }

    /// Waits up to 5 s for the latest draw to end in exactly `count` dots, and says whether it did.
    func wait(forDots count: Int) -> Bool {
        poll { !$0.isEmpty && $0.reversed().prefix { $0 == "•" }.count == count }
    }

    private func poll(_ ready: (String) -> Bool) -> Bool {
        for _ in 0..<5000 {
            if ready(lock.withLock { String(decoding: output, as: UTF8.self) }) { return true }
            usleep(1000)
        }
        return false
    }

    func send(_ keys: String) {
        let bytes = Array(keys.utf8)
        _ = bytes.withUnsafeBytes { write(primary, $0.baseAddress, $0.count) }
    }

    /// True while Control-C raises a signal rather than arriving as a key.
    var signals: Bool {
        var settings = termios()
        return tcgetattr(secondary, &settings) == 0 && settings.c_lflag & tcflag_t(ISIG) != 0
    }

    /// True once the prompt has put echo back on.
    var echoes: Bool {
        var settings = termios()
        return tcgetattr(secondary, &settings) == 0 && settings.c_lflag & tcflag_t(ECHO) != 0
    }

    /// Closes the terminal and returns everything drawn on it.
    func finish() -> String {
        close(secondary)
        drained.wait()
        close(primary)
        return lock.withLock { String(decoding: output, as: UTF8.self) }
    }
}

@Suite("Person-only prompts")
struct PersonOnlyPromptTests {
    @Test("join names both ids and offers Link or Cancel")
    func linkScreen() {
        let title = CredentialScreen.linkTitle(member: "com.example.android", canonical: "com.example.app")
        #expect(title.contains("com.example.android") && title.contains("com.example.app"))
        #expect(CredentialScreen.linkOptions.count == 2)
        #expect(CredentialScreen.linkOptions[0].hasSuffix("Link"))
        #expect(CredentialScreen.linkOptions[1].hasSuffix("Cancel"))
    }

    @Test("unlock-code set --stdin with no terminal to confirm on is person_required, before the pipe is read")
    func pipedCodeNeedsATerminal() async {
        let error = await PersonPresence.$controllingTerminal.withValue({ false }) {
            await #expect(throws: CLIError.self) { try await UnlockCodeCommand.confirmedStandardInput(name: "Offsider_E2E", device: "Offsider_E2E") }
        }
        #expect(error?.reason == .personRequired)
        #expect(error?.hint == nil)
        #expect(error?.userFacingDescription.contains("`offsider unlock-code set --device Offsider_E2E`") == true)
        #expect(UnlockCodeCommand.pipedTitle(name: "Offsider_E2E").contains("Offsider_E2E"))
    }
}
