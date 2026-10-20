import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// Synthetic reports and runs for the start area's person views: doctor, boot, run, lease, guide, init and video.
enum StartFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func clock(_ date: Date) -> String {
        RunClock.clock(date, separator: ":", timeZone: utc).split(separator: ":").prefix(2).joined(separator: ":")
    }

    static let simulator = BootedSimulator(udid: "00000000-0000-4000-8000-000000000001", name: "iPhone 17 Pro", osVersion: "iOS 27.0", deviceType: "iPhone 17 Pro")

    static func android(_ devices: [AndroidDeviceRow]) -> AndroidSummary {
        AndroidSummary(
            sdkRoot: "/Users/me/Library/Android/sdk", sdkSource: "default location", adbPath: "/Users/me/Library/Android/sdk/platform-tools/adb",
            adbVersion: "37.0.0-1", adbServer: "running", adbServerVersion: 41, emulatorRevision: "36.1.9", devices: devices
        )
    }

    static let checks = [
        DoctorCheckResult(id: .developerDir, status: .pass, detail: "/Applications/Xcode.app/Contents/Developer (xcode-select)"),
        DoctorCheckResult(id: .xcodeTrust, status: .pass, detail: "/Applications/Xcode.app is signed by Apple"),
        DoctorCheckResult(
            id: .simulatorApp, status: .warn, detail: "Simulator.app is running from Xcode 26.4, and Xcode 27 runs simulators under Device Hub",
            hint: "osascript -e 'quit app \"Simulator\"'"
        ),
        DoctorCheckResult(id: .stabilization, status: .pass, detail: "25 ms (default)"),
        DoctorCheckResult(id: .androidSDK, status: .pass, detail: "/Users/me/Library/Android/sdk (default location)"),
        DoctorCheckResult(
            id: .androidAdbServer, status: .fail, detail: "the adb server on 127.0.0.1:5037 did not answer within 5 s",
            hint: "Run `adb kill-server`; the next command starts a new one."
        ),
        DoctorCheckResult(id: .androidEmulator, status: .skip, detail: "requires android.adb-server"),
        DoctorCheckResult(id: .hostLoad, status: .pass, detail: "load 2.1 on 12 CPUs"),
    ]

    static var doctor: DoctorReport {
        DoctorReport(
            offsiderVersion: "0.13.0", udid: nil,
            xcode: XcodeSummary(developerDir: "/Applications/Xcode.app/Contents/Developer", version: "27.0", build: "27A5218g", coreSimulator: "1155.4"),
            booted: [simulator],
            android: android([AndroidDeviceRow(serial: "emulator-5554", kind: "emulator", state: "device", avd: "Pixel_9", apiLevel: 36)]),
            checks: checks,
            fixes: [DoctorFixResult(id: .deviceHub, action: "Open Device Hub", outcome: .applied, detail: "Opened Device Hub")]
        )
    }

    static var clean: DoctorReport {
        DoctorReport(
            offsiderVersion: "0.13.0", udid: nil, xcode: XcodeSummary(developerDir: nil, version: "27.0", build: nil, coreSimulator: nil),
            booted: [simulator], checks: [DoctorCheckResult(id: .developerDir, status: .pass, detail: "/Applications/Xcode.app/Contents/Developer (xcode-select)")]
        )
    }

    static var device: DoctorReport {
        DoctorReport(
            offsiderVersion: "0.13.0", udid: nil,
            device: DoctorDevice(id: "emulator-5554", platform: "android", name: "Pixel_9", kind: "emulator", source: "environment"),
            xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil), booted: [],
            android: android([AndroidDeviceRow(serial: "emulator-5554", kind: "emulator", state: "device", avd: "Pixel_9", apiLevel: 36)]),
            checks: [
                DoctorCheckResult(id: .androidSDK, status: .pass, detail: "/Users/me/Library/Android/sdk (default location)"),
                DoctorCheckResult(id: .androidDeviceScreen, status: .warn, detail: "the screen is off", hint: "offsider wake --device emulator-5554"),
                DoctorCheckResult(id: .deviceLease, status: .pass, detail: "Not leased"),
            ]
        )
    }

    static var timeline: RunTimeline {
        var state = RunState(label: "PR 123", startedAt: now, masks: .defaults)
        state.stoppedAt = now.addingTimeInterval(1_903)
        return RunTimeline(dir: "/Users/me/runs/pr-123", state: state, entries: [
            RunManifestLine(n: 1, file: "001-screenshot-14.13.40.png", command: "screenshot", device: "emulator-5554", time: now.addingTimeInterval(20), ms: 320, exit: 0, masked: 2),
            RunManifestLine(n: nil, file: nil, command: "screenshot", device: "emulator-5554", time: now.addingTimeInterval(80), ms: 90, exit: 1, reason: "mask_unproven"),
            RunManifestLine(n: 2, file: "002-logs-14.15.00.log", command: "logs", device: "emulator-5554", time: now.addingTimeInterval(100), ms: 800, exit: 0, entries: 12),
        ], unrecorded: ["003-screenshot-14.20.00.png"])
    }

    /// Every page the start area shows, for the agent contract.
    static var pages: [(name: String, page: Page)] {
        let lease = DeviceLease(label: "PR 123", created: now, expires: now.addingTimeInterval(3_600), pid: 77)
        let reading = AwakeReading(screen: .on, lockScreen: .swipe, credential: "none", userUnlocked: true, memTotalKB: 2_000_000)
        let state = RunState(label: "PR 123", startedAt: now, masks: .defaults)
        let run = RunStatusEntry(dir: "/Users/me/runs/pr-123", label: "PR 123", startedAt: now, owner: nil, files: 4)
        return [
            ("boot", StartPersonView.booted(name: "Pixel_9", id: "emulator-5554", alreadyRunning: false, notices: [
                BootReport.memoryNotice(avd: "Pixel_9", reading: reading), BootReport.screenNotice(avd: "Pixel_9", serial: "emulator-5554", reading: reading),
            ].compactMap { $0 })),
            ("run start", StartPersonView.runStarted(path: "/Users/me/runs/pr-123", state: state, start: .started, home: "/Users/me")),
            ("run start again", StartPersonView.runStarted(path: "/Users/me/runs/pr-123", state: state, start: .active(added: false), home: "/Users/me")),
            ("run stop", StartPersonView.runStopped(timeline, summary: true, now: now, timeZone: utc, home: "/Users/me")),
            ("run status", StartPersonView.runStatus(runs: [run], ended: [], timeZone: utc, home: "/Users/me")),
            ("lease set", StartPersonView.leased("Pixel_9", lease: lease, renewed: false, agentText: "Leased Pixel_9 to 'PR 123' until 15:13.")),
            ("lease show", StartPersonView.leases([LeasedDevice(platform: .android, key: "Pixel_9", lease: lease)], agentText: "android  Pixel_9  'PR 123'")),
            ("guide", StartPersonView.guideTopics(GuideTopic.allCases.map { ($0.rawValue, $0.readItWhen) }, agentText: Guide.topicList(), projectGuide: true)),
            ("init", InitScreen.page([InitScreen.Step(.installed, who: "Claude Code", path: "/Users/me/x", line: "Installed Offsider skill -> Claude Code: /Users/me/x")], next: "offsider doctor", home: "/Users/me")),
            ("video", StartPersonView.videoSaved(path: "/Users/me/rec.mp4", seconds: 12, frames: 120, held: 0, home: "/Users/me")),
        ]
    }

    static func capture(_ page: Page, out: Console.Channel = .person(), err: Console.Channel = .person()) -> ConsoleCapture {
        let capture = ConsoleCapture()
        capture.console(out: out, err: err).show(page)
        return capture
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The `Fix` line under the row starting `row`, before the next row; nil when there is none.
    static func fix(after row: String, in lines: [String]) -> String? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(row) }) else { return nil }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Fix") { return trimmed }
            if line.hasPrefix("  ") && !line.hasPrefix("    ") || line.isEmpty { return nil }
        }
        return nil
    }
}

