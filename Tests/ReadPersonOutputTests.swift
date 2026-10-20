import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// What a person reads from wait, assert, screenshot, displays, logs, describe-ui and batch, and what an agent still reads byte for byte.
@Suite("Read person output")
@MainActor
struct ReadPersonOutputTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let ascii = TerminalStyle(colours: false, ascii: true)
    static let home = "/Users/me"

    static func person(_ columns: Int = 80, style: TerminalStyle = .plain) -> (ConsoleCapture, Console) {
        let capture = ConsoleCapture()
        return (capture, capture.console(out: .person(columns: columns, style: style), err: .person(columns: columns, style: style)))
    }

    /// An agent whose streams claim a wide colour terminal, which must change nothing.
    static func agent() -> (ConsoleCapture, Console) {
        let capture = ConsoleCapture()
        let channel = Console.Channel(profile: .agent, canvas: Canvas(columns: 200, style: TerminalStyle(colours: true)), isTerminal: true, animates: true)
        return (capture, capture.console(out: channel, err: channel))
    }

    static func wait(_ arguments: [String]) throws -> Wait {
        try Wait.parse(arguments + ["--device", device.rawValue, "--poll-interval", "0.05"])
    }

    static func assert(_ arguments: [String]) throws -> Assert {
        try Assert.parse(arguments + ["--device", device.rawValue])
    }

    static let met = WaitOutcome(met: true, elapsed: 1.23, reason: "found")

    static var missed: WaitOutcome {
        var outcome = WaitOutcome(met: false, elapsed: 10, reason: "off screen at (20, 10700) 350x44")
        outcome.nearMiss = WaitNearMiss(summary: "--id 'save-button' at (20, 640)", candidates: [])
        return outcome
    }

    /// Reports `outcome` as `wait` would, returning the exit code it threw (0 when met).
    @discardableResult
    static func report(_ wait: Wait, _ outcome: WaitOutcome, json: Bool = false, console: Console) throws -> Int32 {
        do {
            try Wait.report(outcome, success: wait.successLine(outcome), failure: wait.failureLine(outcome), json: json, person: wait.personOutcome, console: console)
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }

    // MARK: Wait and assert

    @Test("an agent reads wait's ✓ line on stdout and its ✗ line on stderr byte for byte")
    func waitAgentLines() throws {
        let wait = try Self.wait(["--id", "save"])
        let (met, metConsole) = Self.agent()
        #expect(try Self.report(wait, Self.met, console: metConsole) == 0)
        #expect(met.out == "✓ --id 'save' is on screen after 1.2 s\n")
        #expect(met.err.isEmpty)

        let (missed, missedConsole) = Self.agent()
        #expect(try Self.report(wait, Self.missed, console: missedConsole) == 5)
        #expect(missed.out.isEmpty)
        #expect(missed.err == "✗ Timed out after 10 s waiting for --id 'save' (last: off screen at (20, 10700) 350x44; nearest: --id 'save-button' at (20, 640)).\n")
    }

    @Test("a person reads a ✅ with the time on stdout, and a ❌ with the last reason and the nearest element on stderr")
    func waitPerson() throws {
        let wait = try Self.wait(["--id", "save"])
        let (met, metConsole) = Self.person()
        try Self.report(wait, Self.met, console: metConsole)
        #expect(met.out == "✅  --id 'save' is on screen  after 1.2 s\n")
        #expect(met.err.isEmpty)

        let (missed, missedConsole) = Self.person(50, style: Self.ascii)
        #expect(try Self.report(wait, Self.missed, console: missedConsole) == 5)
        #expect(missed.out.isEmpty)
        #expect(missed.err == """
        [x] Timed out after 10 s waiting for --id 'save'
            Last     off screen at (20, 10700) 350x44
            Nearest  --id 'save-button' at (20, 640)

        """)
    }

    @Test("--json keeps the JSON on stdout and the plain line on stderr, even at a person's terminal")
    func waitJSONStaysPlain() throws {
        let wait = try Self.wait(["--id", "save"])
        let (capture, console) = Self.person()
        try Self.report(wait, Self.met, json: true, console: console)
        #expect(capture.out.hasPrefix(#"{"#) && capture.out.hasSuffix("}\n"))
        #expect(capture.err == "✓ --id 'save' is on screen after 1.2 s\n")
    }

    @Test("a person's failure hides the text the agent's line hides")
    func waitPersonRedacts() throws {
        let card = "4111 1111 1111 1111"
        let wait = try Self.wait(["--id", "card", "--has-value", card])
        let outcome = WaitOutcome(met: false, elapsed: 10, reason: "has value '\(card)'")
        let (agent, agentConsole) = Self.agent()
        try Self.report(wait, outcome, console: agentConsole)
        let (person, personConsole) = Self.person()
        try Self.report(wait, outcome, console: personConsole)
        #expect(!agent.err.contains("4111") && agent.err.contains("[redacted card]"))
        #expect(!person.err.contains("4111"))
        #expect(person.err == """
        ❌  Timed out after 10 s waiting for --id 'card' with value '[redacted
            card]'
            Last     has value '[redacted card]'

        """)
    }

    @Test("a wait that matched on text describe-ui hides tells a person so under the receipt")
    func waitRedactionNote() async throws {
        let tree = FakeUI.tree(width: 393, height: 852, [FakeUI.node(.text, id: "otp", label: "Your code is 482913", frame: FakeUI.frame(20, 100, 350, 30))])
        let wait = try Self.wait(["--label-contains", "482913", "--timeout", "0"])
        let outcome = try await wait.evaluate(
            on: DeviceRouter.Route(backend: FakeDeviceBackend(trees: [tree]), device: Self.device), logger: OffsiderLogger(), clock: ScriptedClock().poll
        )
        let (capture, console) = Self.person()
        try Wait.report(outcome, success: wait.successLine(outcome), failure: wait.failureLine(outcome), json: false, checked: wait.selector, person: wait.personOutcome, console: console)
        #expect(capture.out.hasSuffix("\n    matched on the real text; describe-ui shows it redacted\n"))
    }

    @Test("--any names the selector that matched beside the time, and --seconds has nothing to add")
    func waitPersonParts() throws {
        let any = try Self.wait(["--any", "--label", "Done", "--label", "Retry"])
        let matched = WaitOutcome(met: true, elapsed: 0.4, reason: "found", matched: WaitMatch(by: "label", text: "Retry", position: 2, of: 2))
        #expect(any.successLine(matched) == "✓ --label 'Retry' is on screen after 0.4 s (2 of 2 selectors)")
        let receipt = any.personOutcome(matched, note: nil)
        #expect(receipt.headline == "--label 'Retry' is on screen" && receipt.aside == "after 0.4 s · 2 of 2 selectors" && receipt.details.isEmpty)

        let pause = try Self.wait(["--seconds", "2"])
        let waited = WaitOutcome(met: true, elapsed: 2, reason: "waited")
        #expect(pause.successLine(waited) == "✓ Waited 2 s")
        #expect(pause.personOutcome(waited, note: nil).headline == "Waited 2 s" && pause.personOutcome(waited, note: nil).details.isEmpty)
    }

    @Test("assert gives a person the state that held, or what was there instead")
    func assertPerson() throws {
        let assert = try Self.assert(["--id", "count", "--has-value", "3"])
        let (met, metConsole) = Self.person()
        try Wait.report(Self.met, success: assert.successLine(Self.met), failure: assert.failureLine(Self.met), json: false, person: assert.personOutcome, console: metConsole)
        #expect(met.out == "✅  --id 'count' is on screen with value '3'\n")

        let wrong = WaitOutcome(met: false, elapsed: 0, reason: "has value '2', expected '3'")
        let (missed, missedConsole) = Self.person()
        #expect(throws: ExitCode.self) {
            try Wait.report(wrong, success: assert.successLine(wrong), failure: assert.failureLine(wrong), json: false, person: assert.personOutcome, console: missedConsole)
        }
        #expect(missed.err == "❌  --id 'count' has value '2', expected '3'\n")

        let (agent, agentConsole) = Self.agent()
        #expect(throws: ExitCode.self) {
            try Wait.report(wrong, success: assert.successLine(wrong), failure: assert.failureLine(wrong), json: false, person: assert.personOutcome, console: agentConsole)
        }
        #expect(agent.err == "✗ Assertion failed: --id 'count' has value '2', expected '3'.\n")
    }

    // MARK: Screenshot

    static let shot = ScreenshotReport(
        path: "/Users/me/Desktop/shot.png", width: 1206, height: 2622, pixelsPerPoint: 3, region: nil, orientation: "portrait", upright: true, format: .png,
        maskedBy: [.secure: 1]
    )

    @Test("a screenshot is a ✅ receipt with the path under ~ for a person, and the bare path for an agent")
    func screenshotReceipt() {
        let page = ReadPersonView.screenshot(Self.shot, path: "/Users/me/Desktop/shot.png", home: Self.home)
        let (person, personConsole) = Self.person()
        personConsole.show(page)
        #expect(person.out == "✅  Screenshot saved\n    ~/Desktop/shot.png\n    1206 x 2622 px · 1 masked\n")
        let (agent, agentConsole) = Self.agent()
        agentConsole.show(page)
        #expect(agent.out == "/Users/me/Desktop/shot.png\n")
    }

    @Test("a compare reads ✅ or ❌ by --expect for a person, and the summary for an agent", arguments: [
        (ScreenCompare.Outcome.changed, ScreenCompare.Outcome.changed, true, "Changed from the baseline"),
        (.unchanged, .unchanged, true, "Matches the baseline"),
        (.changed, .unchanged, false, "Differs from the baseline"),
        (.unchanged, .changed, false, "No change from the baseline"),
    ])
    func comparison(outcome: ScreenCompare.Outcome, expected: ScreenCompare.Outcome, ok: Bool, headline: String) {
        let changed = outcome == .changed ? 37 : 0
        let result = ScreenCompare.Result(
            changedTiles: changed, comparedTiles: 512, changedFraction: Double(changed) / 512, outcome: outcome,
            pixels: .init(changedPixels: changed * 50, comparedPixels: 100_000, bounds: nil), expected: expected
        )
        var report = Self.shot
        report.comparison = result
        report.diffPath = "/Users/me/Desktop/diff.png"
        let page = ReadPersonView.comparison(report, result, home: Self.home)
        let (person, personConsole) = Self.person()
        personConsole.show(page)
        let lines = person.out.split(separator: "\n").map(String.init)
        #expect(lines.first == (ok ? "✅  " : "❌  ") + headline)
        #expect(lines.dropFirst().first == (changed > 0 ? "    37 of 512 tiles changed (7.2%) · 1850 pixels" : "    0 of 512 tiles changed · 0 pixels"))
        #expect(lines.suffix(2) == ["    Diff at ~/Desktop/diff.png", "    Saved to ~/Desktop/shot.png"])
        let (agent, agentConsole) = Self.agent()
        agentConsole.show(page)
        #expect(agent.out == result.summary + "\n")
    }

    @Test("a saved file is an agent's stderr line, nothing beside a person's receipt, and a note when stdout goes elsewhere")
    func savedLine() {
        let (agent, agentConsole) = Self.agent()
        ReadPersonView.saved("Screenshot saved to /Users/me/a.png (10 x 20 px)", person: "Screenshot saved to ~/a.png · 10 x 20 px", console: agentConsole)
        #expect(agent.err == "Screenshot saved to /Users/me/a.png (10 x 20 px)\n" && agent.out.isEmpty)

        let (person, personConsole) = Self.person()
        ReadPersonView.saved("Screenshot saved to /Users/me/a.png (10 x 20 px)", person: "Screenshot saved to ~/a.png · 10 x 20 px", console: personConsole)
        #expect(person.all.isEmpty)

        let piped = ConsoleCapture()
        let pipedConsole = piped.console(out: .agent, err: .person())
        ReadPersonView.saved("Screenshot saved to /Users/me/a.png (10 x 20 px)", person: "Screenshot saved to ~/a.png · 10 x 20 px", console: pipedConsole)
        #expect(piped.err == "📸  Screenshot saved to ~/a.png · 10 x 20 px\n" && piped.out.isEmpty)
    }

    @Test("~ stands for the home folder only at a folder boundary")
    func tilde() {
        #expect(TerminalText.homePath("/Users/me/Desktop/a.png", home: "/Users/me") == "~/Desktop/a.png")
        #expect(TerminalText.homePath("/Users/me", home: "/Users/me/") == "~")
        #expect(TerminalText.homePath("/var/meow/a.png", home: "/var/me") == "/var/meow/a.png")
        #expect(TerminalText.homePath("/tmp/a.png", home: "/") == "/tmp/a.png")
    }

    // MARK: Displays

    @Test("displays shows a person a header with the posture and a row per display, and an agent the table as it was")
    func displays() {
        let page = DisplayReport.page(DisplayReportTests.folded, platform: .ios)
        let (person, personConsole) = Self.person()
        personConsole.show(page)
        #expect(person.out == """
        📱  Displays                  posture closed
        ────────────────────────────────────────────

          ● cover active  466 x 678 pt  3x  0°  id 1
          ○ inner         669 x 951 pt  3x      id 3

        """)
        let (agent, agentConsole) = Self.agent()
        agentConsole.show(page)
        #expect(agent.out == DisplayReport.table(DisplayReportTests.folded, platform: .ios) + "\n")
    }

    @Test("a narrow terminal drops the platform id, then the rotation and scale, and no row passes the edge", arguments: [32, 36, 40, 45, 80])
    func displaysNarrow(columns: Int) {
        let (person, console) = Self.person(columns)
        console.show(DisplayReport.page(DisplayReportTests.folded, platform: .ios))
        let lines = person.out.split(separator: "\n").map(String.init)
        #expect(lines.allSatisfy { TerminalText.width($0) <= columns - 1 })
        #expect(lines.contains { $0.contains("cover") && $0.contains("466 x 678 pt") })
        #expect(lines.contains { $0.contains("id 1") } == (columns >= 45))
    }

    // MARK: Logs

    @Test("an agent reads each log note as it always has; a person reads a warning or a note, the common ones short")
    func logNotes() {
        let retention = "Warning: the oldest Info or Debug entry is from 03:17:30.000Z, 50 s after the window starts, while Default and Error entries go back further: iOS keeps Info and Debug entries only briefly. Read sooner after the action, or collect live with --duration or --follow."
        let notes = [Logs.wholeLogNote, "Following logs on emulator-5554; press Ctrl+C to stop.", retention, LogClock.note(1800, device: "emulator-5554")]
        let (agent, agentConsole) = Self.agent()
        Console.$current.withValue(agentConsole) { notes.forEach(Logs.printNote) }
        #expect(agent.err == notes.map { $0 + "\n" }.joined())

        let (person, personConsole) = Self.person()
        Console.$current.withValue(personConsole) { notes.forEach(Logs.printNote) }
        #expect(person.err == """
        📜  Reading every app's log; --app, --rn or --process reads one
        📜  Following logs on emulator-5554 · Ctrl+C stops
        ⚠️  The oldest Info or Debug entry is from 03:17:30.000Z, 50 s after the
            window starts, while Default and Error entries go back further: iOS
            keeps Info and Debug entries only briefly. Read sooner after the
            action, or collect live with --duration or --follow.
        💡  emulator-5554's clock is 1800 s ahead of this Mac's. Log times are
            the device's own; --last and --since were counted back from its
            clock.

        """)
    }

    @Test("log lines reach stdout one at a time, unchanged")
    func logLines() {
        let (agent, agentConsole) = Self.agent()
        Console.$current.withValue(agentConsole) {
            Logs.printLine("10:00:00.000+10:30 I app: first")
            Logs.printLine("10:00:01.000+10:30 I app: second")
        }
        #expect(agent.all.map(\.text) == ["10:00:00.000+10:30 I app: first\n", "10:00:01.000+10:30 I app: second\n"])
    }

    // MARK: describe-ui notes

    @Test("describe-ui's notes read as they did for an agent, and in a few words for a person")
    func describeNotes() {
        let truncation = UITreeTruncation(depth: true, nodes: true)
        let app = SimLaunchctl.App(bundleID: "com.example.playground", pid: 4242)
        let udid = "00000000-0000-4000-8000-000000000001"
        let empty = AccessibilityFetcher.emptyTreeNotice(app, udid: udid)
        #expect(AgentRenderer.notice(truncation.notice) == truncation.note + "\n")
        #expect(AgentRenderer.notice(empty) == "Warning: \(DoctorRules.emptyTreeDetail(app)). \(DoctorRules.emptyTreeHint(app, udid: udid))\n")

        let (person, console) = Self.person()
        console.notice(truncation.notice)
        console.notice(empty)
        #expect(person.err == """
        💡  Tree cut at 64 levels and 50,000 elements; some elements are not
            listed
        ⚠️  com.example.playground is running but its accessibility tree is
            empty; relaunch it, or reboot the simulator if that fails
            Try  xcrun simctl terminate \(udid) com.example.playground && xcrun simctl launch \(udid) com.example.playground

        """)
    }

    // MARK: Batch

    static let screen = UIScreenInfo(width: 402, height: 874, scale: 1, rotation: .portrait)
    static let closed = FakeUI.tree([
        FakeUI.node(.button, id: "open", label: "Open", frame: FakeUI.frame(20, 100, 350, 44)),
        FakeUI.node(.text, id: "state", label: "State", value: "Closed", frame: FakeUI.frame(20, 200, 200, 30)),
    ])

    final class Streams {
        var out = ""
        var err = ""
    }

    /// Runs `steps` on a fake device through `output`, returning the exit code the batch ends with.
    static func batch(_ steps: [String], output: BatchOutput, continueOnError: Bool = false) async throws -> Int32 {
        let backend = FakeDeviceBackend(trees: [closed], screen: screen)
        let context = BatchContext(backend: backend, device: device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, noSettle: true)
        do {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Batch.runSteps(steps, context: context, session: backend.session, continueOnError: continueOnError, output: output, logger: OffsiderLogger())
            }
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        } catch let failure as ReportedFailure {
            return failure.exitCode.rawValue
        }
    }

    /// Times vary run to run, so they read as `<t>`.
    static func timeless(_ text: String) -> String {
        text.replacing(#/\d+(\.\d)? (ms|s)\b/#, with: "<t>")
    }

    static let stopping = ["tap --id open", "wait --id open --timeout 0", "assert --id state --has-value Open", "describe-ui --summary"]

    @Test("a person reads a row per step, the steps a failure skipped, a ❌ closing and the dispatched warning; the agent's lines stay away")
    func batchStopped() async throws {
        let (person, console) = Self.person()
        let agent = Streams()
        let output = BatchOutput(json: false, write: { agent.out += $0 }, writeError: { agent.err += $0 }, person: console)

        #expect(try await Self.batch(Self.stopping, output: output) == 5)

        #expect(agent.out.isEmpty && agent.err.isEmpty)
        #expect(Self.timeless(person.out) == """
        📋  Batch                        4 steps
        ────────────────────────────────────────

          ✓ 1  tap --id open  <t>
          ✓ 2  wait --id open --timeout 0  <t>
          ✗ 3  assert --id state --has-value Open  Assertion failed: --id 'state' has …
          - 4  describe-ui --summary  not run

        ❌  Batch stopped at step 3  2 of 4 steps passed · <t>

        """)
        #expect(person.err == "⚠️  Input may have reached the device; check before resending\n")
    }

    @Test("an agent's batch prints the step lines and the failure summary it always has")
    func batchAgentUnchanged() async throws {
        let streams = Streams()
        let output = BatchOutput(json: false, write: { streams.out += $0 }, writeError: { streams.err += $0 })

        #expect(try await Self.batch(Self.stopping, output: output) == 5)

        #expect(Self.timeless(streams.out) == "✓ --id 'open' is on screen after <t>\n")
        #expect(streams.err == "Step 3 failed: [assert]\nAssertion failed: --id 'state' has value 'Closed', expected 'Open'.\nDispatched: yes (input may have reached the device; check before resending)\n")
    }

    @Test("a person's stdout with an agent's stderr still gets the failure summary there")
    func batchSplitStreams() async throws {
        let capture = ConsoleCapture()
        let console = capture.console(out: .person(), err: .agent)
        let output = BatchOutput(json: false, write: { console.data($0) }, writeError: { console.data($0, to: .err) }, person: console)

        #expect(try await Self.batch(Self.stopping, output: output) == 5)

        #expect(capture.out.contains("❌  Batch stopped at step 3"))
        #expect(capture.err.hasPrefix("Step 3 failed: [assert]\n") && !capture.err.contains("⚠️"))
    }

    @Test("a person's tree from a describe-ui step follows its row as an agent reads it")
    func batchTreeFollowsRow() async throws {
        let (person, console) = Self.person()
        #expect(try await Self.batch(["describe-ui --summary"], output: BatchOutput(json: false, write: { _ in }, writeError: { _ in }, person: console)) == 0)
        let agent = Streams()
        #expect(try await Self.batch(["describe-ui --summary"], output: BatchOutput(json: false, write: { agent.out += $0 }, writeError: { _ in })) == 0)

        let tree = try #require(agent.out.components(separatedBy: "✓ Batch").first)
        #expect(tree.contains("Open"))
        #expect(Self.timeless(person.out).contains("  ✓ 1  describe-ui --summary  <t>\n" + tree))
    }

    @Test("a type step's row shows neither its text nor how long it is")
    func batchTypeRow() async throws {
        let (person, console) = Self.person()
        let output = BatchOutput(json: false, write: { _ in }, writeError: { _ in }, person: console)

        _ = try await Self.batch(["type hunter22 --replace", "type 'pass word'"], output: output, continueOnError: true)

        #expect(person.out.contains(" 1  type <hidden> --replace"))
        #expect(person.out.contains(" 2  type <hidden>"))
        #expect(!person.out.contains("hunter22") && !person.out.contains("pass word") && !person.out.contains("character"))
        #expect(ReadPersonView.plannedLine("type hunter22 --into-id email") == "type <hidden> --into-id email")
    }

    @Test("a batch whose steps all ran ends with a ✅ for a person and the success line for an agent")
    func batchCompleted() {
        let (person, console) = Self.person()
        BatchOutput(json: false, write: { _ in }, writeError: { _ in }, person: console).completed(steps: 5, elapsed: 2.34)
        #expect(person.out == "\n✅  Batch done  5 steps · 2.3 s\n")

        let streams = Streams()
        BatchOutput(json: false, write: { streams.out += $0 }, writeError: { streams.err += $0 }).completed(steps: 5, elapsed: 2.34)
        #expect(streams.out == "✓ Batch completed successfully (5 steps)\n")
        let json = Streams()
        BatchOutput(json: true, write: { json.out += $0 }, writeError: { json.err += $0 }).completed(steps: 5, elapsed: 2.34)
        #expect(json.out.isEmpty && json.err == "✓ Batch completed successfully (5 steps)\n")
    }

    @Test("only a person reading stdout without --json gets rows")
    func batchAudience() {
        #expect(BatchOutput.console(json: false, console: Self.person().1).person != nil)
        #expect(BatchOutput.console(json: true, console: Self.person().1).person == nil)
        #expect(BatchOutput.console(json: false, console: Self.agent().1).person == nil)
    }

    @Test("the closing names the step that stopped the batch, the one that failed, or how many did")
    func batchClosing() {
        #expect(ReadPersonView.batchClosing(steps: 5, failed: [], ran: 5, elapsed: 2.34).headline == "Batch done")
        #expect(ReadPersonView.batchClosing(steps: 1, failed: [], ran: 1, elapsed: 0.02).aside == "1 step · 20 ms")
        #expect(ReadPersonView.batchClosing(steps: 5, failed: [3], ran: 3, elapsed: 1).headline == "Batch stopped at step 3")
        #expect(ReadPersonView.batchClosing(steps: 5, failed: [5], ran: 5, elapsed: 1).headline == "Step 5 failed")
        let several = ReadPersonView.batchClosing(steps: 5, failed: [2, 4], ran: 5, elapsed: 1)
        #expect(several.headline == "2 of 5 steps failed" && several.aside == "3 of 5 steps passed · 1 s" && !several.ok)
    }

    @Test("a step row never passes the edge: the detail is cut, then moves under the line, and a skipped step's is left out", arguments: [24, 40, 50, 80, 120])
    func streamRowFits(columns: Int) {
        let canvas = Canvas(columns: columns, style: .plain)
        let rows = [
            PersonRenderer.streamRow(status: .fail, key: "3", keyWidth: 2, text: "assert --id state --has-value Open", detail: "Assertion failed: --id 'state' has value 'Closed', expected 'Open'.", canvas: canvas),
            PersonRenderer.streamRow(status: .skip, key: "12", keyWidth: 2, text: "describe-ui --summary", detail: "not run", canvas: canvas),
            PersonRenderer.streamRow(status: .ok, key: "1", keyWidth: 2, text: "tap --id open", detail: "8 ms", canvas: canvas),
        ]
        for line in rows.joined().split(separator: "\n").map(String.init) {
            #expect(TerminalText.width(line) <= columns - 1, "\(line)")
        }
        #expect(rows[2] == (columns >= 28 ? "  ✓  1  tap --id open  8 ms\n" : "  ✓  1  tap --id open\n        8 ms\n"))
        #expect(rows[1].hasPrefix("  - 12  describe-ui") && rows[1].contains("not run") == (columns >= 39))
        #expect(rows[0].split(separator: "\n").count == (columns >= 61 ? 1 : 2))
    }

    @Test("ASCII rows use + and x, and a time under a second reads in ms")
    func asciiRowsAndTimes() {
        let canvas = Canvas(columns: 80, style: Self.ascii)
        #expect(PersonRenderer.streamRow(status: .ok, key: "1", keyWidth: 1, text: "tap --id open", detail: "8 ms", canvas: canvas) == "  + 1  tap --id open  8 ms\n")
        #expect(PersonRenderer.streamRow(status: .fail, key: "2", keyWidth: 1, text: "wait --id home", detail: "Timed out", canvas: canvas) == "  x 2  wait --id home  Timed out\n")
        #expect(ReadPersonView.elapsed(0.012) == "12 ms")
        #expect(ReadPersonView.elapsed(1.23) == "1.2 s")
        #expect(ReadPersonView.elapsed(0.96) == "1 s")
    }
}
