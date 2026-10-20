import Foundation
import OffsiderCore
import Testing

@Suite("Terminal width")
struct TerminalWidthTests {
    @Test("each character takes the columns a terminal draws it in", arguments: [
        ("Save", 4), ("\u{1B}[1mSave\u{1B}[0m", 4), ("日本", 4), ("📱", 2), ("⚠️", 2), ("⚠\u{FE0E}", 1), ("❤️", 2),
        ("👨\u{200D}👩\u{200D}👧", 2), ("👍🏽", 2), ("🇦🇺", 2), ("1️⃣", 2), ("e\u{0301}", 1), ("\u{07}\u{08}", 0), ("1", 1), ("#*", 2),
        ("🏳️\u{200D}🌈", 2), ("⚠️  iOS", 7),
    ])
    func width(text: String, expected: Int) {
        #expect(TerminalText.width(text) == expected)
    }

    @Test("every mark draws two columns and its ASCII tag stands alone")
    func marks() {
        for mark in TerminalStyle.Mark.allCases {
            #expect(TerminalText.width(mark.emoji) == 2, "\(mark) draws \(TerminalText.width(mark.emoji)) columns")
            #expect(mark.tag.hasPrefix("[") && mark.tag.hasSuffix("]") && mark.tag.allSatisfy(\.isASCII))
        }
        #expect(TerminalStyle.Mark.allCases.filter { $0.emoji.unicodeScalars.count > 1 } == [.warning])
    }

    @Test("status glyphs are one column each, coloured by meaning, and ASCII without Unicode")
    func statusGlyphs() {
        let unicode = TerminalStyle(colours: false)
        let ascii = TerminalStyle(colours: false, ascii: true)
        #expect(RowStatus.allCases.map(unicode.status) == ["●", "◐", "○", "✓", "!", "✗", "-"])
        #expect(RowStatus.allCases.map(ascii.status) == ["*", "~", "o", "+", "!", "x", "-"])
        #expect(RowStatus.allCases.allSatisfy { TerminalText.width(unicode.status($0)) == 1 })
        let coloured = TerminalStyle(colours: true)
        #expect(coloured.status(.on) == coloured.green("●"))
        #expect(coloured.status(.fail) == coloured.red("✗"))
        #expect(coloured.status(.starting) == "◐")
    }

    @Test("UI_ASCII swaps glyphs for tags unless it is empty or 0; FORCE_COLOR never adds colour", arguments: [
        ("1", true), ("yes", true), ("", false), ("0", false),
    ])
    func uiASCII(value: String, ascii: Bool) {
        let style = TerminalStyle.detect(isTerminal: true, environment: ["UI_ASCII": value, "LANG": "en_AU.UTF-8"])
        #expect(style.ascii == ascii)
        #expect(style.colours)
        #expect(!TerminalStyle.detect(isTerminal: false, environment: ["FORCE_COLOR": "1"]).colours)
    }

    @Test("a warning wraps under its text, whatever the mark is drawn as")
    func warningIndent() {
        let text = "This Xcode is not trusted, so iOS Simulators and iPhones were skipped for now."
        let lines = TerminalUI.warning(text, width: 40, style: .plain)
        #expect(lines[0].hasPrefix("⚠️  This"))
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("    ") && !$0.hasPrefix("     ") })
        let ascii = TerminalUI.warning(text, width: 40, style: TerminalStyle(colours: false, ascii: true))
        #expect(ascii.dropFirst().allSatisfy { $0.hasPrefix("    ") && !$0.hasPrefix("     ") })
    }
}

@Suite("Terminal size")
struct TerminalSizeTests {
    @Test("COLUMNS from 1 to 1000 wins, else the measured width, else 80", arguments: [
        (["COLUMNS": "44"], 120, 44), (["COLUMNS": " 200 "], nil, 200), (["COLUMNS": "0"], 120, 120), (["COLUMNS": "wide"], 120, 120),
        (["COLUMNS": "1001"], nil, 80), ([:], nil, 80), ([:], 0, 80), ([:], 30, 30),
    ] as [([String: String], Int?, Int)])
    func resolve(environment: [String: String], measured: Int?, expected: Int) {
        #expect(TerminalSize.resolve(environment: environment, measured: measured) == expected)
    }

    @Test("breakpoints split at 60, 100 and 160, and the canvas keeps one column spare and prose within 72")
    func breakpoints() {
        #expect([30, 59, 60, 99, 100, 159, 160, 400].map { Breakpoint(columns: $0) } == [.narrow, .narrow, .regular, .regular, .wide, .wide, .veryWide, .veryWide])
        #expect(Breakpoint.narrow < .veryWide)
        let canvas = Canvas(columns: 80, style: .plain)
        #expect(canvas.usable == 79 && canvas.prose == 72 && canvas.breakpoint == .regular)
        #expect(Canvas(columns: 44, style: .plain).prose == 43)
        #expect(Canvas(columns: 1, style: .plain).usable == 1)
    }

    @Test("a cut keeps whole characters and its ellipsis, at the end or in the middle")
    func truncate() {
        #expect(TerminalText.truncate("iPad Air 13-inch (M3)", to: 10) == "iPad Air …")
        #expect(TerminalText.truncate("iPad Air 13-inch (M3)", to: 10, at: .middle) == "iPad …(M3)")
        #expect(TerminalText.truncate("📱📱📱", to: 4) == "📱…")
        #expect(TerminalText.truncate("short", to: 10) == "short")
        #expect(TerminalText.truncate("abc", to: 0).isEmpty)
        #expect(TerminalText.truncate("abcdef", to: 4, ellipsis: "...") == "a...")
    }

    @Test("prose never breaks inside a code span, and a person sees the span cyan without its backticks")
    func codeSpans() {
        let lines = PromptScreen.wrap("Run `offsider devices --platform android` to see them", width: 20)
        #expect(lines.contains("`offsider devices --platform android`"))
        #expect(PromptScreen.wrap("a `b c", width: 3) == ["a", "`b", "c"])
        let style = TerminalStyle(colours: true)
        #expect(TerminalText.codeSpans("Run `offsider doctor` now", style: style) == "Run " + style.cyan("offsider doctor") + " now")
        #expect(TerminalText.codeSpans("odd ` tick", style: style) == "odd ` tick")
        #expect(TerminalText.firstSentence("Xcode is missing. Install it from the App Store.") == ("Xcode is missing.", "Install it from the App Store."))
        #expect(TerminalText.firstSentence("Use v1.2. then go") == ("Use v1.2. then go", ""))
    }
}
