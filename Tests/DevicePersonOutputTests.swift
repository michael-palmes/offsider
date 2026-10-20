import Foundation
@testable import Offsider
@testable import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice
import Testing

/// What device-state, session and physical-device commands show a person, and that an agent reads exactly what it always did.
@Suite("Device person output")
@MainActor
struct DevicePersonOutputTests {
    static let ascii = TerminalStyle(colours: false, ascii: true)
    static let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
    static let simulator = DeviceID(rawValue: "00000000-0000-4000-8000-000000000001", platform: .ios)
    static let iPhone = "00000000-0000-4000-8000-000000000002"

    static func person(columns: Int = 80, style: TerminalStyle = .plain) -> (ConsoleCapture, Console) {
        let capture = ConsoleCapture()
        return (capture, capture.console(out: .person(columns: columns, style: style), err: .person(columns: columns, style: style)))
    }

    static func agent() -> (ConsoleCapture, Console) {
        let capture = ConsoleCapture()
        return (capture, capture.console(out: .agent, err: .agent))
    }

    /// Every line fits `columns - 1`, so a terminal never wraps one.
    static func fits(_ text: String, columns: Int) -> Bool {
        text.split(separator: "\n").allSatisfy { TerminalText.width(String($0)) <= columns - 1 }
    }

    // MARK: Device state

    @Test("a setter shows a person a receipt with what it was, and an agent the line it always read")
    func setterReceipt() {
        let (shown, console) = Self.person()
        DevicePersonView.emit("Appearance: dark (was light)", json: false, person: DevicePersonView.appearanceSet(.dark, before: .fixed(.light)), console: console)
        #expect(shown.out == "✅  Appearance dark  was light\n")
        #expect(shown.err.isEmpty)
        let (read, agent) = Self.agent()
        DevicePersonView.emit("Appearance: dark (was light)", json: false, person: DevicePersonView.appearanceSet(.dark, before: .fixed(.light)), console: agent)
        #expect(read.out == "Appearance: dark (was light)\n" && read.err.isEmpty)
    }

    @Test("an unchanged or scheduled earlier value says so, and an unreadable one says nothing")
    func setterDetails() {
        let render: ([Block]) -> String = { blocks in
            let (shown, console) = Self.person()
            console.show(Page(blocks))
            return shown.out
        }
        #expect(render(DevicePersonView.appearanceSet(.dark, before: .fixed(.dark))) == "✅  Appearance dark  unchanged\n")
        #expect(render(DevicePersonView.appearanceSet(.light, before: .scheduled("auto"))) == "✅  Appearance light  was auto\n")
        #expect(render(DevicePersonView.appearanceSet(.light, before: nil)) == "✅  Appearance light\n")
        let size = DevicePersonView.contentSize(
            ContentSizeReading(category: .extraLarge, fontScale: 1.15), previous: ContentSizeReading(category: .large, fontScale: 1), setting: true
        )
        #expect(render(size) == "✅  Content size extra-large  was large\n    font scale 1.15\n")
        let turned = DevicePersonView.orientation(
            .landscapeLeft, previous: .portrait, screen: UIScreenInfo(width: 914.29, height: 411.43), platform: .android,
            rotation: RotationReport(before: nil, now: nil, restored: false), setting: true
        )
        #expect(render(turned) == "✅  Orientation landscape-left  was portrait\n    914.29 x 411.43 dp\n")
    }

    @Test("a read is one key-value line, its detail after the value")
    func readLines() {
        let render: ([Block]) -> String = { blocks in
            let (shown, console) = Self.person()
            console.show(Page(blocks))
            return shown.out
        }
        #expect(render(DevicePersonView.appearance(.fixed(.dark))) == "  Appearance  dark\n")
        #expect(render(DevicePersonView.appearance(.scheduled("auto"))) == "  Appearance  auto follows the system schedule\n")
        #expect(render(DevicePersonView.contentSize(ContentSizeReading(category: .large, fontScale: nil), previous: nil, setting: false)) == "  Content size  large\n")
        let portrait = DevicePersonView.orientation(.portrait, previous: nil, screen: UIScreenInfo(width: 402, height: 874), platform: .ios, setting: false)
        #expect(render(portrait) == "  Orientation  portrait 402 x 874 pt\n")
        #expect(render(DevicePersonView.statusBar(StatusBarReading(demoAllowed: false))) == "  Demo mode  not allowed\n")
        #expect(render(DevicePersonView.statusBar(StatusBarReading(overrides: [:]))) == "  Status bar  no overrides\n")
    }