@Suite("Start person output")
struct StartPersonOutputTests {
    static let colour = TerminalStyle(colours: true)
    static let ascii = TerminalStyle(colours: false, ascii: true)

    @Test("an agent's view of each page has no escape, carriage return or export, and a narrow terminal changes nothing", arguments: StartFixtures.pages.map(\.name))
    func agentContract(name: String) throws {
        let page = try #require(StartFixtures.pages.first { $0.name == name }?.page)
        let narrow = ConsoleCapture()
        AgentOutputTests.agentConsole(narrow, columns: 20).show(page)
        let wide = AgentOutputTests.render(page)
        let text = wide.out + wide.err
        #expect(!text.contains("\u{1B}") && !text.contains("\r") && !text.contains("export "))
        #expect(narrow.out == wide.out && narrow.err == wide.err)
        #expect(wide.err.split(separator: "\n").allSatisfy { line in ["Warning: ", "Note: ", "Try: "].contains { line.hasPrefix($0) } })
    }

    @Test("a person's view of each page fits 50 columns, and its commands and ids stay whole", arguments: StartFixtures.pages.map(\.name))
    func personFits(name: String) throws {
        let page = try #require(StartFixtures.pages.first { $0.name == name }?.page)
        let capture = StartFixtures.capture(page, out: .person(columns: 50), err: .person(columns: 50))
        for line in StartFixtures.lines(capture.out + capture.err) where !line.contains("Try  ") && !line.contains("Next  ") {
            #expect(TerminalText.width(line) <= 49, "\(line)")
        }
        #expect(!capture.out.contains("/Users/me"))
    }

