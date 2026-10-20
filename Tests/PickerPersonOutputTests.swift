import Darwin
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

@Suite("Picker person output", .serialized)
struct PickerPersonOutputTests {
    static let noColour = TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": "1"])
    static let unicode = TerminalStyle(colours: false)

    static func simulator(_ number: Int, _ name: String, state: String = "Shutdown", os: String) -> DeviceSummary {
        DeviceSummary(id: String(format: "00000000-0000-4000-8000-%012d", number), platform: .ios, state: state, name: name, osVersion: os, deviceType: name, kind: .simulator)
    }

    static func avd(_ name: String, state: String = "Shutdown", id: String? = nil) -> DeviceSummary {
        DeviceSummary(id: id ?? name, platform: .android, state: state, name: name, osVersion: "Android 16", deviceType: name.lowercased(), kind: id == nil ? .avd : .emulator, avd: name)
    }

    /// Twelve simulators and AVDs, a running iPhone first, so a pick that ignored the filter would take the wrong row.
    static let devices = [
        simulator(1, "iPhone 17 Pro", state: "Booted", os: "iOS 27.0"), simulator(2, "iPhone 17", os: "iOS 27.0"), simulator(3, "iPhone Air", os: "iOS 27.0"),
        simulator(4, "iPad Pro 13-inch (M5)", os: "iOS 27.0"), simulator(5, "iPad Air 11-inch (M3)", os: "iOS 26.0"), simulator(6, "iPhone 16", os: "iOS 26.0"),
        simulator(7, "iPhone 16e", os: "iOS 26.0"), simulator(8, "iPhone 15", os: "iOS 18.5"), simulator(9, "iPad mini (A17 Pro)", os: "iOS 18.5"),
        avd("Pixel_9"), avd("Pixel_Tablet"), avd("Medium_Phone", state: "Booted", id: "emulator-5554"),
    ]

    static var rows: [MenuRow] { DevicePickerScreen.bootable(devices).map(DevicePickerScreen.bootRow) }

    static func boot(_ menu: ChoiceMenu, columns: Int, style: TerminalStyle = noColour) -> String {
        let filtering = menu.query != nil
        return TerminalUI.menu(
            DevicePickerScreen.bootQuestion, rows: rows, selected: menu.selected, controls: .init(rescan: true, filter: menu.offersFilter, filtering: filtering),
            width: PromptScreen.width(columns: columns), window: 16, style: style, query: menu.query, shown: filtering ? menu.shown : nil
        )
    }

    static func bootMenu(typing keys: String = "") -> ChoiceMenu {
        var menu = ChoiceMenu(count: rows.count, refreshable: true, search: rows.map { $0.columns.joined(separator: " ") })
        menu.window = 16
        if !keys.isEmpty { _ = menu.apply(.text(Array(keys.utf8))) }
        return menu
    }

    static let fullList = """
          > [iPhone]   iPhone 17 Pro          running
            [Android]  Medium_Phone           running
            [Android]  Pixel_9                Android 16
            [Android]  Pixel_Tablet           Android 16
            [iPhone]   iPhone 17              iOS 27.0
            [iPhone]   iPhone Air             iOS 27.0
            [iPad]     iPad Pro 13-inch (M5)  iOS 27.0
            [iPad]     iPad Air 11-inch (M3)  iOS 26.0
            [iPhone]   iPhone 16              iOS 26.0
            [iPhone]   iPhone 16e             iOS 26.0
            [iPhone]   iPhone 15              iOS 18.5
            [iPad]     iPad mini (A17 Pro)    iOS 18.5
        """

    @Test("with NO_COLOR at 80 columns the boot picker offers / on its long list, controls beside the question")
    func bootPickerAt80() {
        #expect(Self.boot(Self.bootMenu(), columns: 80) == "Which one to boot? (up/down, Enter, / filter, R rescan, Q quit)\n\n" + Self.fullList)
    }

    @Test("at 50 columns the controls drop under the question and the rows stay whole")
    func bootPickerAt50() {
        #expect(Self.boot(Self.bootMenu(), columns: 50) == "Which one to boot?\n(up/down, Enter, / filter, R rescan, Q quit)\n\n" + Self.fullList)
    }

