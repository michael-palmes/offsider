import Foundation
@testable import OffsiderCore
import Testing

@Suite("Terminal text")
struct TerminalTextTests {
    @Test("clean text comes back unchanged, emoji joiners and other scripts included", arguments: [
        "Sign in",
        "Café 👩‍👩‍👧 ok",
        "क्षि and നന്ദി",
        "tab\there",
        "",
    ])
    func cleanUnchanged(text: String) {
        #expect(TerminalText.line(text) == text)
        #expect(TerminalText.block(text) == text)
        #expect(TerminalText.bareOrQuoted(text) == text || text.contains("\t"))
    }

    @Test("each hazard class is escaped JSON style", arguments: [
        ("a\u{1B}[2Jb", #"a\u001b[2Jb"#),
        ("bell\u{07}", #"bell\u0007"#),
        ("del\u{7F}", #"del\u007f"#),
        ("c1\u{9B}31m", #"c1\u009b31m"#),
        ("line\nbreak\r", #"line\nbreak\r"#),
        ("\u{202E}evil", #"\u202eevil"#),
        ("iso\u{2066}late\u{2069}", #"iso\u2066late\u2069"#),
        ("zero\u{200B}width\u{200E}\u{200F}", #"zero\u200bwidth\u200e\u200f"#),
        ("sep\u{2028}\u{2029}", #"sep\u2028\u2029"#),
        ("arabic\u{061C}mark", #"arabic\u061cmark"#),
        ("word\u{2060}joiner\u{2064}", #"word\u2060joiner\u2064"#),
        ("\u{FEFF}bom", #"\ufeffbom"#),
        ("anno\u{FFF9}tation\u{FFFB}", #"anno\ufff9tation\ufffb"#),
        ("tag\u{E0041}\u{E007F}", #"tag\udb40\udc41\udb40\udc7f"#),
        ("soft\u{00AD}hyphen", #"soft\u00adhyphen"#),
        ("mongolian\u{180E}vowel", #"mongolian\u180evowel"#),
        ("deprecated\u{206A}format\u{206F}", #"deprecated\u206aformat\u206f"#),
        ("selector\u{FE00}\u{FE0F}", #"selector\ufe00\ufe0f"#),
        ("\u{FE0F}leading", #"\ufe0fleading"#),
        ("a\u{FE0F}\u{FE0F}", "a\u{FE0F}\\ufe0f"),
        ("supplement\u{E0100}\u{E01EF}", #"supplement\udb40\udd00\udb40\uddef"#),
    ])
    func hazardsEscaped(text: String, expected: String) {
        #expect(TerminalText.line(text) == expected)
    }

    @Test("an OSC 52 clipboard write shows inert, with no escape or bell byte left")
    func osc52Inert() {
        let shown = TerminalText.line("\u{1B}]52;c;ZXZpbA==\u{07}")
        #expect(shown == #"\u001b]52;c;ZXZpbA==\u0007"#)
        #expect(!shown.utf8.contains(0x1B))
        #expect(!shown.utf8.contains(0x07))
    }

    @Test("a line never holds a newline, and a tab is kept only when asked")
    func oneLine() {
        #expect(!TerminalText.line("a\nb\r\nc\u{2028}d").contains("\n"))
        #expect(TerminalText.line("a\tb") == "a\tb")
        #expect(TerminalText.line("a\tb", keepsTab: false) == #"a\tb"#)
    }

    @Test("a block keeps its lines, escapes hazards and indents any continuation line that starts at column 0")
    func block() {
        #expect(TerminalText.block("first\nError: forged\n  - kept\n") == "first\n  Error: forged\n  - kept")
        #expect(TerminalText.block("a\u{1B}]0;x\u{07}\nb") == "a\\u001b]0;x\\u0007\n  b")
        #expect(TerminalText.block("a\rb") == #"a\rb"#)
    }

    @Test("long text is cut at 500 characters with how many were left out, never inside a grapheme")
    func capped() {
        let long = String(repeating: "a", count: 499) + String(repeating: "👩‍👩‍👧", count: 3)
        let shown = TerminalText.line(long)
        #expect(shown == String(repeating: "a", count: 499) + "👩‍👩‍👧" + "…(+2)")
        #expect(TerminalText.line(String(repeating: "b", count: 500)) == String(repeating: "b", count: 500))
        #expect(TerminalText.capped(String(repeating: "c", count: 510), cap: 10) == String(repeating: "c", count: 10) + "…(+500)")
        #expect(TerminalText.line(String(repeating: "d", count: 600), cap: nil).count == 600)
        #expect(TerminalText.line(String(repeating: "e", count: 501)) == String(repeating: "e", count: 500) + "…(+1)")
    }

    @Test("one character holding thousands of combining marks is cut by scalars, so it cannot flood the output")
    func combiningFlood() {
        let flood = "a" + String(repeating: "\u{0301}", count: 20_000)
        let shown = TerminalText.line(flood)
        let marker = "…(+19501)"
        #expect(shown.hasSuffix(marker))
        #expect(shown.unicodeScalars.count - marker.unicodeScalars.count <= 600)
        #expect(TerminalText.line("ok " + flood).hasSuffix("…(+19504)"))
    }

    @Test("colour codes survive only with keepsSGR; other escapes never do")
    func sgr() {
        let text = "\u{1B}[1;32mok\u{1B}[0m \u{1B}[2J"
        #expect(TerminalText.line(text, keepsSGR: true) == "\u{1B}[1;32mok\u{1B}[0m \\u001b[2J")
        #expect(TerminalText.line(text) == #"\u001b[1;32mok\u001b[0m \u001b[2J"#)
    }

    @Test("quoted text is JSON that decodes back to the original")
    func jsonRoundTrip() throws {
        let hostile = "a\"b\\c\u{1B}]52;c;eA==\u{07}\u{202E}\u{E0041}\n👩‍👩‍👧"
        let quoted = TerminalText.quoted(hostile)
        #expect(!quoted.utf8.contains(0x1B))
        #expect(!quoted.unicodeScalars.contains("\u{202E}"))
        let decoded = try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
        #expect(decoded == hostile)
    }

    @Test("bare when clean, quoted when it holds a hazard")
    func bareOrQuoted() {
        #expect(TerminalText.bareOrQuoted("Lab Toggles") == "Lab Toggles")
        #expect(TerminalText.bareOrQuoted("Lab\u{1B}[2J") == #""Lab\u001b[2J""#)
        #expect(TerminalText.bareOrQuoted("two\nlines") == #""two\nlines""#)
    }

    @Test("isHazard leaves the joiners alone")
    func joiners() {
        #expect(!TerminalText.isHazard("\u{200C}"))
        #expect(!TerminalText.isHazard("\u{200D}"))
        #expect(TerminalText.isHazard("\u{200B}"))
        #expect(!TerminalText.isHazard(" "))
        #expect(!TerminalText.isHazard("é"))
        #expect(!TerminalText.isHazard("\u{00AC}"))
        #expect(!TerminalText.isHazard("\u{FE10}"))
        #expect(!TerminalText.isHazard("\u{2065}"))
    }
}

@Suite("Presentation selectors in ordinary emoji")
struct PresentationSelectorTests {
    @Test("a lone U+FE0F or U+FE0E after a visible scalar is ordinary text, as every emoji label needs")
    func emojiLabelsStay() {
        let label = "\u{270F}\u{FE0F} Typing active \u{2764}\u{FE0F} \u{263A}\u{FE0E}"
        #expect(TerminalText.line(label) == label)
        #expect(TerminalText.bareOrQuoted(label) == label)
        var json = ""
        OrderedJSON.writeString(label, to: &json)
        #expect(json == "\"\(label)\"")
    }
}