    // MARK: Doctor

    @Test("doctor for a person:a header with Xcode and the counts, sections, a Fix under each problem and one closing line")
    func doctorPerson() {
        let text = DoctorRenderer.person(StartFixtures.doctor, canvas: Canvas(columns: 80, style: .plain))
        let lines = StartFixtures.lines(text)
        #expect(lines[0].hasPrefix("🩺  Doctor") && lines[0].hasSuffix("Xcode 27.0 · 1 failure · 1 warning"))
        #expect(lines.contains("  This Mac") && lines.contains("  Android"))
        #expect(StartFixtures.fix(after: "  ! host.simulator-app", in: lines) == "Fix  osascript -e 'quit app \"Simulator\"'")
        #expect(StartFixtures.fix(after: "  ✗ android.adb-server", in: lines)?.hasPrefix("Fix  Run adb kill-server; the next command") == true)
        #expect(StartFixtures.fix(after: "  ✓ xcode.trust", in: lines) == nil)
        #expect(lines.contains { $0.hasPrefix("  - android.emulator") && $0.hasSuffix("requires android.adb-server") })
        #expect(lines.contains { $0.contains("● iPhone 17 Pro") && $0.contains("00000000-0000-4000-8000-000000000001") })
        #expect(lines.contains { $0.contains("● Pixel_9") && $0.contains("emulator-5554") && $0.hasSuffix("API 36") })
        #expect(lines.contains { $0.hasPrefix("  ✓ host.device-hub") && $0.hasSuffix("Opened Device Hub") })
        #expect(lines.last(where: { !$0.isEmpty }) == "❌  1 failure · 1 warning")
        #expect(!text.contains("Result:") && !text.contains("Fix:"))
    }

    @Test("a sentence hint keeps its words and turns its code cyan; a bare command is cyan whole")
    func doctorFixColours() {
        let lines = StartFixtures.lines(DoctorRenderer.person(StartFixtures.doctor, canvas: Canvas(columns: 100, style: Self.colour)))
        #expect(lines.contains { $0.contains("Fix") && $0.contains("\u{1B}[36mosascript -e 'quit app \"Simulator\"'\u{1B}[0m") })
        #expect(lines.contains { $0.contains("Run \u{1B}[36madb kill-server\u{1B}[0m; the next command") })
    }

