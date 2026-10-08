import ArgumentParser
import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Terminal prompt", .serialized)
struct TerminalPromptTests {
    @Test("a key burst splits into text, Enter and arrows, and only a trailing escape cancels")
    func keyParsing() {
        #expect(TerminalKey.parse(Array("ada\rpw\r".utf8)) == [.text(Array("ada".utf8)), .enter, .text(Array("pw".utf8)), .enter])
        #expect(TerminalKey.parse([0x1B, 0x5B, 0x42, 0x0D]) == [.down, .enter])
        #expect(TerminalKey.parse([0x1B, 0x4F, 0x41]) == [.up])
        #expect(TerminalKey.parse([0x1B, 0x5B, 0x43]) == [.ignored])
        #expect(TerminalKey.parse(Array("qa".utf8) + [0x1B]) == [.text(Array("qa".utf8)), .cancel])
        #expect(TerminalKey.parse([0x03]) == [.cancel])
        #expect(TerminalKey.parse([0x09]) == [.ignored])
    }

    @Test("the editor deletes whole characters, clears on Control-U and cancels on Control-D only when empty")
    func lineEditor() {
        var editor = LineEditor()
        #expect(editor.apply(.text(Array("pé".utf8))) == .editing)
        #expect(editor.length == 2)
        #expect(editor.apply(.backspace) == .editing)
        #expect(editor.text == "p")
        #expect(editor.apply(.endOfInput) == .editing)
        #expect(editor.apply(.clearLine) == .editing)
        #expect(editor.bytes.isEmpty)
        #expect(editor.apply(.endOfInput) == .cancelled)

        var bounded = LineEditor(capacity: 4)
        _ = bounded.apply(.text(Array("abcdef".utf8)))
        #expect(bounded.text == "abcd")
        #expect(bounded.apply(.enter) == .submitted)
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
        #expect(CredentialScreen.tagProblem("dev", taken: ["dev"])?.contains("already saved") == true)
        #expect(CredentialScreen.tagProblem("Default", taken: []) != nil)
        #expect(CredentialScreen.tagProblem("bad tag", taken: []) != nil)
        #expect(CredentialScreen.tagProblem(" qa ", taken: ["dev"]) == nil)
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
        #expect(UnlockCodeScreen.status(name: "Pixel", device: "SERIAL", saved: true, lastAttemptFailed: true, style: .plain).contains("unlock-code set --device SERIAL"))
    }

    @Test("credential set adds a new tag from the menu, and keeping a saved tag reads no password")
    func scriptedChoices() throws {
        let store = MemoryLoginCredentialStore()
        let first = try #require(LoginCredential(username: "ada@example.com", password: "s3cret-token"))
        try store.save(first, app: "com.example.app", key: "dev", isDefault: true)

        let adding = ScriptedQuestions(choice: .create, tag: "qa", credential: try #require(LoginCredential(username: "bea@example.com", password: "s3cret-token")))
        let added = try CredentialCommand.perform(.set, app: "com.example.app", key: nil, json: true, store: store, questions: adding, readCredential: adding.credential)
        #expect(added.contains("\"key\":\"qa\""))
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

    @Test("Down then Enter chooses the second row")
    func menuOnATerminal() throws {
        let terminal = try PseudoTerminal()
        terminal.type("\u{1B}[B\r")
        let index = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, descriptor: terminal.secondary) { prompt in
            try prompt.choose("📋 Pick one", options: ["📝 Update dev", CredentialScreen.addAnother])
        }
        #expect(index == 1)
        #expect(terminal.finish().contains("▸ " + CredentialScreen.addAnother))
    }
}

private final class ScriptedQuestions: CredentialQuestions {
    var choice: LoginSetChoice = .create
    var tag = "qa"
    var replace = false
    let answer: LoginCredential
    private(set) var reads: [LoginCredential] = []

    init(choice: LoginSetChoice = .create, tag: String = "qa", replace: Bool = false, credential: LoginCredential) {
        self.choice = choice
        self.tag = tag
        self.replace = replace
        answer = credential
    }

    func loginToChange(entries: [LoginCredentialSummary]) throws -> LoginSetChoice { choice }
    func replaces(_ entry: LoginCredentialSummary) throws -> Bool { replace }
    func newTag(taken: [String]) throws -> String { tag }
    func credential() throws -> LoginCredential {
        reads.append(answer)
        return answer
    }
}

/// A pseudo-terminal whose output is collected on a thread, so a prompt never blocks on a full buffer.
private final class PseudoTerminal: @unchecked Sendable {
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
            var settings = termios()
            for _ in 0..<500 {
                if tcgetattr(secondary, &settings) == 0, settings.c_lflag & tcflag_t(ECHO) == 0 { break }
                usleep(10_000)
            }
            let bytes = Array(keys.utf8)
            _ = bytes.withUnsafeBytes { write(primary, $0.baseAddress, $0.count) }
        }
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
