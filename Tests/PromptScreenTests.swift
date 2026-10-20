import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Prompt screen", .serialized)
struct PromptScreenTests {
    static let unicode = TerminalStyle(colours: false)
    static let ascii = TerminalStyle(colours: false, ascii: true)

    static let iPad = DeviceSummary(id: "00008140-000000000000ABCD", platform: .ios, state: "Booted", name: "Apple iPad Air", osVersion: nil, deviceType: "iPad Air", kind: .physical, connection: "usb")
    static let phone = DeviceSummary(id: "R58M123ABC", platform: .android, state: "device", name: "Pixel 9", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")

    @Test("prose wraps between words at the terminal width, never past 72 columns, with continuation lines indented")
    func wrapping() {
        #expect(PromptScreen.width(columns: 200) == 72)
        #expect(PromptScreen.width(columns: 50) == 50)
        #expect(PromptScreen.width(columns: nil) == 72)
        let text = "Agents on this Mac can then tap, type and see it until it expires."
        let narrow = PromptScreen.wrap(text, width: 30, indent: "  ")
        #expect(narrow == ["Agents on this Mac can then", "  tap, type and see it until", "  it expires."])
        #expect(narrow.allSatisfy { TerminalText.width($0) <= 30 })
        #expect(narrow.joined(separator: " ").split(separator: " ") == text.split(separator: " "))
        #expect(PromptScreen.wrap(text, width: 72) == [text])
        #expect(PromptScreen.wrap("    a  b", width: 72) == ["    a  b"])
        #expect(PromptScreen.wrap("unbreakable-word-longer-than-the-line", width: 10, indent: "  ") == ["unbreakable-word-longer-than-the-line"])
    }

    @Test("a summary breaks only between its parts")
    func packing() {
        let lines = PromptScreen.pack(["Test Tablet Large", "any app", "12 hours", "team ABCDE12345"], separator: " · ", width: 40, indent: "  ")
        #expect(lines == ["Test Tablet Large · any app · 12 hours ·", "  team ABCDE12345"])
    }

    @Test("ASCII tags stand in for emoji with NO_COLOR or a locale that is not UTF-8, and the columns still line up")
    func asciiFallback() {
        #expect(!TerminalStyle.detect(isTerminal: true, environment: ["LANG": "en_AU.UTF-8"]).ascii)
        #expect(!TerminalStyle.detect(isTerminal: true, environment: [:]).ascii)
        #expect(TerminalStyle.detect(isTerminal: true, environment: ["LANG": "C"]).ascii)
        #expect(TerminalStyle.detect(isTerminal: true, environment: ["LC_ALL": "C", "LANG": "en_AU.UTF-8"]).ascii)
        #expect(TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": "1", "LANG": "en_AU.UTF-8"]).ascii)
        let rows = [Self.iPad, Self.phone].map { AllowScreen.deviceRow($0, key: $0.id, style: Self.ascii) } + [MenuRow(.cancel, [AllowScreen.done])]
        let menu = TerminalUI.menu(AllowScreen.deviceQuestion, step: "1/4", rows: rows, selected: 0, controls: .init(rescan: true), width: 72, style: Self.ascii)
        #expect(menu.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(menu == """
            1/4 Which phone or tablet? (up/down, Enter, R rescan, Q quit)

              > [iPad]     iPad Air  ...ABCD
                [Android]  Pixel 9   ...3ABC
                [x]        Done
            """)
        #expect(TerminalUI.receipt("Device", "iPad", style: Self.ascii) == "[OK] Device    iPad")
        #expect(AllowScreen.header(width: 30, style: Self.ascii) == [
            String(repeating: "=", count: 30), "  Allow agents to control which phone or tablet", String(repeating: "=", count: 30), "",
        ])
        #expect(TerminalUI.warning(AllowScreen.noDevice, width: 72, style: Self.ascii) == ["[!] " + AllowScreen.noDevice])
    }

    @Test("the banner is the whole intro: double rules as wide as the prose, the emoji and the title")
    func banner() {
        #expect(AllowScreen.header(width: 50, style: Self.unicode) == [
            String(repeating: "═", count: 50), "  🔐  Allow agents to control which phone or tablet", String(repeating: "═", count: 50), "",
        ])
        let coloured = TerminalUI.banner("Save the unlock code for Test Pixel", mark: .lock, width: 20, style: TerminalStyle(colours: true))
        #expect(coloured[0] == "\u{1B}[36m" + String(repeating: "═", count: 20) + "\u{1B}[0m")
        #expect(coloured[1] == "\u{1B}[1m  🔐  Save the unlock code for Test Pixel\u{1B}[0m")
    }

    @Test("the question carries its dim step and controls on the same line, and drops the controls to the next only when both would pass the width")
    func questionLine() {
        #expect(TerminalUI.question("Which phone or tablet?", step: "1/4", controls: .init(rescan: true), width: 72, style: Self.unicode) == ["1/4 Which phone or tablet? (↑↓, Enter, R rescan, Q quit)"])
        #expect(TerminalUI.question("Which phone or tablet?", controls: .init(choosing: false, rescan: true), width: 72, style: Self.unicode) == ["Which phone or tablet? (R rescan, Q quit)"])
        #expect(TerminalUI.question("Allow another?", controls: .init(quit: "done"), width: 72, style: Self.unicode) == ["Allow another? (↑↓, Enter, Q done)"])
        #expect(TerminalUI.question("Which phone or tablet?", step: "1/4", controls: .init(rescan: true), width: 40, style: Self.unicode) == ["1/4 Which phone or tablet?", "(↑↓, Enter, R rescan, Q quit)"])
        let coloured = TerminalUI.question("Which app?", step: "3/4", controls: .init(), width: 72, style: TerminalStyle(colours: true))
        #expect(coloured == ["\u{1B}[2m3/4\u{1B}[0m \u{1B}[1mWhich app?\u{1B}[0m \u{1B}[2m(↑↓, Enter, Q quit)\u{1B}[0m"])
    }

    @Test("rows lead with an emoji and two spaces, the recommended one carries a magenta badge, and only the cursor row is green")
    func recommendedRow() {
        let rows = AllowScreenRows.expiry
        let plain = TerminalUI.rows(rows, selected: 1, style: Self.unicode)
        #expect(plain == ["    ⏳  2 hours", "  ▸ ⏳  12 hours (Recommended)", "    📌  Until removed"])
        let coloured = TerminalUI.rows(rows, selected: 1, style: TerminalStyle(colours: true))
        #expect(coloured[1] == "  \u{1B}[32m▸ ⏳  12 hours\u{1B}[0m \u{1B}[35m(Recommended)\u{1B}[0m")
        #expect(!coloured[0].contains("\u{1B}[32m"))
    }

    @Test("a disabled row is drawn dim in the list, the cursor skips it, and its number chooses nothing")
    func disabledRows() {
        var menu = ChoiceMenu(count: 3, selected: 1, disabled: [1])
        #expect(menu.selected == 2)
        #expect(menu.apply(.down) == .moving)
        #expect(menu.selected == 0)
        #expect(menu.apply(.down) == .moving)
        #expect(menu.selected == 2)
        #expect(menu.apply(.up) == .moving)
        #expect(menu.selected == 0)
        #expect(menu.apply(.text(Array("2".utf8))) == .moving)
        #expect(menu.apply(.enter) == .chosen(0))

        var none = ChoiceMenu(count: 1, disabled: [0], refreshable: true)
        #expect(none.selected == nil)
        #expect(none.apply(.enter) == .moving)
        #expect(none.apply(.text(Array("r".utf8))) == .refresh)
        #expect(none.apply(.text(Array("q".utf8))) == .cancelled)
    }

    @Test("Enter collapses the menu to a one-line reminder: the erase climbs over every row it drew")
    func collapse() throws {
        let terminal = try PseudoTerminal()
        terminal.type("\u{1B}[B\r")
        let index = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, keeps: true) { prompt in
            try prompt.choose("Pick one", rows: [MenuRow(["First"]), MenuRow(["Second"])])
        }
        let output = terminal.finish()
        #expect(index == 1)
        let style = TerminalStyle.detect(isTerminal: true)
        let collapsed = try #require(output.range(of: "\u{1B}[3A\r\u{1B}[J", options: .backwards))
        let after = String(output[collapsed.upperBound...]).replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        #expect(after.trimmingCharacters(in: .whitespacesAndNewlines) == "\(style.picked) Second")
    }

    @Test("a menu longer than its window scrolls to keep the cursor in view and counts the rows it hides")
    func menuWindow() {
        let rows = (1...20).map { MenuRow(["Row \($0)"]) }
        let menu = TerminalUI.menu(nil, rows: rows, selected: 10, controls: .init(), window: 5, style: Self.unicode).split(separator: "\n").map(String.init)
        #expect(menu == ["    8 more above", "    Row 9", "    Row 10", "  ▸ Row 11", "    Row 12", "    Row 13", "    7 more below"])
        #expect(TerminalUI.menu(nil, rows: Array(rows.prefix(4)), selected: 0, controls: .init(), window: 5, style: Self.unicode).split(separator: "\n").count == 4)
    }

    @Test("a tick menu toggles with Space, takes every ticked row on Enter, and ignores Enter with none ticked")
    func checkMenu() {
        var menu = CheckMenu(count: 3, ticked: [0, 1, 2])
        #expect(menu.apply(.text([UInt8(ascii: " ")])) == .moving)
        #expect(menu.apply(.down) == .moving)
        #expect(menu.apply(.down) == .moving)
        #expect(menu.apply(.text([UInt8(ascii: " ")])) == .moving)
        #expect(menu.apply(.enter) == .chosen([1]))
        var empty = CheckMenu(count: 1, ticked: [0])
        _ = empty.apply(.text([UInt8(ascii: " ")]))
        #expect(empty.apply(.enter) == .moving)
        #expect(empty.apply(.text([UInt8(ascii: "q")])) == .cancelled)
        #expect(TerminalUI.Controls(ticking: true).text(style: Self.unicode) == "(↑↓, Space, Enter, Q quit)")
    }

    static func summary(_ id: String, _ kind: DeviceKind, state: String = "Booted", platform: DevicePlatform = .ios, name: String, os: String? = nil, avd: String? = nil) -> DeviceSummary {
        var row = DeviceSummary(id: id, platform: platform, state: state, name: name, osVersion: os, deviceType: nil, kind: kind, connection: kind == .physical ? "usb" : nil)
        row.avd = avd
        return row
    }

    @Test("the boot picker offers simulators and AVDs, running ones first and marked, never a physical device")
    func bootPicker() {
        let rows = [
            Self.summary("ABCDEF00-0000-4000-8000-000000000001", .simulator, state: "Shutdown", name: "Old Sim", os: "iOS 18.5"),
            Self.summary("ABCDEF00-0000-4000-8000-000000000002", .simulator, state: "Shutdown", name: "New Sim", os: "iOS 27.1"),
            Self.summary("Test_AVD", .avd, state: "Shutdown", platform: .android, name: "Test_AVD", os: "Android 16", avd: "Test_AVD"),
            Self.summary("emulator-5554", .emulator, platform: .android, name: "Running_AVD", os: "Android 16", avd: "Running_AVD"),
            Self.summary("Running_AVD", .avd, state: "Shutdown", platform: .android, name: "Running_AVD", avd: "Running_AVD"),
            Self.summary(PolicyFixtures.phone, .physical, name: "Test iPhone"),
        ]
        let offered = DevicePickerScreen.bootable(rows)
        #expect(offered.map(\.name) == ["Running_AVD", "Test_AVD", "New Sim", "Old Sim"])
        #expect(DevicePickerScreen.bootRow(offered[0]).columns == ["Running_AVD", DevicePickerScreen.running])
        #expect(offered.map(DevicePickerScreen.bootName) == ["Running_AVD", "Test_AVD", "ABCDEF00-0000-4000-8000-000000000002", "ABCDEF00-0000-4000-8000-000000000001"])
        #expect(DevicePickerScreen.runningDevices(rows).map(\.id) == ["emulator-5554"])
    }
}

private enum AllowScreenRows {
    static let expiry = [MenuRow(.time, ["2 hours"]), MenuRow(.time, ["12 hours"], recommended: true), MenuRow(.keep, ["Until removed"])]
}