    @Test("a posture names its display and size, and a state name that is not the posture's own")
    func postureLines() {
        let screen = UIScreenInfo(width: 884, height: 1104, display: ScreenDisplay(id: "inner", platformId: "0"))
        let (read, console) = Self.person()
        console.show(Page(DevicePersonView.posture(.halfOpened, previous: nil, screen: screen, platform: .android, state: "TENT", angle: nil, setting: false)))
        #expect(read.out == "  Posture  half-opened One UI TENT, inner display, 884 x 1104 dp\n")
        let (set, other) = Self.person()
        other.show(Page(DevicePersonView.posture(.open, previous: .closed, screen: screen, platform: .android, state: "OPENED", angle: nil, setting: true)))
        #expect(set.out == "✅  Posture open  was closed\n    inner display, 884 x 1104 dp\n")
    }

    @Test("--json prints only the JSON, for a person too, with the notices an agent always read")
    func jsonStaysJSON() {
        let (shown, console) = Self.person()
        let notices = StatusBarCommand.notices(.override, on: Self.emulator)
        DevicePersonView.emit(#"{"version":1}"#, json: true, person: DevicePersonView.statusBarCleared(platform: .android), notices: notices, console: console)
        #expect(shown.out == "{\"version\":1}\n")
        #expect(shown.err.isEmpty)
        let (phone, agentConsole) = Self.agent()
        DevicePersonView.emit(#"{"version":1}"#, json: true, person: [], notices: StatusBarCommand.notices(.override, on: Self.phone), console: agentConsole)
        #expect(phone.err == "Note: demo mode stays on for R58M123ABC after this command; `offsider status-bar clear --device R58M123ABC` turns it off.\n")
    }

    @Test("state that outlives the command: a person reads how to undo it on any device; an agent only on a phone, in the words it always had")
    func lastingNotes() {
        let (emulator, console) = Self.person()
        DevicePersonView.emit("Status bar: 9:41", json: false, person: DevicePersonView.statusBarOverride(StatusBarOverride()), notices: StatusBarCommand.notices(.override, on: Self.emulator), console: console)
        #expect(emulator.out == "✅  Status bar overridden\n    9:41, battery 100 % not charging, Wi-Fi 3 bars, cellular 4 bars\n")
        #expect(emulator.err == "\n📌  Demo mode stays on after this command\n    Undo  offsider status-bar clear --device emulator-5554\n")

        let (quiet, agent) = Self.agent()
        agent.show(Page(notices: StatusBarCommand.notices(.override, on: Self.emulator) + StayAwakeCommand.notices(true, on: Self.emulator) + BiometricCommand.notices(.enrol, on: Self.simulator)))
        #expect(quiet.all.isEmpty)

        for (notices, note) in [
            (StatusBarCommand.notices(.override, on: Self.phone), StatusBarCommand.phoneNote(.override, on: Self.phone)),
            (StayAwakeCommand.notices(true, on: Self.phone), StayAwakeCommand.phoneNote(true, on: Self.phone)),
        ] {
            let (read, console) = Self.agent()
            console.show(Page(notices: notices))
            #expect(read.err == (note ?? "") + "\n")
        }

        let (stays, other) = Self.person()
        other.show(Page(notices: StayAwakeCommand.notices(true, on: Self.phone)))
        #expect(stays.err == "📌  Stays on across reboots\n    Undo  offsider stay-awake off --device R58M123ABC\n")
        let (enrolled, third) = Self.person()
        third.show(Page(notices: BiometricCommand.notices(.unenrol, on: Self.simulator)))
        #expect(enrolled.err.hasSuffix("Undo  offsider biometric enrol --device \(Self.simulator.rawValue)\n"))
    }

    @Test("Android's auto-rotate is named only when this turn switched it off")
    func autoRotateNote() {
        let (_, console) = Self.person()
        let on = AutoRotateState(accelerometerRotation: 1, userRotation: 0)
        let off = AutoRotateState(accelerometerRotation: 0, userRotation: 1)
        #expect(OrientationCommand.notices(.landscapeLeft, rotation: RotationReport(before: on, now: off, restored: false), on: Self.emulator).map(\.command)
            == ["offsider orientation portrait --device emulator-5554"])
        #expect(OrientationCommand.notices(.landscapeLeft, rotation: RotationReport(before: off, now: off, restored: false), on: Self.emulator).isEmpty)
        #expect(OrientationCommand.notices(.portrait, rotation: RotationReport(before: on, now: on, restored: true), on: Self.emulator).isEmpty)
    }

    @Test("warnings raised mid-command read to an agent exactly as the raw lines they replace")
    func warningsUnchangedForAgents() {
        let rotate = "Warning: Offsider could not switch auto-rotate back on on emulator-5554 (adb went away). Run `offsider orientation portrait --device emulator-5554` to try again."
        #expect(AgentRenderer.notice(OrientationCommand.autoRotateNotice(rotate, serial: "emulator-5554")) == rotate + "\n")
        let biometric = "Touch ID is not enrolled, so apps see no biometrics. Run `offsider biometric enrol --device \(Self.simulator.rawValue)` first."
        #expect(AgentRenderer.notice(BiometricCommand.unenrolled(biometric, name: "Touch ID", on: Self.simulator)) == "Warning: " + biometric + "\n")
        let (shown, console) = Self.person()
        console.notice(BiometricCommand.unenrolled(biometric, name: "Touch ID", on: Self.simulator))
        #expect(shown.err == "⚠️  Touch ID is not enrolled\n    Try  offsider biometric enrol --device \(Self.simulator.rawValue)\n")
    }

    @Test("wake, stay awake and biometrics read as receipts that never name a code")
    func awakeAndBiometric() {
        let render: ([Block]) -> String = { blocks in
            let (shown, console) = Self.person()
            console.show(Page(blocks))
            return shown.out
        }
        let locked = AwakeReading(screen: .off, lockScreen: .secure, credential: "pin")
        let usable = AwakeReading(screen: .on, lockScreen: .hidden, credential: "pin")
        let woken = render(DevicePersonView.wake(WakeOutcome(previous: locked, current: usable, sent: ["wake", "code"])))
        #expect(woken == "✅  Screen on and unlocked\n    with the saved PIN\n    was off, PIN lock screen showing\n")
        #expect(render(DevicePersonView.wake(WakeOutcome(previous: usable, current: usable, sent: []))) == "✅  Screen already on and unlocked\n")

        var notCharging = AwakeReading(screen: .on, lockScreen: .hidden, screenTimeoutMilliseconds: 600_000)
        notCharging.stayAwake = [.ac, .usb, .wireless]
        let set = render(DevicePersonView.stayAwake(notCharging, previous: AwakeReading(screen: .on, lockScreen: .hidden), setting: true))
        #expect(set == "✅  Stay awake on  was off\n    while charging\n    It is not charging, so the screen still turns off after 10 min\n")
        let read = render(DevicePersonView.stayAwake(AwakeReading(screen: .on, lockScreen: .hidden, screenTimeoutMilliseconds: 1_800_000), previous: nil, setting: false))
        #expect(read == "  Stay awake      off\n  Screen timeout  30 min\n")

        let face = DevicePersonView.biometric(.match, name: "Face ID", modality: .face, enrolled: true, sent: "x", platform: .ios)
        #expect(render(face) == "✅  Sent a matching face\n    an app must be asking for it\n")
        let finger = DevicePersonView.biometric(.noMatch, name: "Fingerprint", modality: .finger, enrolled: nil, sent: "finger touch 10", platform: .android)
        #expect(render(finger) == "✅  Touched the sensor with finger 10\n    finger 10 is not enrolled\n    an app must be asking for it\n")
        #expect(render(DevicePersonView.biometric(.status, name: "Face ID", modality: .face, enrolled: nil, sent: nil, platform: .ios)) == "  Face ID  unknown\n")
    }

    // MARK: Permissions

    static let change = PermissionChange(
        action: .grant,
        targets: [
            PermissionTargetChange(target: "camera", permissions: [PermissionEntry(name: "android.permission.CAMERA", previous: .denied, current: .granted, changed: true)]),
            PermissionTargetChange(target: "location", permissions: [PermissionEntry(name: "android.permission.ACCESS_FINE_LOCATION", previous: .granted, current: .granted, changed: false)]),
        ],
        notes: ["com.example.app does not request android.permission.READ_CONTACTS; grant applied to the rest."],
        appStopped: false
    )

    @Test("a permission change is a receipt, its notes are a person's notices, and an agent keeps them in stdout alone")
    func permissionChange() {
        let text = PermissionCommand.changeLines(Self.change, app: "com.example.app", platform: .android)
        let (shown, console) = Self.person()
        let notices = PermissionCommand.notices(Self.change, app: "com.example.app", on: Self.emulator)
        DevicePersonView.emit(text, json: false, person: DevicePersonView.permissionChange(Self.change, app: "com.example.app"), notices: notices, console: console)
        #expect(shown.out == "✅  Granted camera to com.example.app\n    location already granted\n")
        #expect(shown.err.contains("💡  com.example.app does not request android.permission.READ_CONTACTS;\n    grant applied to the rest.\n"))
        #expect(shown.err.contains("📌  Stays after this command\n    Reset  offsider permission reset camera --app com.example.app --device emulator-5554\n"))
        #expect(!shown.out.contains("Note:"))

        let (read, agent) = Self.agent()
        DevicePersonView.emit(text, json: false, person: [], notices: PermissionCommand.notices(Self.change, app: "com.example.app", on: Self.emulator), console: agent)
        #expect(read.out == text + "\n")
        #expect(read.out.hasSuffix("Note: com.example.app does not request android.permission.READ_CONTACTS; grant applied to the rest.\n"))
        #expect(read.err.isEmpty)
    }

    @Test("the services list is a table that says where each is offered, and fits 50 columns")
    func servicesTable() {
        for columns in [50, 80, 120] {
            let (shown, console) = Self.person(columns: columns)
            console.show(Page(DevicePersonView.services(PermissionService.allCases, platform: nil), notices: [DevicePersonView.literalNote]))
            #expect(Self.fits(shown.out, columns: columns), "\(columns) columns")
            #expect(shown.out.contains("Permission services"))
            #expect(shown.out.contains("camera") && shown.out.contains("Android"))
        }
        let (wide, console) = Self.person(columns: 120)
        console.show(Page(DevicePersonView.services(PermissionService.allCases, platform: nil)))
        #expect(wide.out.contains("  contacts-limited  iOS           not offered") == false)
        #expect(wide.out.contains("  camera            Android       CAMERA\n"))
        #expect(wide.out.contains("  contacts-limited  iOS\n"))
        let (ios, other) = Self.person()
        other.show(Page(DevicePersonView.services(PermissionService.offered(on: .ios), platform: .ios)))
        #expect(!ios.out.contains("Android") && ios.out.contains("on iOS"))
    }

    @Test("permission show lists each runtime permission behind a dot, granted or denied, under the app")
    func permissionShow() {
        let (shown, console) = Self.person()
        console.show(Page(DevicePersonView.permissions(PermissionServiceTests.state, app: "com.example.app")))
        #expect(shown.out.hasPrefix("📦  com.example.app"))
        #expect(shown.out.contains("granted") && shown.out.contains("denied"))
        #expect(shown.out.contains("  ✓ ACCESS_FINE_LOCATION"))
        #expect(shown.out.contains("  ○ POST_NOTIFICATIONS"))
    }

    // MARK: Sessions and the runner

    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func rows() -> [DeviceSessionRow] {
        let runner = RunnerSessionRow(
            record: RunnerSessionRecord(
                udid: iPhone, pid: 11, port: 40000, token: "secret-token", startedAt: started, lastUsed: started, buildKey: "k", version: "1", transport: .usbmux, process: nil
            ),
            alive: true
        )
        var reply = DeviceSessionReply(id: 1)
        reply.stream = DeviceSessionStreamStatus(state: .live, width: 1206, height: 2622, framesReceived: 90)
        let broker = DeviceSessionStatus(
            record: DeviceSessionRecord(udid: iPhone, pid: 22, process: nil, socket: "/s.sock", startedAt: started, version: 1, state: .running), alive: true, reply: reply
        )
        let helper = WarmHelperStatus(serial: "emulator-5554", state: "ready", brokerPid: 33, helperPid: 4567, startedAt: started, idleSeconds: 60, idleFor: 12)
        let input = HIDBrokerStatus(udid: simulator.rawValue, pid: 44, startedAt: started.timeIntervalSince1970, idleSeconds: 60, idleFor: 7, attached: 0, state: "ready")
        return DeviceSessionRow.rows(runners: [runner], brokers: [broker], helpers: [helper], inputs: [input])
    }

    @Test("session status: a header that counts what runs, one row per session behind a dot, and a device's ID once")
    func sessionStatus() {
        let rows = Self.rows()
        let (shown, console) = Self.person(columns: 100)
        console.show(Page([.person(DevicePersonView.sessions(rows, now: Self.started.addingTimeInterval(40))), .agent(DeviceSessionRow.text(rows))]))
        let lines = shown.out.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("🔌  Sessions") && lines[0].hasSuffix("4 running"))
        #expect(lines.contains("  ● \(Self.iPhone)  runner  idle 40 s"))
        #expect(lines.contains("  ●                                       broker  streaming 1206 x 2622"))
        #expect(lines.contains("  ● \(Self.simulator.rawValue)  input   idle 7 s of 60 s"))
        #expect(lines.contains("  ● emulator-5554                         helper  idle 12 s of 60 s"))
        #expect(shown.out.components(separatedBy: Self.iPhone).count == 2)
        #expect(!shown.out.contains("secret-token"))

        let (read, agent) = Self.agent()
        agent.show(Page([.person(DevicePersonView.sessions(rows)), .agent(DeviceSessionRow.text(rows))]))
        #expect(read.out == DeviceSessionRow.text(rows))

        let (empty, other) = Self.person()
        other.show(Page(DevicePersonView.sessions([])))
        #expect(empty.out.hasPrefix("🔌  Sessions") && empty.out.contains("none running") && empty.out.contains("Nothing is running."))
    }