    @Test("filtering shows the query under the question, only the matches, columns still aligned, and Esc in the controls")
    func filterView() {
        let expected = """
            Which one to boot? (up/down, Enter, Esc clear)
              / pix_

              > [Android]  Pixel_9                Android 16
                [Android]  Pixel_Tablet           Android 16
            """
        #expect(Self.boot(Self.bootMenu(typing: "/pix"), columns: 80) == expected)
        #expect(Self.boot(Self.bootMenu(typing: "/pix"), columns: 50) == expected)
        #expect(Self.boot(Self.bootMenu(typing: "/ipad"), columns: 80, style: Self.unicode) == """
            Which one to boot? (↑↓, Enter, Esc clear)
              / ipad▏

              ▸ 📲  iPad Pro 13-inch (M5)  iOS 27.0
                📲  iPad Air 11-inch (M3)  iOS 26.0
                📲  iPad mini (A17 Pro)    iOS 18.5
            """)
    }

    @Test("no match leaves one dim No match row under the query")
    func noMatchView() {
        #expect(Self.boot(Self.bootMenu(typing: "/pixx"), columns: 80) == """
            Which one to boot? (up/down, Enter, Esc clear)
              / pixx_

                No match
            """)
        let coloured = TerminalUI.menu(nil, rows: Self.rows, selected: nil, controls: .init(filtering: true), style: TerminalStyle(colours: true), query: "zz", shown: [])
        #expect(coloured.hasSuffix("    \u{1B}[2m\(TerminalUI.noMatch)\u{1B}[0m"))
    }

    @Test("the controls name / only where it filters, keep today's text everywhere else, and shrink to Esc while filtering")
    func controlsText() {
        #expect(TerminalUI.Controls(rescan: true, filter: true).text(style: Self.unicode) == "(↑↓, Enter, / filter, R rescan, Q quit)")
        #expect(TerminalUI.Controls(filter: true).text(style: Self.unicode) == "(↑↓, Enter, / filter, Q quit)")
        #expect(TerminalUI.Controls(choosing: false, rescan: true, filter: true).text(style: Self.unicode) == "(R rescan, Q quit)")
        #expect(TerminalUI.Controls(rescan: true, filtering: true).text(style: Self.unicode) == "(↑↓, Enter, Esc clear)")
        #expect(TerminalUI.Controls(rescan: true).text(style: Self.unicode) == "(↑↓, Enter, R rescan, Q quit)")
        #expect(TerminalUI.Controls(rescan: true, filter: true).text(style: Self.noColour) == "(up/down, Enter, / filter, R rescan, Q quit)")
    }

    @Test("the filter line shows a typed control or bidi character as ?, never as itself")
    func filterLineIsSafe() {
        #expect(TerminalUI.filterLine("pi\u{202E}x", style: Self.unicode) == "  / pi?x▏")
        #expect(TerminalUI.filterLine("", style: Self.noColour) == "  / _")
    }

    @Test("a long filtered list scrolls within the window around the cursor")
    func filteredWindow() {
        let rows = (1...30).map { MenuRow(["Sim \($0)", "iOS 18.5"]) }
        var menu = ChoiceMenu(count: rows.count, search: rows.map { $0.columns.joined(separator: " ") })
        _ = menu.apply(.text(Array("/sim 2".utf8)))
        for _ in 0..<6 { _ = menu.apply(.down) }
        let drawn = TerminalUI.menu(nil, rows: rows, selected: menu.selected, controls: .init(filtering: true), window: 5, style: Self.unicode, query: menu.query, shown: menu.shown)
        #expect(drawn.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            "  / sim 2▏", "", "    4 more above", "    Sim 22  iOS 18.5", "    Sim 23  iOS 18.5", "  ▸ Sim 24  iOS 18.5", "    Sim 25  iOS 18.5", "    Sim 26  iOS 18.5", "    3 more below",
        ])
    }

    @Test("the boot picker filters its twelve rows with /pix and returns the matching AVD, not the first row")
    @MainActor
    func bootPickerFilters() async throws {
        let terminal = try PseudoTerminal()
        terminal.type("/pix\r")
        let picked = try await DevicePicker.pickBootable(descriptor: terminal.secondary) { Self.devices }
        _ = terminal.finish()
        #expect(picked.name == "Pixel_9")
        #expect(DevicePickerScreen.bootName(picked) == "Pixel_9")

        let tablet = try PseudoTerminal()
        tablet.type("/PIXEL tab\r")
        #expect(try await DevicePicker.pickBootable(descriptor: tablet.secondary) { Self.devices }.name == "Pixel_Tablet")
        _ = tablet.finish()
    }

    @Test("a person sees / filter in the controls, then the query and Esc clear as they type")
    @MainActor
    func bootPickerDrawsFilter() async throws {
        let terminal = try PseudoTerminal()
        let style = TerminalStyle.detect(isTerminal: true)
        let shown = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            shown.append(terminal.wait(forOutput: TerminalUI.Controls(rescan: true, filter: true).text(style: style)))
            terminal.send("/tab")
            shown.append(terminal.wait(forOutput: TerminalUI.filterLine("tab", style: style)))
            terminal.send("\r")
        }
        let picked = try await DevicePicker.pickBootable(descriptor: terminal.secondary) { Self.devices }
        let transcript = terminal.finish().replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        #expect(picked.name == "Pixel_Tablet")
        #expect(shown.values == [true, true])
        #expect(transcript.contains("\(DevicePickerScreen.bootQuestion) \(TerminalUI.Controls(filtering: true).text(style: style))"))
    }

    @Test("a short picker keeps today's controls and takes / as nothing")
    @MainActor
    func shortPickerUnchanged() async throws {
        let terminal = try PseudoTerminal()
        terminal.type("/\u{1B}[B\r")
        let picked = try await DevicePicker.pickBootable(descriptor: terminal.secondary) { Array(Self.devices.suffix(3)) }
        let transcript = terminal.finish().replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        #expect(picked.name == "Pixel_9")
        #expect(transcript.contains("\(DevicePickerScreen.bootQuestion) \(TerminalUI.Controls(rescan: true).text(style: .detect(isTerminal: true)))"))
    }

    @Test("an agent never gets a picker, even with a terminal on every stream")
    func agentGetsNoPicker() {
        #expect(DevicePicker.prompts(terminals: true, profile: .person))
        #expect(!DevicePicker.prompts(terminals: true, profile: .agent))
        #expect(!DevicePicker.prompts(terminals: false, profile: .person))
        #expect(!DevicePicker.offers(arguments: ["tap", "-x", "1", "-y", "1"], terminal: DevicePicker.prompts(terminals: true, profile: .agent)))
    }

    @Test("under the agent profile the live check offers no picker", .agentOutput)
    func agentProfileOffersNone() {
        #expect(!DevicePicker.prompts(terminals: true))
        #expect(!DevicePicker.offers(arguments: ["boot"], terminal: DevicePicker.terminal()))
    }

    @Test("a picker no one answers leaves its one dim line on stderr through the console")
    @MainActor
    func unansweredGoesThroughConsole() async throws {
        let capture = ConsoleCapture()
        let terminal = try AccessTerminal()
        let missing = CLIError(errorDescription: DeviceDefault.missingMessage, reason: .usage)
        await Console.$current.withValue(capture.console(out: .person(), err: .person())) {
            _ = try? await DevicePicker.orUnanswered(missing, boot: true) {
                try await DevicePicker.pickBootable(descriptor: terminal.secondary, idle: 0.2) { Self.devices }
            }
        }
        _ = terminal.finish()
        #expect(capture.out.isEmpty)
        #expect(capture.err == DevicePickerScreen.unanswered(within: PromptTimedOut.duration(0.2), boot: true) + "\n")
    }
}

/// Values a sender thread records for the test to check.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []

    func append(_ value: Bool) {
        lock.withLock { stored.append(value) }
    }

    var values: [Bool] { lock.withLock { stored } }
}
