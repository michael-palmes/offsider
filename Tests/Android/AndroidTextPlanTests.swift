import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android text plan")
struct AndroidTextPlanTests {
    @Test("ASCII text is typed, with Return and Tab as key presses")
    func asciiKeys() throws {
        #expect(try AndroidTextPlan.make(for: "hi there\nnext\tcell") == .keys([
            .text("hi there"), .key(usage: 40), .text("next"), .key(usage: 43), .text("cell"),
        ]))
        #expect(try AndroidTextPlan.make(for: "a\r\nb") == .keys([.text("a"), .key(usage: 40), .text("b")]))
    }

    @Test("long runs split at 256 bytes")
    func chunks() throws {
        let text = String(repeating: "x", count: 600)
        #expect(try AndroidTextPlan.make(for: text) == .keys([
            .text(String(repeating: "x", count: 256)), .text(String(repeating: "x", count: 256)), .text(String(repeating: "x", count: 88)),
        ]))
    }

    @Test("any non-ASCII character makes the whole string one paste", arguments: ["héllo", "日本語", "ok 🙂", "mixed ascii and é"])
    func nonASCIIPastes(text: String) throws {
        #expect(try AndroidTextPlan.make(for: text) == .paste(text))
    }

    @Test("other control characters fail before anything is typed")
    func controlCharacters() {
        let error = #expect(throws: AndroidError.self) { try AndroidTextPlan.make(for: "ding\u{7}") }
        #expect(error?.message == "Cannot type the control character U+0007 on Android. Use `key` for special keys.")
        #expect(throws: AndroidError.self) { try AndroidTextPlan.make(for: "lone\rreturn") }
    }

    @Test("an empty string types nothing")
    func empty() throws {
        #expect(try AndroidTextPlan.make(for: "") == .keys([]))
    }
}