    @Test("session rows stack under 60 columns, IDs whole, every line inside the width")
    func sessionStatusNarrow() {
        let (shown, console) = Self.person(columns: 50)
        console.show(Page(DevicePersonView.sessions(Self.rows(), now: Self.started)))
        #expect(Self.fits(shown.out, columns: 50))
        #expect(shown.out.contains(Self.iPhone) && shown.out.contains(Self.simulator.rawValue))
    }

    @Test("a stopped broker, one not answering and a starting helper each read as what they are")
    func sessionStates() {
        let broker = DeviceSessionStatus(
            record: DeviceSessionRecord(udid: Self.iPhone, pid: 22, process: nil, socket: "/s.sock", startedAt: Self.started, version: 1, state: .running), alive: true, reply: nil
        )
        let helper = WarmHelperStatus(serial: "emulator-5554", state: "starting", brokerPid: 33, helperPid: nil, startedAt: Self.started, idleSeconds: 60, idleFor: 0)
        let (shown, console) = Self.person(columns: 100)
        console.show(Page(DevicePersonView.sessions(DeviceSessionRow.rows(runners: [], brokers: [broker], helpers: [helper]))))
        #expect(shown.out.contains("  ! \(Self.iPhone)  broker  not answering"))
        #expect(shown.out.contains("  ◐ emulator-5554                         helper  starting, idle 0 s of 60 s"))
        #expect(shown.out.split(separator: "\n").first?.hasSuffix("1 starting · 1 not answering") == true)
    }