    @Test("doctor fits each width: details wrap whole under themselves, and under 60 columns stack beneath the id", arguments: [50, 80, 120])
    func doctorWidths(columns: Int) {
        let canvas = Canvas(columns: columns, style: .plain)
        let lines = StartFixtures.lines(DoctorRenderer.person(StartFixtures.doctor, canvas: canvas))
        for line in lines { #expect(TerminalText.width(line) <= canvas.usable, "\(line)") }
        let text = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        #expect(text.contains("the adb server on 127.0.0.1:5037 did not answer within 5 s"))
        #expect(text.contains("Simulator.app is running from Xcode 26.4, and Xcode 27 runs simulators under Device Hub"))
        #expect(lines.contains("  ✓ xcode.developer-dir") == (columns < 60))
        #expect(StartFixtures.fix(after: "  ! host.simulator-app", in: lines) == "Fix  osascript -e 'quit app \"Simulator\"'")
    }

    @Test("ASCII doctor: tags for marks and dots, nothing wider than plain text")
    func doctorASCII() {
        let text = DoctorRenderer.person(StartFixtures.doctor, canvas: Canvas(columns: 80, style: Self.ascii))
        #expect(text.hasPrefix("Doctor"))
        #expect(text.contains("  ! host.simulator-app") && text.contains("  x android.adb-server") && text.contains("  + xcode.trust"))
        #expect(text.contains("[x] 1 failure - 1 warning"))
        #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("a device report names the device in the header and its section, and says it came from OFFSIDER_DEVICE")
    func doctorDevice() {
        let lines = StartFixtures.lines(DoctorRenderer.person(StartFixtures.device, canvas: Canvas(columns: 80, style: .plain)))
        #expect(lines[0].hasSuffix("Pixel_9 (emulator-5554) · 1 warning"))
        #expect(lines.contains("  Pixel_9 (emulator-5554)  from OFFSIDER_DEVICE"))
        #expect(!lines.contains { $0.contains("Running") })
        #expect(lines.last(where: { !$0.isEmpty }) == "⚠️  1 warning")
    }

    @Test("doctor writes an agent's text byte for byte, a person's checklist with the next step on stderr, and --json as before")
    func doctorWrite() throws {
        let report = StartFixtures.clean
        let agent = ConsoleCapture()
        try Doctor.write(report, json: false, console: agent.console(out: .agent, err: .agent))
        #expect(agent.out == DoctorRenderer.render(report) + "Next: offsider doctor --device 00000000-0000-4000-8000-000000000001\n")
        #expect(agent.err.isEmpty)

        let person = ConsoleCapture()
        try Doctor.write(report, json: false, console: person.console(out: .person(), err: .person()))
        #expect(person.out.hasPrefix("🩺  Doctor") && person.out.hasSuffix("✅  No problems found\n\n"))
        #expect(person.err == "Next  offsider doctor --device 00000000-0000-4000-8000-000000000001\n")

        let json = ConsoleCapture()
        try Doctor.write(report, json: true, console: json.console(out: .person(), err: .agent))
        #expect(json.err == DoctorRenderer.render(report) + "Next: offsider doctor --device 00000000-0000-4000-8000-000000000001\n")
        #expect(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) is [String: Any])
    }

    // MARK: Boot

    @Test("booter lines become spinner steps, kept notes or nothing, as the booters write them")
    func bootLines() {
        #expect(StartPersonView.bootLine("Starting Pixel_9...") == .step("Starting Pixel_9"))
        #expect(StartPersonView.bootLine("Waiting for Android to finish booting on emulator-5554...") == .step("Waiting for Android to finish booting on emulator-5554"))
        #expect(StartPersonView.bootLine("Pixel_9 is already starting as emulator-5554.") == .step("Pixel_9 is already starting as emulator-5554"))
        #expect(StartPersonView.bootLine("Booting iPhone 17 Pro (00000000-0000-4000-8000-000000000001).") == .step("Booting iPhone 17 Pro (00000000-0000-4000-8000-000000000001)"))
        #expect(StartPersonView.bootLine("Pixel_9 is already running as emulator-5554.") == .running)
        #expect(StartPersonView.bootLine("Pixel_9 is already running as emulator-5554 without gRPC; commands will use adb.")
            == .note("Pixel_9 is already running as emulator-5554 without gRPC; commands will use adb"))
        #expect(StartPersonView.bootLine("-memory ignored: Pixel_9 is already running.") == .note("-memory ignored: Pixel_9 is already running"))
    }

    @Test("an agent reads every booter line on stderr as it comes; a person's spinner takes the steps and the notes wait for the receipt")
    func bootProgress() {
        let agent = ConsoleCapture()
        var agentLines = StartPersonView.Lines(console: agent.console(out: .agent, err: .agent))
        for line in ["Starting Pixel_9...", "-memory ignored: Pixel_9 is already running.", "Pixel_9 is already running as emulator-5554."] {
            StartPersonView.bootProgress(line, lines: &agentLines)
        }
        #expect(agent.err == "Starting Pixel_9...\n-memory ignored: Pixel_9 is already running.\nPixel_9 is already running as emulator-5554.\n")
        #expect(agentLines.notices.isEmpty)

        let person = ConsoleCapture()
        var personLines = StartPersonView.Lines(console: person.console(out: .person(), err: .person()))
        for line in ["Starting Pixel_9...", "-memory ignored: Pixel_9 is already running."] {
            StartPersonView.bootProgress(line, lines: &personLines)
        }
        #expect(person.all.isEmpty)
        #expect(personLines.notices == [.note("-memory ignored: Pixel_9 is already running")])
    }

    @Test("boot leaves an agent the serial alone and a person a receipt, the warning and the next command")
    func booted() throws {
        let reading = AwakeReading(screen: .on, lockScreen: .hidden, credential: "none", userUnlocked: true, memTotalKB: 2_000_000)
        let memory = try #require(BootReport.memoryNotice(avd: "Pixel_9", reading: reading))
        let page = StartPersonView.booted(name: "Pixel_9", id: "emulator-5554", alreadyRunning: false, notices: [memory])
        let agent = StartFixtures.capture(page, out: .agent, err: .agent)
        #expect(agent.out == "emulator-5554\n")
        #expect(agent.err == "Warning: Pixel_9 has 1.9 GB of RAM, which is tight for a React Native debug build. Close it, then run `offsider boot Pixel_9 --memory 4096`.\n")
        let person = StartFixtures.capture(page)
        #expect(person.out == "✅  Pixel_9 is running\n    emulator-5554\n")
        #expect(person.err.contains("Try  offsider boot Pixel_9 --memory 4096"))
        #expect(person.err.hasSuffix("\nNext  offsider describe-ui --device emulator-5554\n"))
        let again = StartFixtures.capture(StartPersonView.booted(name: "iPhone 17 Pro", id: "00000000-0000-4000-8000-000000000001", alreadyRunning: true))
        #expect(again.out.hasPrefix("✅  iPhone 17 Pro was already running\n"))
    }

    // MARK: Run

    @Test("run start: an agent reads the folder alone, a person a receipt with ~ and the stop command")
    func runStarted() {
        let state = RunState(label: "PR 123", startedAt: StartFixtures.now, masks: .defaults)
        let page = StartPersonView.runStarted(path: "/Users/me/runs/pr-123", state: state, start: .started, home: "/Users/me")
        #expect(StartFixtures.capture(page, out: .agent, err: .agent).out == "/Users/me/runs/pr-123\n")
        let person = StartFixtures.capture(page)
        #expect(person.out == "✅  Run started\n    ~/runs/pr-123\n    PR 123\n")
        #expect(person.err == "\nNext  offsider run stop --summary\n")
        let active = StartFixtures.capture(StartPersonView.runStarted(path: "/Users/me/runs/pr-123", state: state, start: .active(added: true), home: "/Users/me"))
        #expect(active.out.contains("Masks added to the run") && active.out.contains("masks password fields and email addresses"))
        #expect(active.err.contains("See  offsider run stop") && !active.err.contains("Next"))
    }

    @Test("the run start lines an agent reads stay on stderr word for word, and a person's warning follows the receipt")
    func runStartLines() {
        let agent = ConsoleCapture()
        var lines = StartPersonView.Lines(console: agent.console(out: .agent, err: .agent))
        lines.add("Warning: other users can write to /tmp/run, so they could add or change files in the run.", person: .warning("Other users can write to this run's folder"))
        lines.add("Started a run in /tmp/run; screenshots and logs from this session are numbered into it. Run `offsider run stop --summary` when done.", person: nil)
        #expect(agent.err == "Warning: other users can write to /tmp/run, so they could add or change files in the run.\nStarted a run in /tmp/run; screenshots and logs from this session are numbered into it. Run `offsider run stop --summary` when done.\n")
        #expect(lines.notices.isEmpty)

        let person = ConsoleCapture()
        let console = person.console(out: .person(), err: .person())
        var personLines = StartPersonView.Lines(console: console)
        personLines.add("Warning: other users can write to /tmp/run.", person: .warning("Other users can write to this run's folder"))
        var page = StartPersonView.runStarted(path: "/tmp/run", state: RunState(label: nil, startedAt: StartFixtures.now, masks: .defaults), start: .started)
        page.notices = personLines.notices + page.notices
        console.show(page)
        #expect(person.all.map(\.stream) == [.out, .err])
        #expect(person.err.hasPrefix("\n⚠️  Other users can write to this run's folder\n"))
    }

    @Test("run stop --summary: an agent reads the timeline as before; a person a header, a row per capture and the counts")
    func runStopped() {
        let timeline = StartFixtures.timeline
        let page = StartPersonView.runStopped(timeline, summary: true, now: StartFixtures.now, timeZone: StartFixtures.utc, home: "/Users/me")
        #expect(StartFixtures.capture(page, out: .agent, err: .agent).out == timeline.text(now: StartFixtures.now, timeZone: StartFixtures.utc) + "\n")
        let lines = StartFixtures.lines(StartFixtures.capture(page).out)
        #expect(lines[0].hasPrefix("🎬  Run PR 123") && lines[0].hasSuffix("14:13:20 to 14:45:03 · 31 min 43 s"))
        #expect(lines.contains { $0.hasPrefix("  ✓ 001") && $0.contains("001-screenshot-14.13.40.png masked 2") })
        #expect(lines.contains { $0.hasPrefix("  ✗ ---") && $0.contains("exit 1 mask_unproven") })
        #expect(lines.contains { $0.hasPrefix("  ! 003") && $0.contains("unrecorded") })
        #expect(lines.suffix(4) == ["✅  Run stopped", "    ~/runs/pr-123", "    2 files, 1 failure, 1 unrecorded", ""])

        let plain = StartPersonView.runStopped(timeline, summary: false, now: StartFixtures.now, home: "/Users/me")
        #expect(StartFixtures.capture(plain, out: .agent, err: .agent).out == "Stopped the run in /Users/me/runs/pr-123: 2 files, 1 failure.\n")
        #expect(StartFixtures.capture(plain).out == "✅  Run stopped\n    ~/runs/pr-123\n    2 files, 1 failure, 1 unrecorded\n")
        #expect(StartFixtures.capture(StartPersonView.noRun, out: .agent, err: .agent).out == "No run is active.\n")
    }

    @Test("run status: an agent's lines as before; a person's live runs on and ended runs off")
    func runStatus() {
        let live = RunStatusEntry(dir: "/Users/me/runs/pr-123", label: "PR 123", startedAt: StartFixtures.now, owner: ProcessIdentity(pid: 812, startTime: 1, name: "node"), files: 4)
        let ended = RunStatusEntry(dir: "/Users/me/runs/old", label: nil, startedAt: StartFixtures.now, owner: nil, files: 0, endedBy: "owner-exited")
        let page = StartPersonView.runStatus(runs: [live], ended: [ended], timeZone: StartFixtures.utc, home: "/Users/me")
        #expect(StartFixtures.capture(page, out: .agent, err: .agent).out == ended.text(timeZone: StartFixtures.utc) + "\n" + live.text(timeZone: StartFixtures.utc) + "\n")
        let lines = StartFixtures.lines(StartFixtures.capture(page).out)
        #expect(lines[0].hasPrefix("🎬  Runs") && lines[0].hasSuffix("1 active · 1 ended"))
        #expect(lines.contains { $0.hasPrefix("  ● PR 123") && $0.contains("~/runs/pr-123") && $0.contains("since 14:13:20") && $0.contains("4 files") })
        #expect(lines.contains { $0.hasPrefix("  ○ Run") && $0.contains("its session exited") })
        #expect(StartFixtures.capture(StartPersonView.runStatus(runs: [], ended: [])).out == "  No run is active.\n")
    }

    // MARK: Lease

    @Test("lease set: an agent's sentence never says export; a person's receipt, with export as the next step only when no session was found")
    func leased() {
        let lease = DeviceLease(label: "PR 123", created: StartFixtures.now, expires: StartFixtures.now.addingTimeInterval(3_600), pid: 77)
        let page = StartPersonView.leased("Pixel_9", lease: lease, renewed: false, agentText: "agent words", clock: StartFixtures.clock)
        let agent = StartFixtures.capture(page, out: .agent, err: .agent)
        #expect(agent.out == "agent words\n" && agent.err.isEmpty)
        let person = StartFixtures.capture(page)
        #expect(person.out == "✅  Pixel_9 leased to PR 123\n    until 15:13\n")
        #expect(person.err == "\nNext  export OFFSIDER_LEASE='PR 123'\n")
        let owned = DeviceLease(label: "PR 123", created: StartFixtures.now, expires: StartFixtures.now, pid: 77, owner: ProcessIdentity(pid: 812, startTime: 1, name: "node"))
        let mine = StartFixtures.capture(StartPersonView.leased("Pixel_9", lease: owned, renewed: true, agentText: "x", clock: StartFixtures.clock))
        #expect(mine.out.contains("Lease on Pixel_9 renewed for PR 123") && mine.out.contains("for this session (node, pid 812)") && mine.err.isEmpty)
    }

    @Test("lease show and release: a person's table and receipt; an agent's lines unchanged")
    func leaseShowAndRelease() {
        let lease = DeviceLease(label: "PR 123", created: StartFixtures.now, expires: StartFixtures.now.addingTimeInterval(3_600), pid: 77)
        let shown = StartPersonView.leases([LeasedDevice(platform: .android, key: "Pixel_9", lease: lease)], agentText: "android  Pixel_9  'PR 123'", clock: StartFixtures.clock)
        #expect(StartFixtures.capture(shown, out: .agent, err: .agent).out == "android  Pixel_9  'PR 123'\n")
        let lines = StartFixtures.lines(StartFixtures.capture(shown).out)
        #expect(lines[0].hasPrefix("📌  Lease") && lines[0].hasSuffix("1 leased"))
        #expect(lines.contains { $0.hasPrefix("  ● Pixel_9") && $0.contains("PR 123") && $0.contains("14:13 to 15:13") })
        #expect(StartFixtures.capture(StartPersonView.leases([], agentText: "No devices are leased.")).out == "  No devices are leased.\n")
        let released = StartFixtures.capture(StartPersonView.released("Pixel_9", lease: lease, agentText: "Released the lease 'PR 123' on Pixel_9."))
        #expect(released.out == "✅  Released Pixel_9\n    was leased to PR 123\n")
    }

    // MARK: Guide

    @Test("guide's topic list: an agent reads it unchanged; a person sees each topic cyan beside when to read it, fitted to the width")
    func guideTopics() {
        let topics = GuideTopic.allCases.map { ($0.rawValue, $0.readItWhen) }
        let page = StartPersonView.guideTopics(topics, agentText: Guide.topicList(), projectGuide: true)
        let agent = StartFixtures.capture(page, out: .agent, err: .agent)
        #expect(agent.out == Guide.topicList())
        #expect(agent.err.isEmpty)
        let colour = StartFixtures.capture(page, out: .person(style: Self.colour), err: .person(style: Self.colour))
        #expect(colour.out.contains("\u{1B}[36mselectors\u{1B}[0m"))
        #expect(colour.out.contains("\u{1B}[36moffsider guide --project .\u{1B}[0m") && colour.err.isEmpty)
        for columns in [50, 80] {
            let canvas = Canvas(columns: columns, style: .plain)
            let lines = StartFixtures.lines(StartFixtures.capture(page, out: .person(columns: columns), err: .person(columns: columns)).out)
            #expect(lines.allSatisfy { TerminalText.width($0) <= canvas.usable })
            #expect(lines.contains { $0.hasPrefix("  react-native") })
        }
    }

    // MARK: Video

    @Test("a recording's live line counts minutes and seconds; its end is a receipt for a person and the path for an agent")
    func video() {
        #expect(StartPersonView.recordingLabel(device: "emulator-5554", elapsed: 72.9) == "Recording emulator-5554  01:12  (Ctrl+C to stop)")
        let page = StartPersonView.videoSaved(path: "/Users/me/Desktop/rec.mp4", seconds: 12.4, frames: 120, held: 3, home: "/Users/me")
        #expect(StartFixtures.capture(page, out: .agent, err: .agent).out == "/Users/me/Desktop/rec.mp4\n")
        #expect(StartFixtures.capture(page).out == "✅  Video saved\n    ~/Desktop/rec.mp4\n    12 s, 120 frames, 3 held\n")
        #expect(StartPersonView.streamHeader(device: "emulator-5554", format: "mjpeg", fps: 10) == "Streaming emulator-5554 as mjpeg at 10 fps  (Ctrl+C to stop)")
    }

    // MARK: Stderr

    @Test("stderr helpers: an agent's lines byte for byte; a person's notices, dim asides and spinner labels instead")
    func stderrHelpers() {
        let agent = ConsoleCapture()
        let agentConsole = agent.console(out: .agent, err: .agent)
        agentConsole.line("Project guide: /tmp/OFFSIDER.md", person: .note("From /tmp/OFFSIDER.md"))
        StartPersonView.step("Waiting for dtuhidd to answer (up to 45 s)...", label: "Waiting for dtuhidd", console: agentConsole)
        StartPersonView.aside("Press Ctrl+C to stop streaming", person: "Streaming", console: agentConsole)
        StartPersonView.aside(nil, person: "Streaming now", console: agentConsole)
        #expect(agent.err == "Project guide: /tmp/OFFSIDER.md\nWaiting for dtuhidd to answer (up to 45 s)...\nPress Ctrl+C to stop streaming\n")
        #expect(agent.out.isEmpty)

        let person = ConsoleCapture()
        let personConsole = person.console(out: .person(), err: .person(style: Self.colour))
        personConsole.line("Project guide: /tmp/OFFSIDER.md", person: .note("From /tmp/OFFSIDER.md", mark: .guide))
        personConsole.line("Press Ctrl+C to stop recording", person: nil)
        StartPersonView.step("Waiting for dtuhidd to answer (up to 45 s)...", label: "Waiting for dtuhidd", console: personConsole)
        StartPersonView.aside("Press Ctrl+C to stop streaming", person: "Streaming", console: personConsole)
        #expect(person.err == "📖  From /tmp/OFFSIDER.md\n\u{1B}[2mStreaming\u{1B}[0m\n")

        let dumb = ConsoleCapture()
        let still = Console.Channel(profile: .person, canvas: Canvas(columns: 80, style: .plain), isTerminal: true, animates: false)
        StartPersonView.step("Starting Pixel_9...", label: "Starting Pixel_9", console: dumb.console(out: still, err: still))
        #expect(dumb.err == "Starting Pixel_9...\n")
    }
}
