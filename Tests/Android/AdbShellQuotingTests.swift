import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("adb shell quoting")
struct AdbShellQuotingTests {
    @Test("words are single-quoted with embedded quotes escaped", arguments: [
        ("plain", "'plain'"),
        ("it's", #"'it'\''s'"#),
        ("", "''"),
        ("$(reboot); `id` \"x\"", "'$(reboot); `id` \"x\"'"),
    ])
    func quoting(text: String, expected: String) {
        #expect(AdbShellQuoting.quote(text) == expected)
    }

    @Test("spaces go as %s so input text keeps them")
    func spacesBecomePercentS() {
        #expect(AdbShellQuoting.inputTextCommands(for: "hello world") == ["input text 'hello%sworld'"])
    }

    @Test("a literal %s is split across two calls so it is not turned into a space")
    func literalPercentS() {
        #expect(AdbShellQuoting.inputTextCommands(for: "50%sale") == ["input text '50%'", "input text 'sale'"])
        #expect(AdbShellQuoting.inputTextCommands(for: "%s") == ["input text '%'", "input text 's'"])
    }

    @Test("a percent sign before a space stays literal")
    func percentBeforeSpace() {
        #expect(AdbShellQuoting.inputTextCommands(for: "100% sure") == ["input text '100%%ssure'"])
    }

    @Test("quotes inside typed text stay inside one shell word")
    func quotesInText() {
        #expect(AdbShellQuoting.inputTextCommands(for: "don't") == [#"input text 'don'\''t'"#])
    }

    @Test("an empty string sends nothing")
    func emptyText() {
        #expect(AdbShellQuoting.inputTextCommands(for: "").isEmpty)
    }
}