    @Test("stopping sessions or the runner is a receipt naming what stopped where, or that nothing was running")
    func stopReceipts() {
        let render: ([Block]) -> String = { blocks in
            let (shown, console) = Self.person()
            console.show(Page(blocks))
            return shown.out
        }
        let stopped = DeviceSessionRow.stopped(runners: ["A"], brokers: ["A"], helpers: ["emulator-5554"])
        #expect(render(DevicePersonView.stopped(stopped, device: nil)) == "✅  Stopped 3 sessions\n    runner and session broker on A\n    warm helper on emulator-5554\n")
        #expect(render(DevicePersonView.stopped([], device: "emulator-5554")) == "✅  Nothing to stop\n    no session on emulator-5554\n")
        #expect(render(DevicePersonView.runnersStopped([Self.iPhone], device: nil)) == "✅  Stopped the runner\n    \(Self.iPhone)\n")
        #expect(render(DevicePersonView.runnersStopped([], device: nil)) == "✅  Nothing to stop\n")
    }

    @Test("cleaning up the runner is a receipt; an app it could not remove is a warning, and what only Apple's site removes a note")
    func cleanReceipt() {
        var report = RunnerCleanupReport(udid: Self.iPhone)
        report.uninstalled = ["com.example.runner", "com.example.runner.uitests"]
        report.notUninstalled = ["com.example.other": "the device is locked"]
        report.removedBuilds = 2
        report.removedLogs = ["/Users/me/runner.log"]
        let view = DevicePersonView.cleaned(report)
        let (shown, console) = Self.person()
        console.show(Page(view.blocks, notices: view.notices))
        #expect(shown.out == "✅  Cleaned up the runner on \(Self.iPhone)\n    uninstalled com.example.runner and com.example.runner.uitests\n    deleted 2 cached builds and 1 log\n")
        #expect(shown.err.contains("⚠️  Did not uninstall com.example.other: the device is locked\n"))
        #expect(shown.err.contains("🏢  Your developer team keeps the runner's profile, App IDs and this"))
    }

