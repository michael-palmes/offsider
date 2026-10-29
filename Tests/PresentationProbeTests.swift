import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A simulator's backend whose probe answers with `probeHit`, counting every probe apart from hit-tests.
@MainActor
final class ProbingFakeBackend: FakeDeviceBackend, PointHitTesting, PresentationProbing {
    var probeHit: UINode?
    /// How long a probe takes to answer, for a read that stalls.
    var probeDelay: Duration?
    private(set) var probes = 0
    private(set) var hitTests = 0
    private(set) var hitPoints: [UIPoint] = []
    /// How many trees had been read when the first probe began.
    private(set) var treeReadsAtFirstProbe: Int?

    func hitTest(at point: UIPoint, on id: DeviceID, appPIDs: Set<Int>) async throws -> UINode? {
        hitTests += 1
        hitPoints.append(point)
        return try await accessibilityTree(for: id, point: point).roots.first
    }

    func processName(of pid: Int, on id: DeviceID) async -> String? { nil }

    func probe(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
        probes += 1
        treeReadsAtFirstProbe = treeReadsAtFirstProbe ?? treeReads
        if let probeDelay { try await Task.sleep(for: probeDelay) }
        return probeHit
    }
}

@Suite("Presentation probe")
@MainActor
struct PresentationProbeTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let hostPID = 1000
    /// Above any pid macOS hands out, so the live process lookup finds nothing.
    static let foreignPID = 999_999_999
    static let pickerPath = "/Users/me/Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000001/data/PickerService.appex/PickerService"

    static func node(_ role: UIRole, id: String? = nil, label: String? = nil, value: String? = nil, frame: UIFrame, pid: Int = hostPID, children: [UINode] = []) -> UINode {
        UINode(role: role, id: id, label: label, value: value, frame: frame, native: .ios(IOSNativeAttributes(pid: pid)), children: children)
    }

    static func screen(_ children: [UINode]) -> UITree {
        UITree(platform: .ios, device: device.rawValue, roots: [node(.application, label: "Playground", frame: FakeUI.frame(0, 0, 402, 874), children: children)])
    }

    static let home = screen([
        node(.header, id: "home-title", label: "Home", frame: FakeUI.frame(60, 74, 282, 20)),
        node(.button, id: "home-open", label: "Open Picker", frame: FakeUI.frame(16, 420, 370, 44)),
    ])

    static func finding(_ tree: UITree, hit: UINode?) -> PresentationFinding {
        PresentationProbe.finding(in: tree, hit: hit) { pid in pid == foreignPID ? pickerPath : nil }
    }

    @Test("a hit from another process is presented: its label masked and cut to 40 characters, its process the executable's file name only")
    func foreignProcessIsPresented() throws {
        let hit = Self.node(.button, label: "Sign in as reviewer@example.com to continue with your account", value: "secret-value", frame: FakeUI.frame(16, 420, 370, 44), pid: Self.foreignPID)

        let presented = try #require(Self.finding(Self.home, hit: hit).presented)

        #expect(presented == UITreeContext.Presented(label: "Sign in as [redacted email] to continue…", role: .button, process: "PickerService"))
        #expect(presented.summary == #""Sign in as [redacted email] to continue…" from PickerService"#)
    }

    static let webContentPID = 999_999_998

    static func webFinding(_ tree: UITree, hit: UINode?) -> PresentationFinding {
        PresentationProbe.finding(in: tree, hit: hit) { pid in pid == webContentPID ? "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent" : nil }
    }

    @Test("web content inside the app's own web view smaller than the screen, as a widget in a form, presents nothing")
    func hostedWebContentIsNotPresented() {
        let form = Self.screen([
            Self.node(.textField, id: "email", frame: FakeUI.frame(16, 300, 370, 34)),
            Self.node(.group, id: "widget", frame: FakeUI.frame(16, 405, 370, 64), children: [Self.node(.scrollView, frame: FakeUI.frame(16, 405, 370, 64))]),
        ])
        let hit = Self.node(.text, label: "Confirm you are here", frame: FakeUI.frame(40, 420, 200, 20), pid: Self.webContentPID)

        #expect(Self.webFinding(form, hit: hit) == PresentationFinding())
    }

    @Test("web content with no small scroll view of the app around it, only a card or a control, or from another process than WebKit's, is still presented")
    func unhostedWebContentIsPresented() throws {
        let hit = Self.node(.text, label: "Confirm you are here", frame: FakeUI.frame(40, 420, 200, 20), pid: Self.webContentPID)
        let screenSized = Self.screen([Self.node(.group, id: "page", frame: FakeUI.frame(0, 0, 402, 874))])

        #expect(try #require(Self.webFinding(screenSized, hit: hit).presented).process == "com.apple.WebKit.WebContent")
        #expect(try #require(Self.webFinding(Self.home, hit: hit).presented).label == "Confirm you are here")

        let card = Self.screen([Self.node(.group, id: "card", frame: FakeUI.frame(16, 300, 370, 300))])
        #expect(Self.webFinding(card, hit: hit).presented != nil)

        let picker = Self.node(.button, label: "Cancel", frame: FakeUI.frame(40, 420, 200, 20), pid: Self.foreignPID)
        let form = Self.screen([Self.node(.scrollView, id: "widget", frame: FakeUI.frame(16, 405, 370, 64))])
        #expect(Self.finding(form, hit: picker).presented?.process == "PickerService")
    }

    @Test("a hit the tree lists, from the app's own process, presents nothing", arguments: [false, true])
    func ownElementIsNotPresented(moved: Bool) throws {
        var hit = try #require(Self.home.roots[0].children.last)
        if moved {
            hit.label = "Open Picker (2)"
            hit.frame = FakeUI.frame(16, 420.5, 370, 44)
        }

        #expect(Self.finding(Self.home, hit: hit) == PresentationFinding())
    }

    @Test("a hit the tree does not list is presented even from the app's own process")
    func unlistedHitIsPresented() {
        let hit = Self.node(.button, id: "sheet-done", label: "Done", frame: FakeUI.frame(300, 60, 80, 44))

        #expect(Self.finding(Self.home, hit: hit).presented == UITreeContext.Presented(label: "Done", role: .button, process: nil))
    }

    @Test("a system prompt found at the same middle names what is over the app, so presented is not named twice, while a stale frame still is")
    func systemPromptWins() {
        var tree = Self.home
        tree.systemPrompt = SystemPrompt(title: "Save Password?", process: "PickerService", pid: Self.foreignPID)
        let stale = UITreeContext.StaleFrame(id: "sheet-host", label: nil, frame: FakeUI.frame(0, 10000, 402, 874))

        tree.apply(PresentationFinding(presented: UITreeContext.Presented(label: "Save Password?", role: .button, process: "PickerService"), staleFrame: stale))

        #expect(tree.presented == nil && tree.staleFrame == stale)
        #expect(tree.context.headerLines.contains("# window: Save Password? (system)"))
        #expect(!tree.context.headerLines.contains { $0.hasPrefix("# presented:") })
    }

    @Test("from the app's own process, an unlabelled container or a row that scrolled between the two reads presents nothing")
    func ownMotionIsNotPresented() {
        let container = Self.node(.group, frame: FakeUI.frame(0, 300, 402, 240))
        let scrolled = Self.node(.text, label: "Home", frame: FakeUI.frame(60, 34, 282, 20))
        let tree = Self.screen([Self.node(.text, label: "Home", frame: FakeUI.frame(60, 74, 282, 20))])

        #expect(Self.finding(tree, hit: container).presented == nil)
        #expect(Self.finding(tree, hit: scrolled).presented == nil)
    }

    @Test("a secure field from another process shows no label, only its role")
    func secureFieldShowsNoLabel() {
        let hit = Self.node(.secureTextField, label: "Password", value: "••••", frame: FakeUI.frame(16, 420, 370, 44), pid: Self.foreignPID)

        let presented = Self.finding(Self.home, hit: hit).presented

        #expect(presented == UITreeContext.Presented(label: nil, role: .secureTextField, process: "PickerService"))
        #expect(presented?.summary == "secureTextField from PickerService")
    }

    /// A modal sheet listed far below the screen while the screen shows it, over a drawer panel parked to the left.
    static func staleSheet(sheetChildren: [UINode]? = nil) -> UITree {
        let menu = node(.group, id: "drawer-panel", frame: FakeUI.frame(-300, 0, 300, 874), children: [
            node(.button, id: "menu-settings", label: "Settings", frame: FakeUI.frame(-280, 120, 260, 44)),
        ])
        let sheet = node(.group, id: "sheet-host", frame: FakeUI.frame(0, 10000, 402, 874), children: sheetChildren ?? [
            node(.header, label: "Sheet Title", frame: FakeUI.frame(16, 10100, 370, 40)),
            node(.button, id: "sheet-done", label: "Done", frame: FakeUI.frame(16, 10437, 370, 44)),
            node(.button, id: "sheet-cancel", label: "Cancel", frame: FakeUI.frame(16, 10500, 370, 44)),
        ])
        return screen([menu, sheet])
    }

    @Test("a centre read landing in a screen-sized node listed off screen with labelled children flags its frame as stale")
    func staleFrameIsFlagged() throws {
        let tree = Self.staleSheet()
        let done = try #require(tree.roots[0].children[1].children[1])

        let finding = Self.finding(tree, hit: done)

        #expect(finding.presented == nil)
        #expect(finding.staleFrame == UITreeContext.StaleFrame(id: "sheet-host", label: nil, frame: FakeUI.frame(0, 10000, 402, 874)))
        #expect(finding.explaining("off screen at (0, 10000) 402x874") == "off screen at (0, 10000) 402x874 (likely a stale frame: the screen's centre is inside id=sheet-host; check a screenshot)")
    }

    @Test("no stale frame for a read in a node smaller than the screen, at the root, or in a screen-sized node holding nothing labelled")
    func staleFrameNegatives() throws {
        let tree = Self.staleSheet()
        let settings = try #require(tree.roots[0].children[0].children.first)
        #expect(Self.finding(tree, hit: settings).staleFrame == nil)
        #expect(Self.finding(tree, hit: tree.roots[0]).staleFrame == nil)

        let bare = Self.staleSheet(sheetChildren: [Self.node(.group, frame: FakeUI.frame(0, 10000, 402, 874))])
        #expect(Self.finding(bare, hit: bare.roots[0].children[1]).staleFrame == nil)
    }

    @Test("describe-ui names what is presented and a stale frame under the header, and JSON carries both")
    func headerAndJSON() throws {
        var tree = Self.staleSheet()
        tree.apply(PresentationFinding(
            presented: UITreeContext.Presented(label: "Cancel", role: .button, process: "PickerService"),
            staleFrame: UITreeContext.StaleFrame(id: "sheet-host", label: nil, frame: FakeUI.frame(0, 10000, 402, 874))
        ))

        let summary = String(decoding: UITreeRenderer.render(tree, .summary), as: UTF8.self)
        let context = try #require((try JSONSerialization.jsonObject(with: tree.jsonData()) as? [String: Any])?["context"] as? [String: Any])

        #expect(summary.hasPrefix("""
        # ios fake-device
        # presented: "Cancel" from PickerService
        # stale frame: id=sheet-host is listed off screen at (0, 10000) 402x874, but the screen's centre is inside it; check a screenshot

        """))
        #expect(context["presented"] as? [String: String] == ["label": "Cancel", "role": "button", "process": "PickerService"])
        #expect((context["staleFrame"] as? [String: Any])?["id"] as? String == "sheet-host")
        #expect(try UITree(jsonData: tree.jsonData()).context == tree.context)
    }

    @Test("without a finding the context keys are null and the header has no such lines")
    func absentFinding() throws {
        let context = try #require((try JSONSerialization.jsonObject(with: Self.home.jsonData()) as? [String: Any])?["context"] as? [String: Any])

        #expect(context["presented"] is NSNull && context["staleFrame"] is NSNull)
        #expect(Self.home.context.headerLines.isEmpty)
    }

    @Test("an off-screen run says how many listed items its nodes hide, and a run hiding none reads as before")
    func runCountsInside() {
        let summary = String(decoding: UITreeRenderer.render(Self.staleSheet(), .summary), as: UTF8.self)
        let rows = Self.screen([
            Self.node(.button, id: "row-20", label: "Row 20", frame: FakeUI.frame(0, 900, 402, 44)),
            Self.node(.button, id: "row-21", label: "Row 21", frame: FakeUI.frame(0, 944, 402, 44)),
        ])

        #expect(summary.contains("\n  [off-screen below] 1 item (+3 inside): id=sheet-host\n"))
        #expect(summary.contains("\n  [off-screen left] 1 item (+1 inside): id=drawer-panel\n"))
        #expect(String(decoding: UITreeRenderer.render(rows, .summary), as: UTF8.self).contains("\n  [off-screen below] 2 items: id=row-20 to id=row-21\n"))
    }

    // MARK: Budget

    static func describe(_ arguments: [String], on backend: ProbingFakeBackend) async throws -> String {
        let fixture = try TreeCacheFixture()
        return try await fixture.run {
            try await DescribeUI.parse(arguments + ["--device", Self.device.rawValue]).describe(on: DeviceRouter.Route(backend: backend, device: Self.device))
        }
    }

    static let screenInfo = UIScreenInfo(width: 402, height: 874, scale: 3)

    @Test("describe-ui probes once, started before the tree read so the two overlap, and prints what another process presents")
    func describeProbesOnce() async throws {
        let backend = ProbingFakeBackend(trees: [Self.home], screen: Self.screenInfo)
        backend.probeHit = Self.node(.button, label: "Cancel", frame: FakeUI.frame(16, 800, 370, 44), pid: Self.foreignPID)

        let output = try await Self.describe(["--summary"], on: backend)

        #expect(backend.probes == 1)
        #expect(backend.treeReadsAtFirstProbe == 0)
        #expect(output.contains("\n# presented: \"Cancel\"\n"))
    }

    @Test("under a system prompt, describe-ui names it from the one probe at the centre and makes no second read there")
    func describeReusesProbeForSystemPrompt() async throws {
        let backend = ProbingFakeBackend(trees: [SystemPromptCoverTests.signedIn(prompt: true)], screen: Self.screenInfo)
        backend.probeHit = SystemPromptCoverTests.title

        let output = try await Self.describe(["--summary"], on: backend)

        #expect(backend.probes == 1)
        #expect(!backend.hitPoints.contains(UIPoint(x: 201, y: 437)))
        #expect(output.contains("\n# window: Save Password? (system)\n"), "\(output)")
        #expect(!output.contains("# presented"))
    }

    @Test("describe-ui drops a probe that stalls instead of holding its output")
    func describeDropsStalledProbe() async throws {
        let backend = ProbingFakeBackend(trees: [Self.home], screen: Self.screenInfo)
        backend.probeHit = Self.node(.button, label: "Cancel", frame: FakeUI.frame(16, 800, 370, 44), pid: Self.foreignPID)
        backend.probeDelay = .seconds(300)
        let started = Date()

        let output = try await Self.describe(["--summary"], on: backend)

        #expect(Date().timeIntervalSince(started) < 120)
        #expect(!output.contains("# presented"))
    }

    @Test("describe-ui --point and --diff never probe", arguments: [["--point", "20,80"], ["--diff"]])
    func describeVariantsDoNotProbe(arguments: [String]) async throws {
        let backend = ProbingFakeBackend(trees: [Self.home], screen: Self.screenInfo)

        _ = try await Self.describe(arguments, on: backend)

        #expect(backend.probes == 0)
    }

    static func wait(_ arguments: [String], on backend: ProbingFakeBackend, probesOnMiss: Bool) async throws -> WaitOutcome {
        try await Wait.parse(arguments + ["--timeout", "0", "--device", Self.device.rawValue])
            .evaluate(on: DeviceRouter.Route(backend: backend, device: Self.device), logger: OffsiderLogger(), probesOnMiss: probesOnMiss)
    }

    @Test("a wait that misses probes once and explains a stale frame; one that passes, or a batch step, never probes")
    func waitProbesOnlyOnMiss() async throws {
        let missed = ProbingFakeBackend(trees: [Self.staleSheet()])
        missed.probeHit = Self.staleSheet().roots[0].children[1].children[1]
        let outcome = try await Self.wait(["--id", "sheet-host"], on: missed, probesOnMiss: true)
        #expect(missed.probes == 1)
        #expect(outcome.reason == "off screen at (0, 10000) 402x874 (likely a stale frame: the screen's centre is inside id=sheet-host; check a screenshot)")

        let passed = ProbingFakeBackend(trees: [Self.home])
        _ = try await Self.wait(["--id", "home-open"], on: passed, probesOnMiss: true)
        #expect(passed.probes == 0)

        let batchStep = ProbingFakeBackend(trees: [Self.home])
        _ = try await Self.wait(["--id", "missing"], on: batchStep, probesOnMiss: false)
        #expect(batchStep.probes == 0)
    }

    @Test("an assert that fails probes once and names what is presented")
    func assertProbesOnFailure() async throws {
        let backend = ProbingFakeBackend(trees: [Self.home])
        backend.probeHit = Self.node(.button, label: "Cancel", frame: FakeUI.frame(16, 800, 370, 44), pid: Self.foreignPID)

        let outcome = try await Assert.parse(["--id", "picker-done", "--device", Self.device.rawValue])
            .evaluate(on: DeviceRouter.Route(backend: backend, device: Self.device), logger: OffsiderLogger(), probesOnMiss: true)

        #expect(backend.probes == 1)
        #expect(outcome.reason == #"not found; presented: "Cancel""#)
    }

    @Test("a tap, with or without --verify-id polling for its effect, never probes")
    func tapNeverProbes() async throws {
        let done = Self.screen([Self.node(.text, id: "done", label: "Done", frame: FakeUI.frame(20, 100, 350, 44))])
        for arguments in [["--id", "home-open"], ["--id", "home-open", "--verify-id", "done"]] {
            let backend = ProbingFakeBackend(trees: [Self.home, done], advanceTreeOnInput: true)
            let fixture = try TreeCacheFixture()
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await fixture.run {
                    try await Tap.parse(arguments + ["--no-settle", "--device", Self.device.rawValue])
                        .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: VerifyProgress(), logger: OffsiderLogger())
                }
            }
            #expect(backend.session.calls.count == 1)
            #expect(backend.probes == 0)
        }
    }
}
