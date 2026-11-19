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

    @Test("an emulator text event holds at most 30 key events: 2 per character, 4 with Shift", arguments: [
        ("abcdefghijklmno", ["abcdefghijklmno"]),
        ("abcdefghijklmnop", ["abcdefghijklmno", "p"]),
        ("cam@example.com", ["cam@example.co", "m"]),
        ("ABCDEFGHIJ", ["ABCDEFG", "HIJ"]),
        ("{}|:\"<>?", ["{}|:\"<>", "?"]),
        ("", []),
    ])
    func emulatorRuns(text: String, runs: [String]) {
        #expect(AndroidTextPlan.emulatorRuns(text) == runs)
    }

    @Test("long text splits greedily, in order, with every run within the limit")
    func longEmulatorRuns() {
        let text = String(repeating: "The Quick Brown Fox Jumps Over 13 Lazy Dogs! ", count: 7)
        let runs = AndroidTextPlan.emulatorRuns(text)

        #expect(runs.joined() == text)
        #expect(runs.allSatisfy { AndroidTextPlan.keyEvents(in: $0) <= 30 })
        #expect(zip(runs, runs.dropFirst()).allSatisfy { run, next in
            AndroidTextPlan.keyEvents(in: run) + AndroidTextPlan.keyEvents(in: next.prefix(1)) > 30
        })
    }

    @Test("emulator sends wait for the guest once a burst would pass 30 key events, Return and Tab included")
    func emulatorSends() throws {
        let chunks = try #require({ if case .keys(let chunks) = try AndroidTextPlan.make(for: "hello world\ncam@example.com\tok") { return chunks } else { return nil } }())
        let sends = try AndroidTextPlan.emulatorSends(for: chunks)

        #expect(sends.map(\.event) == [
            .text("hello world"), .usb(0x070028, .press), .text("cam@example.co"), .text("m"), .usb(0x07002B, .press), .text("ok"),
        ])
        #expect(sends.map(\.afterDrain) == [false, false, true, true, false, false])
        #expect(sends.map(\.characters).reduce(0, +) == "hello world\ncam@example.com\tok".count)
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