    @Test("a runner build's receipt shows its folder under ~, never the home path")
    func buildReceipt() {
        let (shown, console) = Self.person()
        console.show(Page(DevicePersonView.built(udid: Self.iPhone, directory: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/offsider/runner/abc"))))
        #expect(shown.out == "✅  Runner built for \(Self.iPhone)\n    signature checked\n    ~/Library/Caches/offsider/runner/abc\n")
    }

    // MARK: Physical devices

    static let allowance = DeviceAllowance(
        platform: .ios, key: iPhone, name: "Apple Test iPhone", added: PolicyFixtures.added, expires: PolicyFixtures.added.addingTimeInterval(3_600), apps: ["com.example.app"]
    )

    @Test("the physical-device banner is one dim line for a person, broken between parts when narrow, and never cut")
    func personBanner() {
        let utc = TimeZone(identifier: "UTC")!
        let line = CommandScope.personBanner(for: Self.allowance, managed: false, now: PolicyFixtures.now, timeZone: utc, canvas: Canvas(columns: 80, style: .plain))
        #expect(line == "🔐  Driving Test iPhone · allowed until 15:13 · com.example.app only\n")
        let managed = CommandScope.personBanner(for: Self.allowance, managed: true, now: PolicyFixtures.now, timeZone: utc, canvas: Canvas(columns: 50, style: Self.ascii))
        #expect(managed == "[lock] Driving Test iPhone -\n       allowed until 15:13 -\n       com.example.app only -\n       managed policy applies\n")
        #expect(Self.fits(managed, columns: 50))
        let coloured = CommandScope.personBanner(for: Self.allowance, managed: false, now: PolicyFixtures.now, timeZone: utc, canvas: Canvas(columns: 80, style: TerminalStyle(colours: true)))
        #expect(coloured.hasPrefix("🔐  \u{1B}[2mDriving"))
    }

    @Test("the banner goes to stderr in every mode: a person's line on a person's terminal, the agent's exact line otherwise")
    func bannerRouting() {
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .ios, trees: []), device: DeviceID(rawValue: Self.iPhone, platform: .ios), allowance: Self.allowance)
        let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [Self.allowance])), now: PolicyFixtures.now)
        let agentLine = CommandScope.banner(for: Self.allowance, managed: false) + "\n"
        for (person, expected) in [(false, agentLine), (true, nil)] {
            let (shown, console) = person ? Self.person() : Self.agent()
            let scope = CommandScope()
            Console.$current.withValue(console) {
                DevicePolicyGate.$current.withValue(gate) {
                    scope.noteRoute(route)
                    scope.noteRoute(route)
                }
            }
            #expect(shown.out.isEmpty)
            if let expected {
                #expect(shown.err == expected)
            } else {
                #expect(shown.err.hasPrefix("🔐  Driving Test iPhone · allowed until ") && shown.err.hasSuffix("com.example.app only\n"))
                #expect(shown.err.split(separator: "\n").count == 1)
            }
        }
    }

    @Test("an off or locked screen's note reads to an agent as the line it always was, and to a person as the cause and a Try line")
    func screenNote() {
        let sentence = "ZY22FAKE01 is showing its password lock screen, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry."
        let notice = ScreenStateHint.notice("Note: " + sentence)
        #expect(AgentRenderer.notice(notice) == "Note: " + sentence + "\n")
        let (shown, console) = Self.person()
        console.notice(notice)
        #expect(shown.err == "🔐  ZY22FAKE01 is showing its password lock screen, so input and screen\n    reads do not reach the app.\n    Try  offsider wake --device ZY22FAKE01\n")
    }

    @Test("a device name holding backticks never becomes the Try command")
    func screenNoteIgnoresNameSpans() {
        let sentence = "Phone `rm x`. Now is showing its lock screen, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry."
        #expect(ScreenStateHint.notice("Note: " + sentence).command == "offsider wake --device ZY22FAKE01")
    }

    @Test("unlock-code saves, reads and removes as a person's receipts and lines, with the next command; an agent's text is unchanged")
    func unlockCodePages() throws {
        let store = MemoryUnlockCodeStore()
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)
        let code = try #require(UnlockCode("2468"))
        let saved = try UnlockCodeCommand.result(.set, device: "Pixel_9", name: "Pixel_9", json: false, store: store, ledger: ledger) { code }
        let (shown, console) = Self.person()
        console.show(saved.person)
        #expect(shown.out == "✅  Saved the unlock code for Pixel_9\n")
        #expect(shown.err == "\nNext  offsider wake --unlock --device Pixel_9\n")
        #expect(!(shown.out + shown.err).contains("2468"))
        #expect(saved.text == "Saved the unlock code for Pixel_9 in the login Keychain. `offsider wake --unlock --device Pixel_9` types it when the lock screen asks.")

        let status = try UnlockCodeCommand.result(.status, device: "Pixel_9", name: "Pixel_9", json: false, store: store, ledger: ledger) { code }
        let (read, other) = Self.person()
        other.show(status.person)
        #expect(read.out == "  Device       Pixel_9\n  Unlock code  saved\n")
        #expect(status.text == "Pixel_9: unlock code saved")

        let removed = try UnlockCodeCommand.result(.remove, device: "Pixel_9", name: "Pixel_9", json: false, store: store, ledger: ledger) { code }
        let gone = try UnlockCodeCommand.result(.remove, device: "Pixel_9", name: "Pixel_9", json: false, store: store, ledger: ledger) { code }
        let (both, third) = Self.person()
        third.show(removed.person)
        third.show(gone.person)
        #expect(both.out == "✅  Removed the unlock code for Pixel_9\n✅  Nothing to remove\n    no unlock code saved for Pixel_9\n")
    }
}
