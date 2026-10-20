import ArgumentParser
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// What the input commands show: a person gets a receipt or a ❌ with commands to try; an agent reads the same bytes as before.
@Suite("Input person output")
@MainActor
struct InputPersonOutputTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let ascii = TerminalStyle(colours: false, ascii: true)

    /// Runs `body` with every write captured: both streams a person's terminal `columns` wide, or both an agent's.
    static func run(person: Bool, columns: Int = 80, style: TerminalStyle = .plain, _ body: () async throws -> Void) async rethrows -> ConsoleCapture {
        let capture = ConsoleCapture()
        let channel: Console.Channel = person ? .person(columns: columns, style: style) : .agent
        try await Console.$current.withValue(capture.console(out: channel, err: channel)) { try await body() }
        return capture
    }

    static func show(_ page: Page, person: Bool, columns: Int = 80, style: TerminalStyle = .plain) -> ConsoleCapture {
        let capture = ConsoleCapture()
        let channel: Console.Channel = person ? .person(columns: columns, style: style) : .agent
        capture.console(out: channel, err: channel).show(page)
        return capture
    }

    static let screen = FakeUI.tree([FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 200, 44))])

    static func request(
        _ command: String = "tap", subject: String = "Tap on id=save", target: String = "id=save", options: [String] = ["--verify"],
        styles: [TapDeliveryStyle?] = [.simulator, .physical], node: UINode? = nil, personSubject: String? = nil
    ) throws -> VerifyRequest {
        VerifyRequest(
            command: command, subject: subject, target: target, backend: FakeDeviceBackend(trees: []), device: device,
            options: try VerificationOptions.parse(options), styles: styles, targetNode: node, personSubject: personSubject
        )
    }

    static var verified: Verifier.Outcome {
        var outcome = Verifier.Outcome(verified: true, attempts: 2, change: .accessibilityTree, style: .physical, summary: nil)
        outcome.changes = [VerifyChange(kind: .changed, node: "text id=count", field: "value", old: "0", new: "1")]
        outcome.phases = VerifyPhases(settle: 0.3, resolve: 0.1, dispatch: 0.1, verify: 1.2)
        return outcome
    }

    // MARK: Receipts

    @Test("a command that is silent for an agent stays silent, and a person gets one receipt naming what was sent")
    func silentReceipts() async throws {
        let touch = try Touch.parse(["-x", "200", "-y", "400", "--down", "--up", "--delay", "1.0", "--device", "x"])
        let key = try Key.parse(["40", "--duration", "1.5", "--device", "x"])
        let gesture = try Gesture.parse(["long-press-drag", "--x", "200", "--y", "300", "--to-x", "200", "--to-y", "600", "--device", "x"])
        let pages: [(Page, String)] = [
            (InputPersonView.receipt(try Swipe.parse(["--start-x", "100", "--start-y", "600", "--end-x", "100", "--end-y", "200", "--device", "x"]).receiptHeadline),
             "✅  Swiped (100, 600) to (100, 200)\n"),
            (InputPersonView.receipt(try Drag.parse(["--start-x", "100", "--start-y", "300", "--end-x", "100", "--end-y", "600", "--device", "x"]).receiptHeadline),
             "✅  Dragged (100, 300) to (100, 600)\n"),
            (InputPersonView.receipt(touch.receiptHeadline, aside: touch.receiptAside), "✅  Touched (200, 400)  held 1 s\n"),
            (InputPersonView.receipt(try Touch.parse(["-x", "200", "-y", "400", "--down", "--device", "x"]).receiptHeadline), "✅  Touch down at (200, 400)\n"),
            (InputPersonView.receipt("Sent \(gesture.preset.rawValue)", aside: gesture.receiptAside), "✅  Sent long-press-drag  (200, 300) to (200, 600)\n"),
            (InputPersonView.receipt(key.receiptHeadline, aside: key.receiptAside), "✅  Pressed Return  key 40, held 1.5 s\n"),
            (InputPersonView.receipt("Sent " + InputPersonView.combo(modifiers: [227], key: 4, android: false)), "✅  Sent Cmd+A\n"),
        ]
        for (page, expected) in pages {
            let agent = Self.show(page, person: false)
            #expect(agent.all.isEmpty)
            let person = Self.show(page, person: true)
            #expect(person.out == expected)
            #expect(person.err.isEmpty)
        }
    }

    @Test("tap keeps the agent's completion line byte for byte; a person reads what was tapped and where")
    func tapReceipt() async throws {
        func tap(person: Bool) async throws -> ConsoleCapture {
            try await Self.run(person: person) {
                try await Tap.parse(["--id", "save", "--no-settle", "--device", Self.device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: FakeDeviceBackend(trees: [Self.screen]), device: Self.device), progress: nil, logger: OffsiderLogger())
            }
        }
        let agent = try await tap(person: false)
        #expect(agent.out == Tap.completionLine(selector: "id=save", at: (x: 120, y: 622)) + "\n")
        #expect(agent.err.isEmpty)
        #expect(try await tap(person: true).out == "✅  Tapped id=save  (120, 622)\n")
    }

    @Test("an off-screen tap warns an agent once, in the words it always read, and a person with a warning mark")
    func offScreenWarning() async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen], screen: UIScreenInfo(width: 402, height: 874))
        let agent = await Self.run(person: false) {
            await Tap.warnIfOffScreen(x: 500, y: 100, backend: backend, device: Self.device)
            await Tap.warnIfOffScreen(x: 500, y: 100, backend: backend, device: Self.device)
        }
        #expect(agent.err == (Tap.offScreenWarning(x: 500, y: 100, screen: UISize(width: 402, height: 874)) ?? "") + "\n")
        let person = await Self.run(person: true) { await Tap.warnIfOffScreen(x: 500, y: 100, backend: backend, device: Self.device) }
        #expect(person.err == "⚠️  (500, 100) is outside the 402x874 screen; the tap may do nothing\n")
    }

    @Test("type's receipt names the field, never the text or how long it was", arguments: [
        (["s3cret-text", "--into-id", "email"], "Typed into id=email"),
        (["--replace", "", "--into-label", "Email"], "Cleared label=Email"),
        (["--replace", "s3cret-text"], "Replaced the text in the focused field"),
        (["s3cret-text"], "Typed into the focused field"),
    ] as [([String], String)])
    func typeReceipt(arguments: [String], expected: String) throws {
        let headline = try Type.parse(arguments + ["--device", "x"]).receiptHeadline
        #expect(headline == expected)
        #expect(!headline.contains("s3cret") && !headline.contains("11"))
    }

    @Test("a file read for type names it to an agent with its size as before; a person reads the path alone")
    func typeFileNote() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("text.txt")
        try Data("s3cret-text".utf8).write(to: file)
        let type = try Type.parse(["--file", file.path, "--device", "x"])
        let read = try TextFileInput.read(file.path, allowing: nil)

        let agent = try await Self.run(person: false) { _ = try type.readFromFile(file.path) }
        #expect(agent.err == read.announcement + "\n")
        let person = try await Self.run(person: true) { _ = try type.readFromFile(file.path) }
        #expect(person.err.hasPrefix("📝  Reading text from") && person.err.contains("text.txt"))
        #expect(!person.err.contains("bytes"))
    }

    // MARK: Keys

    @Test("a key that types a character is never named; one that types nothing is, and shortcuts use each platform's modifier names")
    func keyNames() throws {
        #expect((4...39).allSatisfy { InputPersonView.keyName($0) == nil })
        #expect(InputPersonView.keyName(40) == "Return" && InputPersonView.keyName(58) == "F1" && InputPersonView.keyName(82) == "Up arrow")
        #expect(try Key.parse(["4", "--device", "x"]).receiptHeadline == "Pressed key 4")
        #expect(InputPersonView.combo(modifiers: [227, 225], key: 4, android: false) == "Cmd+Shift+A")
        #expect(InputPersonView.combo(modifiers: [227], key: 4, android: true) == "Meta+A")
        #expect(InputPersonView.combo(modifiers: [224], key: 40, android: true) == "Ctrl+Return")
        #expect(InputPersonView.combo(modifiers: [226], key: 200, android: false) == "Option+key 200")
    }

    // MARK: Verify

    @Test("a verified input keeps the agent's line and the timing suffix bench-ab parses; a person reads a receipt with the timings")
    func verifiedLine() async throws {
        let request = try Self.request()
        let agent = try await Self.run(person: false) { try VerifyOutput.report(Self.verified, for: request) }
        #expect(agent.out == VerifyOutput.verifiedLine(Self.verified, for: request) + "\n")
        #expect(agent.out.contains(#/ \(settle [0-9.]+ s, [a-z]+ [0-9.]+ s, verify [0-9.]+ s\)\n/#))
        #expect(agent.err.isEmpty)

        let person = try await Self.run(person: true) { try VerifyOutput.report(Self.verified, for: request) }
        #expect(person.out == """
            ✅  Tap on id=save verified
                Changed: value of text id=count "0" to "1"
                Attempt 2 of 2, physical style
                Settle 0.4 s, tap 0.1 s, verify 1.2 s

            """)
        #expect(person.err.isEmpty)
    }

    @Test("under --json the verified line stays on stderr and the report on stdout, whoever reads them")
    func verifiedJSON() async throws {
        let request = try Self.request(options: ["--verify", "--json"])
        let agent = try await Self.run(person: false) { try VerifyOutput.report(Self.verified, for: request) }
        #expect(agent.err == VerifyOutput.verifiedLine(Self.verified, for: request) + "\n")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(agent.out.utf8)) as? [String: Any])
        #expect(report["verified"] as? Bool == true)
    }

    @Test("nothing changing fails on stderr: the agent's ✗ line as before, a person's ❌ with the commands to try")
    func unverified() async throws {
        let request = try Self.request()
        let outcome = Verifier.Outcome(verified: false, attempts: 2, change: .none, style: .physical, summary: nil)
        let agent = await Self.run(person: false) {
            #expect(throws: ExitCode(5)) { try VerifyOutput.report(outcome, for: request) }
        }
        #expect(agent.err == VerifyOutput.unverifiedLine(outcome, for: request) + "\n")
        #expect(agent.out.isEmpty)

        let person = await Self.run(person: true) {
            #expect(throws: ExitCode(5)) { try VerifyOutput.report(outcome, for: request) }
        }
        #expect(person.err == """
            ❌  Tap on id=save changed nothing
                Sent 2 times (simulator, then physical style)
                Try  offsider describe-ui --summary --device fake-device
                Or   offsider doctor --device fake-device

            """)
        #expect(person.out.isEmpty)
    }

    @Test("a switch that may change late tells a person the wait to run rather than tapping again")
    func lateSwitch() throws {
        let node = FakeUI.node(.switch, id: "alerts", label: "Alerts", value: "0")
        let request = try Self.request(subject: "Tap on id=alerts", target: "id=alerts", styles: [.physical], node: node)
        let failure = VerifyOutput.personUnverified(Verifier.Outcome(verified: false, attempts: 1, change: .none, style: .physical, summary: nil), for: request)
        #expect(failure.headline == "Tap on id=alerts changed nothing yet")
        #expect(failure.commands == ["offsider wait --id alerts --has-value 1 --timeout 10 --device fake-device"])
        #expect(failure.details.allSatisfy { !$0.contains("offsider wait") })
    }

    @Test("a person's verify lines for type never count the characters an agent's line does")
    func typedLength() async throws {
        let request = try Self.request("type", subject: "Typing text (11 characters)", target: "text (11 characters)", styles: [nil, nil], personSubject: Type.personSubject)
        var outcome = Verifier.Outcome(verified: true, attempts: 1, change: .screenshot, style: nil, summary: nil)
        outcome.phases = VerifyPhases(verify: 0.5)
        let person = try await Self.run(person: true) { try VerifyOutput.report(outcome, for: request) }
        #expect(person.out.hasPrefix("✅  Typed text verified\n"))
        #expect(!person.out.contains("11") && !person.out.contains("character"))
        let failed = VerifyOutput.personUnverified(Verifier.Outcome(verified: false, attempts: 1, change: .none, style: nil, summary: nil), for: request)
        #expect(!([failed.headline] + failed.details).joined().contains("11"))
        let agent = try await Self.run(person: false) { try VerifyOutput.report(outcome, for: request) }
        #expect(agent.out.hasPrefix("✓ Typing text (11 characters) verified: "))
    }

    @Test("a retry is the agent's ! line as before and a person's warning")
    func retry() async {
        let failed = Verifier.Attempt(number: 1, style: .simulator)
        let next = Verifier.Attempt(number: 2, style: .physical)
        let note = { Console.current.line(VerifyOutput.retryLine(failed: failed, next: next), person: .warning(VerifyOutput.personRetry(failed: failed, next: next))) }
        #expect(await Self.run(person: false) { note() }.err == "! No observable change after attempt 1 (simulator style); retrying with physical style\n")
        #expect(await Self.run(person: true) { note() }.err == "⚠️  Nothing changed after attempt 1; trying physical style\n")
    }

    // MARK: Button home

    /// `button home` on an Android fake whose launcher comes up only after the HOME intent, or never; once through `Console`, once through the seams.
    static func home(_ arguments: [String], reached: Bool, person: Bool) async throws -> (capture: ConsoleCapture, seams: (out: String, err: String)) {
        func backend() -> FakeDeviceBackend {
            let backend = FakeDeviceBackend(platform: .android, trees: [])
            backend.foregrounds = [ForegroundActivities(top: "com.example.app/.Main", home: "com.example.launcher/.Home")]
            if reached { backend.foregroundAfterIntent = ForegroundActivities(top: "com.example.launcher/.Home", home: "com.example.launcher/.Home") }
            return backend
        }
        let options = try VerificationOptions.parse(arguments)
        let capture = await Self.run(person: person) {
            try? await Button.pressHome(on: backend(), device: Self.android, verification: options, sleep: { _ in })
        }
        var out = ""
        var err = ""
        try? await Button.pressHome(on: backend(), device: Self.android, verification: options, sleep: { _ in }, writeOutput: { out += $0 + "\n" }, writeError: { err += $0 + "\n" })
        return (capture, (out, err))
    }

    @Test("Android home without seams writes an agent exactly what the seams receive", arguments: [
        ([], true), ([], false), (["--verify"], true), (["--verify"], false), (["--verify", "--json"], true),
    ] as [([String], Bool)])
    func homeAgentBytes(arguments: [String], reached: Bool) async throws {
        let (capture, seams) = try await Self.home(arguments, reached: reached, person: false)
        #expect(!(capture.out + capture.err).isEmpty)
        #expect(capture.out == seams.out)
        #expect(capture.err == seams.err)
    }

    @Test("Android home gives a person a receipt, a warning when the launcher never came, and a ❌ when --verify fails")
    func homePerson() async throws {
        let viaIntent = try await Self.home([], reached: true, person: true).capture
        #expect(viaIntent.out == "✅  Pressed Home\n    The launcher came to the front\n    The home key was ignored, so Offsider sent the HOME intent\n")
        #expect(viaIntent.err.isEmpty)
        let stuck = try await Self.home([], reached: false, person: true).capture
        #expect(stuck.out.isEmpty)
        #expect(stuck.err.hasPrefix("⚠️  com.example.app/.Main is still in front"))
        let failed = try await Self.home(["--verify"], reached: false, person: true).capture
        #expect(failed.err.hasPrefix("❌  Home button not verified\n"))
        #expect(failed.err.contains("Try  offsider describe-ui --summary --device emulator-5554"))
    }

    // MARK: Reads and sign-in

    @Test("login keeps the agent's line; a person reads who signed in and that the server's answer is not checked")
    func login() throws {
        let filter = try #require(LoginTag(rawValue: "role=admin"))
        let report = LoginReport(app: "com.example.app", key: "qa-admin", turnstile: .absent, submitLabel: "Sign in", filter: [filter])
        #expect(Self.show(InputPersonView.login(report), person: false).out == report.textLine() + "\n")
        #expect(Self.show(InputPersonView.login(report), person: true).out == """
            ✅  Signed in as qa-admin
                com.example.app: tapped Sign in
                Chosen by --where role=admin
                Server answer not checked

            """)
    }

    @Test("turnstile keeps the agent's state line; a person reads the state and what to do while it waits on someone")
    func turnstile() {
        let status = TurnstileStatus(state: .checkbox, source: .tree, frame: FakeUI.frame(32, 388.95, 163.81, 25.14))
        #expect(Self.show(InputPersonView.turnstile(status), person: false).out == status.textLine() + "\n")
        let person = Self.show(InputPersonView.turnstile(status), person: true).out
        #expect(person.hasPrefix("  Turnstile  checkbox at (32, 388.95) 163.81x25.14\n"))
        #expect(person.contains("A person must tick it"))
    }

    @Test("LogBox status keeps the agent's lines; a person's rows quote device text and keep it redacted")
    func logBox() {
        var state = LogBoxState(tree: FakeUI.tree([]))
        state.toasts = [
            LogBoxToast(count: 2, frame: FakeUI.frame(10, 800, 380, 48), message: "Each child needs a key", index: 1),
            LogBoxToast(count: 1, frame: FakeUI.frame(10, 740, 380, 48), message: "Bad \u{1B}[31mred text password=hunter2", index: 2),
        ]
        let page = InputPersonView.logBox(state, redacts: true, device: "fake-device")
        #expect(Self.show(page, person: false).out == state.text(redacts: true) + "\n")
        let person = Self.show(page, person: true, style: Self.ascii).out
        #expect(person.hasPrefix("LogBox"))
        #expect(person.contains("3 logs - 2 toasts"))
        #expect(person.contains("  1  Each child needs a key 2 logs\n"))
        #expect(person.contains("\"Bad \\u001b[31mred text password=[redacted]\""))
        #expect(!person.contains("hunter2") && !person.contains("\u{1B}"))
    }

    @Test("rn logbox dismiss: a clear run is the agent's ✓ line or a person's receipt; logs left fail on stderr")
    func logBoxDismiss() {
        let cleared = LogBoxDismissal(cleared: 3, remaining: 0, method: .inspector)
        let page = InputPersonView.receipt(RNLogBoxDismiss.personLine(cleared, index: nil), details: RNLogBoxDismiss.personMethod(cleared), agent: RNLogBoxDismiss.line(cleared, index: nil, device: "x") + "\n")
        #expect(Self.show(page, person: false).out == "✓ Cleared 3 LogBox logs (inspector)\n")
        #expect(Self.show(page, person: true).out == "✅  Cleared 3 LogBox logs\n    Through the inspector's Dismiss\n")
        let left = LogBoxDismissal(cleared: 1, remaining: 2, method: .dismissButton)
        #expect(RNLogBoxDismiss.personFailure(left).headline == "2 LogBox logs are still on screen")
        #expect(RNLogBoxDismiss.personFailure(LogBoxDismissal(cleared: 0, remaining: 0, method: .none, emptyDialog: true)).headline == "An empty LogBox dialog covers the app")
    }

    @Test("rn devmenu and rn tools off keep the agent's lines; a person reads the items or what was chosen")
    func devMenu() {
        let listed = RNDevMenu.Outcome.listed(DevMenu.State(menu: "expo", items: ["Reload", "Go home"].map { DevMenu.Entry(label: $0, role: .button, frame: nil) }))
        #expect(Self.show(listed.page, person: false).out == "expo dev menu: Reload, Go home\n")
        let person = Self.show(listed.page, person: true).out
        #expect(person.hasPrefix("📋  Dev menu") && person.contains("Expo · 2 items") && person.contains("\n  Go home\n"))
        let chose = RNDevMenu.Outcome.chose(menu: "expo", item: .reload, label: "Reload")
        #expect(Self.show(chose.page, person: false).out == "✓ Chose Reload and the dev menu closed\n")
        #expect(Self.show(chose.page, person: true).out == "✅  Chose Reload\n    The dev menu closed\n")
        #expect(Self.show(RNToolsOff.page(inspector: "turned-off", perfMonitor: "off"), person: false).out == "Element inspector: turned-off; performance monitor: off\n")
    }

    @Test("a profile's removed turnstile key reaches an agent in its old words and a person as a warning")
    func removedTurnstileKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"bundleId":"com.example.app","turnstile":"required"}"#.utf8).write(to: folder.appendingPathComponent(LoginProfile.fileName))
        let agent = try await Self.run(person: false) { _ = try LoginProfiles.load(project: folder.path) }
        #expect(agent.err == LoginProfile.removedTurnstileWarning + "\n")
        let person = try await Self.run(person: true) { _ = try LoginProfiles.load(project: folder.path) }
        #expect(person.err.hasPrefix("⚠️  offsider.login.json has a"))
    }

    // MARK: Every page

    static var pages: [Page] {
        get throws {
            var state = LogBoxState(tree: FakeUI.tree([]))
            state.toasts = [LogBoxToast(count: 1, frame: FakeUI.frame(10, 800, 380, 48), message: String(repeating: "A long LogBox message ", count: 8), index: 1)]
            return [
                InputPersonView.receipt(Tap.receiptHeadline(selector: "label=" + String(repeating: "Settings ", count: 8), at: (x: 120, y: 640)), details: ["(120, 640)"]),
                InputPersonView.receipt("Slider id=volume set to 50%", details: ["The nearest step to 42%"]),
                InputPersonView.login(LoginReport(app: "com.example.app", key: "qa", turnstile: nil, submitLabel: "Continue with your email address")),
                InputPersonView.turnstile(TurnstileStatus(state: .challenge, source: .webViewPoints)),
                InputPersonView.devMenu("react-native", labels: ["Reload", "Toggle Element Inspector"], agent: "react-native dev menu: Reload, Toggle Element Inspector"),
                InputPersonView.logBox(state, redacts: true, device: "00000000-0000-4000-8000-000000000001"),
                RNLogBoxOpen.page(LogBoxOpening(toast: state.toasts[0], inspector: LogBoxInspector(log: 1, of: 2)), redacts: true),
            ]
        }
    }

    @Test("every person view fits the terminal at 50 and 80 columns, in ASCII under NO_COLOR too", arguments: [50, 80])
    func fits(columns: Int) throws {
        for page in try Self.pages {
            for style in [TerminalStyle.plain, Self.ascii] {
                let text = Self.show(page, person: true, columns: columns, style: style).out
                for line in text.split(separator: "\n").map(String.init) {
                    #expect(TerminalText.width(line) <= columns - 1, "\(line)")
                }
            }
        }
    }

    @Test("an agent's input output holds no escape or carriage return, even on a colour terminal")
    func agentPlain() throws {
        for page in try Self.pages {
            let capture = ConsoleCapture()
            let channel = Console.Channel(profile: .agent, canvas: Canvas(columns: 20, style: TerminalStyle(colours: true)), isTerminal: true, animates: true)
            capture.console(out: channel, err: channel).show(page)
            #expect(!(capture.out + capture.err).contains("\u{1B}") && !(capture.out + capture.err).contains("\r"))
        }
    }
}
