import Foundation
@testable import Offsider
import OffsiderCore
import Testing

/// What an agent such as Claude Code reads: only the information, one line per note, nothing a terminal draws.
@Suite("Agent output")
struct AgentOutputTests {
    /// An agent's streams that claim a colour terminal `columns` wide, which the agent renderer must ignore.
    static func agentConsole(_ capture: ConsoleCapture, columns: Int = 80) -> Console {
        let channel = Console.Channel(profile: .agent, canvas: Canvas(columns: columns, style: TerminalStyle(colours: true)), isTerminal: true, animates: true)
        return capture.console(out: channel, err: channel)
    }

    static func render(_ page: Page, columns: Int = 80) -> ConsoleCapture {
        let capture = ConsoleCapture()
        agentConsole(capture, columns: columns).show(page)
        return capture
    }

    @Test("no escape, carriage return or export reaches an agent", arguments: ScreenFixtures.pages.map(\.name))
    func plain(name: String) throws {
        let page = try #require(ScreenFixtures.pages.first { $0.name == name }?.page)
        let capture = Self.render(page)
        let text = capture.out + capture.err
        #expect(!text.contains("\u{1B}") && !text.contains("\r"))
        #expect(!text.contains("export "))
    }

    @Test("every stderr line starts Warning, Note, Error or Try, and none repeats", arguments: ScreenFixtures.pages.map(\.name))
    func prefixed(name: String) throws {
        let page = try #require(ScreenFixtures.pages.first { $0.name == name }?.page)
        let lines = Self.render(page).err.split(separator: "\n").map(String.init)
        #expect(lines.allSatisfy { line in ["Warning: ", "Note: ", "Error: ", "Try: "].contains { line.hasPrefix($0) } })
        #expect(Set(lines).count == lines.count)
    }

    @Test("nothing wraps: a 20-column terminal reads exactly as an 80-column one", arguments: ScreenFixtures.pages.map(\.name))
    func noWidth(name: String) throws {
        let page = try #require(ScreenFixtures.pages.first { $0.name == name }?.page)
        let narrow = Self.render(page, columns: 20)
        let wide = Self.render(page, columns: 80)
        #expect(narrow.out == wide.out && narrow.err == wide.err)
    }

    @Test("an error is one Error line and one Try line")
    func errorLines() {
        let text = ErrorReporter.errorText(ScreenGoldenTests.message) + ErrorReporter.hintText("offsider devices --platform android", message: ScreenGoldenTests.message, style: .plain)
        #expect(text.split(separator: "\n").map { String($0.prefix(5)) } == ["Error", "Try: "])
    }

    @Test("a pause shows nothing to an agent: no spinner from progress or from TerminalSpinner")
    func silentProgress() async throws {
        let capture = ConsoleCapture()
        let console = Self.agentConsole(capture)
        let value = try await console.progress("Looking for devices") {
            try await Task.sleep(for: .milliseconds(300))
            return 7
        }
        #expect(value == 7)
        try await Console.$current.withValue(console) {
            try await TerminalSpinner.run("Stopping the warm helper") { try await Task.sleep(for: .milliseconds(300)) }
        }
        #expect(capture.all.isEmpty)
    }

    @Test("the same warning from two backends reaches an agent once")
    func coalesced() {
        let capture = ConsoleCapture()
        let console = Self.agentConsole(capture)
        console.notice(.warning("adb restarted", agent: "The adb server restarted."))
        console.notice(.warning("adb restarted", agent: "The adb server restarted."))
        console.notice(.next("export OFFSIDER_DEVICE=emulator-5554"))
        #expect(capture.err == "Warning: The adb server restarted.\n")
    }
}
