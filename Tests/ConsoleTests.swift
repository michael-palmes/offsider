import Foundation
import OffsiderCore
import Testing

@Suite("Console")
struct ConsoleTests {
    static let warning = Notice.warning("adb is old", agent: "adb 34.0.0 is older than 35.0.0.", try: "sdkmanager platform-tools")

    @Test("a notice shows once however often it is raised, alone or on a page")
    func dedupe() {
        let capture = ConsoleCapture()
        let console = capture.console(out: .agent, err: .agent)
        console.notice(Self.warning)
        console.notice(Self.warning)
        console.show(Page([.prose("body")], notices: [Self.warning, .note("one more")]))
        #expect(capture.err == "Warning: adb 34.0.0 is older than 35.0.0.\nTry: sdkmanager platform-tools\nNote: one more\n")
        #expect(capture.out == "body\n")
    }

    @Test("an agent reads one line once, even when two notices word it differently for a person")
    func agentDedupeByLine() {
        let capture = ConsoleCapture()
        let console = capture.console(out: .agent, err: .agent)
        console.notice(.warning("adb is old", agent: "adb 34.0.0 is older than 35.0.0."))
        console.show(Page(notices: [.warning("Update adb", agent: "adb 34.0.0 is older than 35.0.0.")]))
        #expect(capture.err == "Warning: adb 34.0.0 is older than 35.0.0.\n")
    }

    @Test("the body goes to stdout before its notices go to stderr")
    func ordering() {
        let capture = ConsoleCapture()
        capture.console(out: .person(), err: .person()).show(ScreenFixtures.page(ScreenFixtures.mixed))
        let streams = capture.all.map(\.stream)
        #expect(streams == [.out, .err])
        #expect(capture.err.hasPrefix("\n⚠️  iPhones and iPads skipped"))
    }

    @Test("styling follows each stream: a person's terminal is styled, a pipe or an agent is not, and only a person's stderr spins")
    func perStream() {
        let environment = ["LANG": "en_AU.UTF-8"]
        let terminal = Console.channel(.out, profile: .person, isTerminal: true, environment: environment, measured: 120)
        #expect(terminal.canvas.style.colours && terminal.canvas.columns == 120 && !terminal.animates)
        let piped = Console.channel(.err, profile: .person, isTerminal: false, environment: environment, measured: nil)
        #expect(!piped.canvas.style.colours && !piped.animates && piped.canvas.columns == 80)
        let agent = Console.channel(.err, profile: .agent, isTerminal: true, environment: environment, measured: 120)
        #expect(!agent.canvas.style.colours && !agent.animates)
        #expect(Console.channel(.err, profile: .person, isTerminal: true, environment: environment, measured: 90).animates)
        #expect(!Console.channel(.err, profile: .person, isTerminal: true, environment: ["TERM": "dumb"], measured: 90).animates)
        #expect(Console.channel(.out, profile: .person, isTerminal: true, environment: ["COLUMNS": "44"], measured: 90).canvas.columns == 44)

        let capture = ConsoleCapture()
        let styled = Console.Channel.person(style: TerminalStyle(colours: true))
        capture.console(out: styled, err: piped).show(ScreenFixtures.page(ScreenFixtures.mixed))
        #expect(capture.out.contains("\u{1B}["))
        #expect(!capture.err.contains("\u{1B}") && capture.err.contains("Try  sudo xcode-select"))
    }

    @Test("a next step is a person's only")
    func nextIsPersonOnly() {
        let agent = ConsoleCapture()
        agent.console(out: .agent, err: .agent).notice(.next("offsider doctor"))
        #expect(agent.all.isEmpty)
        let person = ConsoleCapture()
        person.console(out: .person(), err: .person()).notice(.next("offsider doctor"))
        #expect(person.err == "Next  offsider doctor\n")
    }

    @Test("a person sees five notices of a kind, then how many more there were")
    func fivePerKind() {
        let warnings = (1...7).map { Notice.warning("warning \($0)") }
        let page = ConsoleCapture()
        page.console(out: .person(), err: .person()).show(Page(notices: warnings + [.note("a note")]))
        #expect(page.err.split(separator: "\n").map(String.init) == (1...5).map { "⚠️  warning \($0)" } + ["    …and 2 more", "💡  a note"])

        let single = ConsoleCapture()
        let console = single.console(out: .person(), err: .person())
        warnings.forEach(console.notice)
        #expect(single.err.split(separator: "\n").map(String.init) == (1...5).map { "⚠️  warning \($0)" } + ["    …and more"])

        let agent = ConsoleCapture()
        agent.console(out: .agent, err: .agent).show(Page(notices: warnings))
        #expect(agent.err.split(separator: "\n").count == 7)
    }

    @Test("a notice raised under a spinner first clears the spinner's line, and the spinner is gone at the end")
    func clearsSpinner() async throws {
        let capture = ConsoleCapture()
        let console = capture.console(out: .person(), err: .person())
        func drawn(_ label: String) async throws {
            for _ in 0..<100 where !capture.all.contains(where: { $0.text.contains(label) }) {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await console.progress("Looking for devices") {
            try await drawn("Looking for devices")
            console.relabel("Still looking")
            console.notice(.warning("adb is old"))
            try await drawn("Still looking")
        }
        let writes = capture.all
        let notice = try #require(writes.firstIndex { $0.text.contains("adb is old") })
        #expect(notice > 1)
        let clear = writes[notice - 1].text
        #expect(clear.hasPrefix("\r") && clear.hasSuffix("\r") && clear.dropFirst().dropLast().allSatisfy { $0 == " " })
        #expect(writes.contains { $0.text.contains("Looking for devices") })
        #expect(writes.dropFirst(notice).contains { $0.text.contains("Still looking") })
        let last = try #require(writes.last?.text)
        #expect(last.hasPrefix("\r") && last.hasSuffix("\r") && last.dropFirst().dropLast().allSatisfy { $0 == " " })
        #expect(!writes.contains { $0.text.contains("\u{1B}") })
    }

    @Test("a quick pause draws no spinner at all")
    func quickPause() async {
        let capture = ConsoleCapture()
        await capture.console(out: .person(), err: .person()).progress("Looking") { }
        #expect(capture.all.isEmpty)
    }
}
