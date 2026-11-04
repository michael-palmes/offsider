import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Taps that used to land on the wrong thing and report success.
@Suite("Cover and verify")
@MainActor
struct CoverAndVerifyTests {
    static let ios = DeviceID(rawValue: "fake-device", platform: .ios)
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)

    /// Runs `tap` as an agent and returns what it wrote to stdout and stderr.
    @discardableResult
    static func tap(_ arguments: [String], on backend: FakeDeviceBackend, device: DeviceID = ios, progress: VerifyProgress? = nil) async throws -> (out: String, err: String) {
        let capture = ConsoleCapture()
        try await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await TypeIntoTests.quiet {
                    try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
                        .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: progress, logger: OffsiderLogger())
                }
            }
        }
        return (capture.out, capture.err)
    }

    // MARK: The floating dev menu button

    /// The button's icon, as Android lists it in Expo's Compose host, over a row whose point is inside its circle but outside its icon.
    static func androidGearScreen(rowX: Double = 250, rowWidth: Double = 140) -> UITree {
        let icon = FakeUI.node(.image, label: "Tools", frame: FakeUI.frame(320, 600, 26, 26), platform: .android)
        let host = TapCoverTests.classed(
            FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: .android, drawingOrder: 2, children: [icon]),
            ExpoDevLauncher.composeHostClass
        )
        let row = FakeUI.node(.button, id: "filter-all", label: "Everything", frame: FakeUI.frame(rowX, 610, rowWidth, 40), platform: .android, drawingOrder: 1)
        return FakeUI.tree(platform: .android, [host, row])
    }

    @Test("the dev menu button's whole circle takes a tap its 26 pt icon leaves out, so the tap is refused with the drag that moves it, and nothing is sent")
    func gearCircleRefusesOnAndroid() async {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.androidGearScreen()])

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "filter-all"], on: backend, device: Self.android) }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.evidence == .devMenuTouchArea)
        #expect(error?.coveredBy?.label == "Tools")
        #expect(error?.userFacingDescription.contains("under the dev menu button") == true)
        #expect(error?.userFacingDescription.contains("Nothing was sent.") == true)
        #expect(error?.hint == "offsider drag --start-x 333 --start-y 613 --end-x 333 --end-y 373 --duration 0.8 --hold-end 300 --device emulator-5554")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("the drag it suggests stays on a short screen")
    func dragStaysOnScreen() throws {
        let button = FakeUI.node(.image, label: "Tools", frame: FakeUI.frame(320, 170, 26, 26))
        let hint = try #require(TapCover.dragClear(button, viewport: FakeUI.frame(0, 0, 874, 402), device: Self.android))
        #expect(hint.contains("--end-y 362"), "\(hint)")
    }

    @Test("--allow-covered taps through the button's circle, and a point past the circle is clear")
    func gearCircleLimits() async throws {
        let through = FakeDeviceBackend(platform: .android, trees: [Self.androidGearScreen()])
        try await Self.tap(["--id", "filter-all", "--allow-covered"], on: through, device: Self.android)
        #expect(through.session.calls.count == 1)

        let beyond = FakeDeviceBackend(platform: .android, trees: [Self.androidGearScreen(rowX: 200, rowWidth: 60)])
        try await Self.tap(["--id", "filter-all"], on: beyond, device: Self.android)
        #expect(beyond.session.calls.count == 1)
    }

    @Test("the button itself can be tapped, and an app's own Tools image outside Expo's host covers nothing past its frame")
    func gearItselfAndLookalike() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.androidGearScreen()])
        try await Self.tap(["--label", "Tools"], on: backend, device: Self.android)
        #expect(backend.session.calls.count == 1)

        let icon = FakeUI.node(.image, label: "Tools", frame: FakeUI.frame(320, 600, 26, 26), platform: .android)
        let row = FakeUI.node(.button, id: "filter-all", label: "Everything", frame: FakeUI.frame(250, 610, 140, 40), platform: .android)
        let own = FakeDeviceBackend(platform: .android, trees: [FakeUI.tree(platform: .android, [row, icon])])
        try await Self.tap(["--id", "filter-all"], on: own, device: Self.android)
        #expect(own.session.calls.count == 1)
    }

    /// The gear as an iOS simulator lists it, in a screen-sized view of its own, over a control the tree lists after it.
    static func iosGearScreen(_ row: UINode) -> UITree {
        let gear = FakeUI.node(.image, id: "gearshape.fill", label: "Gear Shape, Filled", frame: FakeUI.frame(320, 600, 26, 26))
        return FakeUI.tree([FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [gear]), row])
    }

    @Test("on a simulator whose hit-test answers with the row beside the icon, the circle still refuses")
    func gearCircleBeatsCleanHitOnIOS() async {
        let row = FakeUI.node(.button, id: "filter-all", label: "Everything", frame: FakeUI.frame(312, 610, 42, 33))
        let backend = HitTestingFakeBackend(trees: [Self.iosGearScreen(row)])
        backend.hits = { _ in row }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "filter-all"], on: backend) }

        #expect(error?.coveredBy?.evidence == .devMenuTouchArea)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a wide row whose centre is under the circle is tapped beside it, once a hit-test there finds the row")
    func gearLeavesPartOfWideRow() async throws {
        let row = FakeUI.node(.button, id: "row", label: "Row", frame: FakeUI.frame(0, 592, 666, 41))
        let backend = HitTestingFakeBackend(trees: [Self.iosGearScreen(row)])
        backend.hits = { _ in row }

        let (_, stderr) = try await Self.tap(["--id", "row"], on: backend)

        guard case .perform(.tapAt(let x, _))? = backend.session.calls.first else {
            Issue.record("no tap sent: \(backend.session.calls)")
            return
        }
        #expect(x < 308 || x > 358)
        #expect(stderr.contains("tapping the part that shows"), "\(stderr)")
    }

    @Test("a control's own gear icon, inside its frame, covers nothing")
    func controlsOwnGearIcon() async throws {
        let gear = FakeUI.node(.image, id: "gearshape.fill", label: "Gear Shape, Filled", frame: FakeUI.frame(350, 60, 26, 26))
        let settings = FakeUI.node(.button, id: "settings", label: "Settings", frame: FakeUI.frame(340, 50, 46, 46), children: [gear])
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([settings])])

        try await Self.tap(["--id", "settings", "--fail-if-covered"], on: backend)

        #expect(backend.session.calls.count == 1)
    }

    // MARK: A sheet over a screen

    /// A native sheet's scroll view over a pushed page whose spinner sits where the sheet's button is.
    static func sheetOverPage() -> (tree: UITree, submit: UINode) {
        let home = FakeUI.node(.group, id: "home", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Home", frame: FakeUI.frame(60, 70, 282, 22)),
        ])
        let page = FakeUI.node(.group, id: "summary", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Summary", frame: FakeUI.frame(60, 70, 282, 22)),
            FakeUI.node(.button, id: "summary-button", label: "Summary", frame: FakeUI.frame(16, 780, 370, 56)),
            FakeUI.node(.other, id: "spinner", label: "Loading", frame: FakeUI.frame(191, 798, 20, 20)),
        ])
        let submit = FakeUI.node(.button, id: "submit", label: "Submit", frame: FakeUI.frame(16, 780, 370, 56))
        let sheet = FakeUI.node(.group, frame: FakeUI.frame(0, 500, 402, 374), children: [
            FakeUI.node(.scrollView, frame: FakeUI.frame(0, 520, 402, 354), children: [submit]),
        ])
        return (FakeUI.tree([home, page, sheet]), submit)
    }

    @Test("a clean hit-test on a sheet's button stays clean though a spinner on the screen beneath shares its point")
    func cleanHitOnSheet() async throws {
        let (tree, submit) = Self.sheetOverPage()
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in submit }

        let (_, stderr) = try await Self.tap(["--id", "submit", "--fail-if-covered"], on: backend)

        #expect(backend.session.calls.count == 1)
        #expect(!stderr.contains("covered"), "\(stderr)")
    }

    @Test("a clean hit-test on a target beneath a page stays a guess when that page's control holds the point")
    func pageOverTargetKeepsGuess() async {
        let row = ScrollFoldTests.row(12, y: 780)
        let beneath = FakeUI.node(.group, id: "home", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Home", frame: FakeUI.frame(60, 70, 282, 22)),
            FakeUI.node(.scrollView, frame: FakeUI.frame(0, 100, 402, 774), children: [row]),
        ])
        let page = FakeUI.node(.group, id: "details", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Details", frame: FakeUI.frame(60, 70, 282, 22)),
            FakeUI.node(.button, id: "details-action", label: "Act", frame: FakeUI.frame(16, 790, 370, 56)),
        ])
        let tree = FakeUI.tree([beneath, page])
        let viewport = FakeUI.frame(0, 0, 402, 874)
        let verdict = CoverJudge.judge(
            target: row, matched: row, point: UIPoint(x: 201, y: 810),
            candidates: tree.roots[0].flattened().filter { $0.id == "details-action" },
            roots: tree.roots, viewport: viewport, stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: row
        )
        #expect(verdict?.cover.id == "details-action")
    }

    @Test("a footer floating over a scroll view is still a guess, listed either side of it")
    func footerStaysGuess() async {
        let row = ScrollFoldTests.row(12, y: 780)
        let footer = FakeUI.node(.button, id: "menu-footer", label: "Continue", frame: FakeUI.frame(16, 790, 370, 56))
        let scroll = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 100, 402, 774), children: [row])
        for roots in [[footer, scroll], [scroll, footer]] {
            let backend = HitTestingFakeBackend(trees: [FakeUI.tree(roots)])
            backend.hits = { _ in row }
            let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "menu-row-12", "--fail-if-covered"], on: backend) }
            #expect(error?.coveredBy?.id == "menu-footer")
        }
    }

    // MARK: R25

    @Test("on Android a screen-sized group under a dialog sibling is covered, so assert fails and a tap on the group is refused")
    func androidScreenGroupUnderDialog() async throws {
        let home = FakeUI.node(.group, id: "home-screen", frame: FakeUI.frame(0, 0, 402, 874), platform: .android, drawingOrder: 1)
        let dialog = FakeUI.node(.group, frame: FakeUI.frame(40, 300, 322, 280), platform: .android, drawingOrder: 2, children: [
            FakeUI.node(.button, label: "Close", frame: FakeUI.frame(60, 420, 282, 48), platform: .android),
        ])
        let tree = FakeUI.tree(platform: .android, [home, dialog])

        #expect(try TapCoverTests.judge(tree, target: "home-screen", hit: nil)?.isConfident == true)

        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        let route = DeviceRouter.Route(backend: backend, device: Self.android)
        let outcome = try await Assert.parse(["--id", "home-screen", "--device", Self.android.rawValue]).evaluate(on: route, logger: OffsiderLogger())
        #expect(!outcome.met)
    }

    // MARK: A page just left

    /// `Back` from a page that stays in the tree over the next one for its first read, drawn over the tab by Android's order.
    static func poppedPage(leaving: Bool) -> UITree {
        let tab = FakeUI.node(.button, id: "tab-library", label: "Library", frame: FakeUI.frame(0, 790, 201, 49), platform: .android, drawingOrder: 1)
        let leavingPage = FakeUI.node(.button, id: "next-step", label: "Next step", frame: FakeUI.frame(0, 780, 402, 70), platform: .android, drawingOrder: 2)
        return FakeUI.tree(platform: .android, leaving ? [tab, leavingPage] : [tab])
    }

    private func pollPopped(coverSettle: TimeInterval) async throws -> (Polled<TapResolution>, Int) {
        let clock = ScriptedClock()
        var reads = 0
        let device = Self.android
        let tap = try Tap.parse(["--id", "tab-library", "--device", device.rawValue])
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let polled = try await AccessibilityPoller.pollForResolution(
            query: .id("tab-library"), waitTimeout: 0, pollInterval: 0.25, elementType: nil,
            coverCheck: tap.coverCheck(query: .id("tab-library"), backend: backend, device: device),
            coverSettle: coverSettle, logger: OffsiderLogger(), clock: clock.poll
        ) {
            reads += 1
            return Self.poppedPage(leaving: reads == 1)
        }
        return (polled, reads)
    }

    @Test("a cover from the page just left is read again straight after an input, so the tap goes once it has gone")
    func coverSettlesAfterInput() async throws {
        let (polled, reads) = try await pollPopped(coverSettle: TapCover.coverSettle)
        #expect(reads == 2)
        #expect(polled.value.target?.id == "tab-library")
    }

    @Test("straight after an input, a page just left that shows only on a verify tap's second read is waited out, and a tap with none recent refuses")
    func verifySecondReadSettles() async throws {
        func run(inputAge: TimeInterval) async throws -> (calls: Int, error: (any Error)?) {
            let device = DeviceID(rawValue: "fake-device", platform: .android)
            let backend = FakeDeviceBackend(platform: .android, trees: [Self.poppedPage(leaving: false), Self.poppedPage(leaving: true), Self.poppedPage(leaving: false)])
            let fixture = try TreeCacheFixture()
            try fixture.write(fixture.settledRecord(Self.poppedPage(leaving: false), inputAge: inputAge))
            var failure: (any Error)?
            try await fixture.run {
                do {
                    try await Console.$current.withValue(ConsoleCapture().console(out: .agent, err: .agent)) {
                        try await DispatchTracker.$current.withValue(DispatchTracker()) {
                            try await Tap.parse(["--id", "tab-library", "--verify", "--verify-timeout", "0.5", "--retries", "0", "--device", device.rawValue])
                                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: VerifyProgress(), logger: OffsiderLogger())
                        }
                    }
                } catch {
                    failure = error
                }
            }
            return (backend.session.calls.count, failure)
        }

        let recent = try await run(inputAge: 0.3)
        #expect(recent.calls == 1, "\(String(describing: recent.error))")
        let old = try await run(inputAge: 30)
        #expect(old.calls == 0)
        #expect((old.error as? CLIError)?.reason == .targetCovered)
    }

    @Test("with no recent input the same cover refuses on the first read")
    func coverRefusesWithoutInput() async throws {
        await #expect(throws: CLIError.self) { try await self.pollPopped(coverSettle: 0) }
    }

    @Test("the settle applies only within two seconds of an input")
    func coverSettleWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(TapCover.coverSettle(lastInput: now.addingTimeInterval(-0.5), now: now) == 1)
        #expect(TapCover.coverSettle(lastInput: now.addingTimeInterval(-5), now: now) == 0)
        #expect(TapCover.coverSettle(lastInput: nil, now: now) == 0)
    }

    // MARK: tap --dry-run

    @Test("--dry-run finds and judges the target, opens no session and says nothing was sent")
    func dryRunSendsNothing() async throws {
        let screen = FakeUI.tree([FakeUI.node(.button, id: "confirm", label: "Confirm", frame: FakeUI.frame(16, 700, 370, 44))])
        let backend = FakeDeviceBackend(trees: [screen])

        let (stdout, _) = try await Self.tap(["--id", "confirm", "--dry-run"], on: backend)

        #expect(backend.openedSessions.isEmpty)
        #expect(backend.session.calls.isEmpty)
        #expect(stdout == "✓ Dry run: a tap on id=confirm at (201, 722) would reach it. Nothing was sent.\n")
    }

    @Test("--dry-run exits as the tap would on a cover, and on a target that is not there")
    func dryRunRefuses() async {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.androidGearScreen()])
        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "filter-all", "--dry-run"], on: backend, device: Self.android) }
        #expect(error?.reason == .targetCovered)
        #expect(backend.session.calls.isEmpty)

        let empty = FakeDeviceBackend(trees: [FakeUI.tree([])])
        await #expect(throws: ElementResolutionError.self) { try await Self.tap(["--id", "confirm", "--dry-run"], on: empty) }
        #expect(empty.openedSessions.isEmpty)
    }

    @Test("--dry-run says what it would do beside a cover, not that it is tapping")
    func dryRunWording() async throws {
        let row = FakeUI.node(.button, id: "row", label: "Row", frame: FakeUI.frame(0, 592, 666, 41))
        let backend = HitTestingFakeBackend(trees: [Self.iosGearScreen(row)])
        backend.hits = { _ in row }

        let (_, stderr) = try await Self.tap(["--id", "row", "--dry-run"], on: backend)

        #expect(stderr.contains("would tap the part that shows"), "\(stderr)")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--dry-run --json reports dispatched no with the point it would tap")
    func dryRunJSON() async throws {
        let screen = FakeUI.tree([FakeUI.node(.button, id: "confirm", label: "Confirm", frame: FakeUI.frame(16, 700, 370, 44))])
        let backend = FakeDeviceBackend(trees: [screen])
        let capture = ConsoleCapture()
        let tap = try Tap.parse(["--id", "confirm", "--dry-run", "--json", "--no-settle", "--device", Self.ios.rawValue])

        try await DispatchTracker.$current.withValue(DispatchTracker()) {
            try await InputOutput.reporting(command: "tap", target: "id=confirm", json: true, console: capture.console(out: .agent, err: .agent)) { details in
                try await TypeIntoTests.quiet {
                    try await tap.execute(on: DeviceRouter.Route(backend: backend, device: Self.ios), progress: nil, logger: OffsiderLogger(), details: details)
                }
            }
        }

        let line = capture.out
        #expect(line.contains(#""dispatched":"no""#), "\(line)")
        #expect(line.contains(#""dryRun":true"#), "\(line)")
        #expect(line.contains(#""x":201"#), "\(line)")
    }

    @Test("--dry-run takes a selector and no verify", arguments: [
        (["-x", "10", "-y", "10", "--dry-run"], "--dry-run checks an element; use it with --id, --label, --label-contains or --value."),
        (["--id", "a", "--dry-run", "--verify"], "--dry-run sends nothing, so there is nothing to verify."),
    ])
    func dryRunValidation(arguments: [String], message: String) {
        let error = #expect(throws: (any Error).self) { try Tap.parse(arguments + ["--device", "emulator-5554"]) }
        #expect(error.map { Tap.message(for: $0) } == message)
    }

    @Test("a batch step refuses tap --dry-run before anything is sent, as a step would otherwise tap")
    func dryRunInBatch() async {
        let screen = FakeUI.tree(platform: .android, [FakeUI.node(.button, id: "confirm", label: "Confirm", frame: FakeUI.frame(16, 700, 370, 44), platform: .android)])
        let backend = FakeDeviceBackend(platform: .android, trees: [screen])
        let context = BatchContext(backend: backend, device: Self.android, axCachePolicy: .perStep, typeSubmissionMode: .chunked, typeChunkSize: 200)

        await #expect(throws: (any Error).self) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await TypeIntoTests.quiet {
                    _ = try await Batch.runSteps(["tap --id confirm --dry-run"], context: context, session: backend.session, continueOnError: false, output: TypeIntoTests.quietOutput(), logger: OffsiderLogger())
                }
            }
        }
        #expect(backend.session.calls.isEmpty)
    }

    // MARK: R6 and R41

    static func save(y: Double = 300) -> UINode {
        FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, y, 370, 44))
    }

    static let tabBarFrame = FakeUI.frame(0, 790, 402, 84)
    static func tabButton() -> UINode { FakeUI.node(.button, id: "tab", label: "Tab", frame: tabBarFrame) }

    @Test("a verify tap whose target comes under a cover by the second read refuses, sending nothing")
    func verifyRechecksCoverOnSecondRead() async {
        let clear = FakeUI.tree([Self.save()])
        let covered = FakeUI.tree([Self.save(y: 800), Self.tabButton()])
        let backend = HitTestingFakeBackend(trees: [clear, covered])
        backend.hits = { point in Self.tabBarFrame.contains(point) ? Self.tabButton() : Self.save() }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5"], on: backend, progress: VerifyProgress()) }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "tab")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a verify tap whose still target gets a cover by the second read refuses too")
    func verifyRechecksStillTarget() async {
        let banner = FakeUI.node(.button, id: "banner", label: "Banner", frame: FakeUI.frame(0, 280, 402, 90))
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([Self.save()]), FakeUI.tree([Self.save(), banner])])
        backend.hits = { _ in banner }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5"], on: backend, progress: VerifyProgress()) }

        #expect(error?.coveredBy?.id == "banner")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a verify tap whose target has gone by the second read is not sent to where it was")
    func verifyRefusesGoneTarget() async {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([Self.save()]), FakeUI.tree([FakeUI.node(.header, label: "Next", frame: FakeUI.frame(60, 70, 282, 22))])])

        await #expect(throws: ElementResolutionError.self) { try await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5"], on: backend, progress: VerifyProgress()) }

        #expect(backend.session.calls.isEmpty)
    }

    @Test("a verify tap whose target moved goes to where it is now, a part beside a cover included")
    func verifyTapsWhereItIsNow() async throws {
        let moved = FakeDeviceBackend(trees: [FakeUI.tree([Self.save()]), FakeUI.tree([Self.save(y: 340)])], advanceTreeOnInput: false)

        _ = try? await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5", "--retries", "0"], on: moved, progress: VerifyProgress())

        #expect(moved.session.calls.first == .perform(.tapAt(x: 201, y: 362)))
    }

    @Test("a verify tap on an element only the filled read holds is resolved again from a filled read, not refused as gone")
    func verifyRefillsHiddenTarget() async {
        let backend = FillingBackend(plain: FakeUI.tree([FakeUI.node(.header, label: "Next", frame: FakeUI.frame(60, 70, 282, 22))])) { _ in [Self.save()] }

        _ = try? await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5", "--retries", "0"], on: backend, progress: VerifyProgress())

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 322))])
    }

    @Test("with --fail-if-covered on Android, a hidden page that arrives by the verifier's read refuses the tap, as it would on the first read")
    func verifyReadsHiddenCoverAgain() async {
        let target = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 300, 370, 44), platform: .android, drawingOrder: 1)
        let cover = FakeUI.node(.button, id: "hidden-cover", label: "Cover", frame: FakeUI.frame(0, 280, 402, 90), platform: .android, drawingOrder: 2)
        let backend = FillingBackend(plain: FakeUI.tree(platform: .android, [target])) { fill in fill == 1 ? [] : [cover] }

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "save", "--fail-if-covered", "--verify", "--verify-timeout", "0.5", "--retries", "0"], on: backend, device: Self.android, progress: VerifyProgress())
        }

        #expect(error?.coveredBy?.id == "hidden-cover")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a verify tap whose second read comes back empty is sent to the first read's point, not refused as gone")
    func verifyEmptySecondRead() async {
        let empty = FakeUI.tree([])
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([Self.save()]), empty, FakeUI.tree([Self.save()])])

        _ = try? await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5", "--retries", "0"], on: backend, progress: VerifyProgress())

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 322))])
    }

    @Test("the frozen display digest ignores a label ticking beneath a full-screen page, and sees one on the page in front")
    func frozenDigestSkipsBeneath() {
        func pushed(beneath: String, front: String) -> UITree {
            FakeUI.tree([
                FakeUI.node(.group, id: "home", frame: FakeUI.frame(0, 0, 402, 874), children: [
                    FakeUI.node(.header, label: "Home", frame: FakeUI.frame(60, 70, 282, 22)),
                    FakeUI.node(.text, label: beneath, frame: FakeUI.frame(16, 300, 370, 22)),
                ]),
                FakeUI.node(.group, id: "details", frame: FakeUI.frame(0, 0, 402, 874), children: [
                    FakeUI.node(.header, label: "Details", frame: FakeUI.frame(60, 70, 282, 22)),
                    FakeUI.node(.text, label: front, frame: FakeUI.frame(16, 600, 370, 22)),
                ]),
            ])
        }
        let base = FrozenDisplayRecord.digest(tree: pushed(beneath: "12:01", front: "Ready"))
        #expect(FrozenDisplayRecord.digest(tree: pushed(beneath: "12:02", front: "Ready")) == base)
        #expect(FrozenDisplayRecord.digest(tree: pushed(beneath: "12:01", front: "Done")) != base)
    }

    @Test("the spinner says what a dry run does")
    func dryRunSpinner() throws {
        #expect(try Tap.parse(["--id", "a", "--dry-run", "--device", Self.android.rawValue]).progressLabel == "Checking id=a")
        #expect(try Tap.parse(["--id", "a", "--device", Self.android.rawValue]).progressLabel == "Tapping id=a")
    }

    @Test("a guess about the same cover warns once though each read is judged")
    func verifyWarnsOnce() async throws {
        let banner = FakeUI.node(.button, id: "banner", label: "Banner", frame: FakeUI.frame(0, 280, 402, 90))
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([Self.save(), banner])])

        let capture = ConsoleCapture()
        _ = try? await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await TypeIntoTests.quiet {
                    try await Tap.parse(["--id", "save", "--verify", "--verify-timeout", "0.5", "--retries", "0", "--no-settle", "--device", Self.ios.rawValue])
                        .execute(on: DeviceRouter.Route(backend: backend, device: Self.ios), progress: VerifyProgress(), logger: OffsiderLogger())
                }
            }
        }

        #expect(backend.session.calls.count == 1)
        #expect(capture.err.components(separatedBy: "may be covered by").count == 2, "\(capture.err)")
    }

    @Test("two matches, one covered, on a screen that never changes: the reached one is tapped twice, with no note that the screen did not settle")
    func verifyRetriesAmongJudgedMatches() async throws {
        let first = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 200, 370, 44))
        let second = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 500, 370, 44))
        let chip = FakeUI.node(.button, id: "chip", label: "Chip", frame: FakeUI.frame(0, 180, 402, 80))
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([first, second, chip])])
        backend.hits = { point in point.y < 300 ? chip : second }

        var failure: (any Error)?
        var stderr = ""
        do {
            stderr = try await Self.tap(["--id", "save", "--verify", "--verify-timeout", "0.5"], on: backend, progress: VerifyProgress()).err
        } catch {
            failure = error
        }

        #expect(failure as? ExitCode == ExitCode(5))
        #expect(backend.session.calls.count == 2)
        #expect(!stderr.contains("did not settle"))
    }

    // MARK: R39, R40, R42, R59, R75

    /// A row half under a tab bar, with a labelled image spread behind everything as a sibling.
    static func rowOverBackdrop() -> (tree: UITree, row: UINode, bar: UINode) {
        let backdrop = FakeUI.node(.image, label: "Backdrop", frame: FakeUI.frame(0, 0, 402, 874))
        let row = FakeUI.node(.button, id: "row-12", label: "Row 12", frame: FakeUI.frame(0, 775, 402, 56))
        let bar = FakeUI.node(.group, id: "tab-bar", frame: FakeUI.frame(0, 790, 402, 84), children: [
            FakeUI.node(.button, id: "tab-home", label: "Home", frame: FakeUI.frame(0, 790, 201, 49)),
        ])
        return (FakeUI.tree([backdrop, row, bar]), row, bar)
    }

    @Test("wait and tap agree on a row beside a tab bar, though a backdrop lies behind it, and centres are read before parts")
    func waitAgreesWithTapBesideCover() async throws {
        let (tree, row, bar) = Self.rowOverBackdrop()
        func simulator() -> HitTestingFakeBackend {
            let backend = HitTestingFakeBackend(trees: [tree])
            backend.hits = { point in point.y >= 790 ? bar : row }
            return backend
        }

        let waiting = simulator()
        let route = DeviceRouter.Route(backend: waiting, device: Self.ios)
        let outcome = try await Wait.parse(["--id", "row-12", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(outcome.met, "\(outcome.reason)")
        #expect(waiting.hitPoints.map(\.y) == [803, 782.5])

        let tapping = simulator()
        try await Self.tap(["--id", "row-12"], on: tapping)
        #expect(tapping.session.calls == [.perform(.tapAt(x: 201, y: 782.5))])
    }

    @Test("an element whose centre is clear costs one read, and one read of a covered element's part stays within the limit")
    func partsReadOnlyWhenCovered() async throws {
        let (tree, row, _) = Self.rowOverBackdrop()
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in row }
        let route = DeviceRouter.Route(backend: backend, device: Self.ios)

        _ = try await Wait.parse(["--id", "row-12", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)

        #expect(backend.hitTests == 1)
    }

    @Test("a screen of covered elements never reads more points than the limit")
    func partsStayWithinHitLimit() async throws {
        let cover = FakeUI.node(.button, id: "cover", label: "Cover", frame: FakeUI.frame(0, 0, 402, 400))
        let rows = (0..<20).map { FakeUI.node(.button, id: "row-\($0)", label: "Row \($0)", frame: FakeUI.frame(0, Double($0) * 20, 402, 200)) }
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree(rows + [cover])])
        backend.hits = { _ in cover }

        _ = try await OnScreenRuleTests.describe(["--summary"], on: backend, device: Self.ios)

        #expect(backend.hitTests <= FrontJudge.hitLimit, "\(backend.hitTests)")
    }

    @Test("an empty screen-sized answer to a quick read is not reused, so the tap asks again with the retrying hit-test and refuses the cover it finds")
    func emptyQuickAnswerIsReadAgain() async {
        let home = FakeUI.node(.group, id: "home", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Home", frame: FakeUI.frame(60, 70, 282, 22)),
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 200, 370, 44)),
        ])
        let chip = FakeUI.node(.button, id: "chip", label: "Chip", frame: FakeUI.frame(0, 490, 402, 70))
        let details = FakeUI.node(.group, id: "details", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Details", frame: FakeUI.frame(60, 70, 282, 22)),
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 500, 370, 44)),
            chip,
        ])
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([home, details])])
        backend.quickHits = { _ in FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874)) }
        backend.hits = { _ in chip }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "save"], on: backend) }

        #expect(error?.coveredBy?.id == "chip")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a clean quick read is reused, so the tap reads no second point")
    func cleanQuickAnswerIsReused() async throws {
        let (tree, inbox, chip) = Self.drawerCopies()
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { point in chip.frame?.contains(point) == true ? chip : inbox }

        try await Self.tap(["--id", "menu-inbox"], on: backend)

        #expect(backend.hitTests == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 140, y: 622))])
    }

    @Test("a tap moved beside a cover never presses another control inside a group target; it refuses")
    func movedTapSparesInnerControls() async {
        let delete = FakeUI.node(.button, id: "card-delete", label: "Delete", frame: FakeUI.frame(16, 520, 370, 90))
        let card = FakeUI.node(.group, id: "card", frame: FakeUI.frame(0, 500, 402, 300), children: [delete])
        let footer = FakeUI.node(.group, id: "footer", frame: FakeUI.frame(0, 645, 402, 215), children: [
            FakeUI.node(.button, id: "footer-action", label: "Act", frame: FakeUI.frame(16, 800, 370, 44)),
        ])
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([card, footer])])
        backend.hits = { point in point.y >= 645 ? footer : delete }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "card"], on: backend) }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "footer")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a row's own text beside the cover still counts as the row")
    func movedTapTakesInnerText() async throws {
        let (tree, row, bar) = Self.rowOverBackdrop()
        let text = FakeUI.node(.text, label: "Row 12", frame: FakeUI.frame(16, 776, 300, 14))
        var withText = row
        withText.children = [text]
        var nodes = tree.roots[0].children
        nodes[1] = withText
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree(nodes)])
        backend.hits = { point in point.y >= 790 ? bar : text }

        try await Self.tap(["--id", "row-12"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 782.5))])
    }

    static func wideSwitch() -> UINode {
        FakeUI.node(.switch, id: "switch-row", label: "Alerts", value: "0", frame: FakeUI.frame(16, 770, 370, 44))
    }

    @Test("a wide switch half under a bar keeps its knob's x in the part that shows")
    func wideSwitchKeepsKnob() async throws {
        let bar = FakeUI.node(.button, id: "bar", label: "Bar", frame: FakeUI.frame(0, 790, 402, 84))
        let toggle = Self.wideSwitch()
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([toggle, bar])])
        backend.hits = { point in point.y >= 790 ? bar : toggle }

        try await Self.tap(["--id", "switch-row"], on: backend)

        #expect(backend.session.calls.count > 0)
        let parts = backend.session.calls.compactMap { call -> Double? in
            if case .physicalTap(let x, _, _, _) = call { return x }
            if case .perform(.tapAt(let x, _)) = call { return x }
            return nil
        }
        #expect(parts == [355], "\(backend.session.calls)")
    }

    @Test("a button over a wide switch's knob at full height leaves no part with the knob, so the tap is refused")
    func wideSwitchKnobCovered() async {
        let floating = FakeUI.node(.button, id: "floating", label: "Floating", frame: FakeUI.frame(320, 760, 80, 64))
        let toggle = Self.wideSwitch()
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([toggle, floating])])
        backend.hits = { point in point.x >= 320 ? floating : toggle }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "switch-row"], on: backend) }

        #expect(error?.coveredBy?.id == "floating")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a batch tap on a simulator hit-tests several matches, as a lone tap does, and taps the one a touch reaches")
    func batchTapReadsFront() async throws {
        let (trees, inbox, chip) = Self.drawerCopies()
        let backend = HitTestingFakeBackend(trees: [trees])
        backend.hits = { point in chip.frame?.contains(point) == true ? chip : inbox }
        let context = BatchContext(backend: backend, device: Self.ios, axCachePolicy: .perStep, typeSubmissionMode: .chunked, typeChunkSize: 200)

        _ = try await DispatchTracker.$current.withValue(DispatchTracker()) {
            try await TypeIntoTests.quiet {
                try await Batch.runSteps(["tap --id menu-inbox"], context: context, session: backend.session, continueOnError: false, output: TypeIntoTests.quietOutput(), logger: OffsiderLogger())
            }
        }

        let tapped = backend.session.calls.compactMap { call -> Double? in
            if case .perform(.tapAt(_, let y)) = call { return y }
            return nil
        }
        #expect(tapped == [622], "\(backend.session.calls)")
    }

    /// Two copies of an id at different points, one under a chip.
    static func drawerCopies() -> (UITree, UINode, UINode) {
        let hidden = FakeUI.node(.button, id: "menu-inbox", label: "Inbox", frame: FakeUI.frame(16, 200, 248, 44))
        let inbox = FakeUI.node(.button, id: "menu-inbox", label: "Inbox", frame: FakeUI.frame(16, 600, 248, 44))
        let chip = FakeUI.node(.button, id: "chip", label: "Chip", frame: FakeUI.frame(0, 190, 402, 70))
        return (FakeUI.tree([hidden, inbox, chip]), inbox, chip)
    }

    // MARK: R17

    @Test("a row past the edge of its scroll view is off screen to wait, assert, --verify-id and --on-screen, as it is to tap")
    func rowPastScrollEdgeAgrees() async throws {
        let tree = ScrollFoldTests.pinnedFooter(rows: [ScrollFoldTests.row(12, y: 760)])
        let route = DeviceRouter.Route(backend: HitTestingFakeBackend(trees: [tree]), device: Self.ios)

        let waited = try await Wait.parse(["--id", "menu-row-12", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(!waited.met)
        #expect(waited.reason == "past the edge of its scroll view, so a tap would not reach it")

        let asserted = try await Assert.parse(["--id", "menu-row-12", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger())
        #expect(!asserted.met)

        var judged = tree
        await FrontJudge.read(matching: [.id("menu-row-12")], elementType: nil, in: &judged, backend: route.backend, device: Self.ios, everyPoint: true)
        #expect(Verifier.placement(of: "menu-row-12", in: judged) == .hidden("past the edge of its scroll view"))

        let onScreen = try await OnScreenRuleTests.describe(["--on-screen", "--flat"], on: HitTestingFakeBackend(trees: [tree]), device: Self.ios)
        #expect(!onScreen.contains("menu-row-12"), "\(onScreen)")
        let summary = try await OnScreenRuleTests.describe(["--summary"], on: HitTestingFakeBackend(trees: [tree]), device: Self.ios)
        #expect(!summary.contains(#"button "Menu Row 12""#), "\(summary)")
        #expect(summary.contains("menu-row-12") && summary.contains("below"), "\(summary)")

        let refused = await #expect(throws: ElementResolutionError.self) { try await Self.tap(["--id", "menu-row-12"], on: HitTestingFakeBackend(trees: [tree])) }
        #expect(refused?.reason == .targetOffScreen)
    }

    @Test("a row past the top of its scroll view folds into a run above, not below")
    func rowPastTopFoldsAbove() async throws {
        let scroll = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 200, 402, 500), children: [
            FakeUI.node(.group, frame: FakeUI.frame(0, 100, 402, 1200), children: [ScrollFoldTests.row(1, y: 120)]),
        ])
        let summary = try await OnScreenRuleTests.describe(["--summary"], on: HitTestingFakeBackend(trees: [FakeUI.tree([scroll])]), device: Self.ios)
        #expect(summary.contains("[off-screen above]"), "\(summary)")
    }

    @Test("a row that shows above its scroll view's fold stays on screen")
    func rowStraddlingFoldStays() async throws {
        let tree = ScrollFoldTests.pinnedFooter(rows: [ScrollFoldTests.row(11, y: 720)])
        let route = DeviceRouter.Route(backend: HitTestingFakeBackend(trees: [tree]), device: Self.ios)
        let waited = try await Wait.parse(["--id", "menu-row-11", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(waited.met)
    }

    // MARK: R104

    @Test("--gone met through a cover says what hides the element, on both platforms, and through no match says gone")
    func goneNamesTheCover() async throws {
        for (backend, device) in OnScreenRuleTests.backends() {
            let route = DeviceRouter.Route(backend: backend, device: device)
            let wait = try Wait.parse(["--id", "menu-inbox", "--gone", "--timeout", "0", "--device", device.rawValue])
            let waited = try await wait.evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
            #expect(waited.met)
            #expect(waited.goneBecause == #"under button "Filter Chip" (16, 180) 160x44"#, "\(device.platform)")
            #expect(wait.successLine(waited).hasPrefix(#"✓ --id 'menu-inbox' is not on screen: under button "Filter Chip" (16, 180) 160x44"#))

            let assert = try Assert.parse(["--id", "menu-inbox", "--gone", "--device", device.rawValue])
            let asserted = try await assert.evaluate(on: route, logger: OffsiderLogger())
            #expect(assert.successLine(asserted) == #"✓ --id 'menu-inbox' is not on screen: under button "Filter Chip" (16, 180) 160x44"#)

            let absent = try Assert.parse(["--id", "no-such-row", "--gone", "--device", device.rawValue])
            let none = try await absent.evaluate(on: route, logger: OffsiderLogger())
            #expect(absent.successLine(none) == "✓ --id 'no-such-row' is gone")
        }
    }

    @Test("--gone's success line masks what it quotes from the screen, as a failure line does")
    func goneLineIsRedacted() throws {
        let wait = try Wait.parse(["--id", "row", "--gone", "--timeout", "0", "--device", Self.android.rawValue])
        let assert = try Assert.parse(["--id", "row", "--gone", "--device", Self.android.rawValue])
        var outcome = WaitOutcome(met: true, elapsed: 0, reason: "")
        outcome.goneBecause = #"under text "Your code is 482913""#
        #expect(!wait.successLine(outcome).contains("482913"))
        #expect(!assert.successLine(outcome).contains("482913"))
    }

    @Test("a --gone dwell carries the cover into its reason, as JSON reads it")
    func goneDwellKeepsReason() async throws {
        let clock = ScriptedClock()
        let tree = OnScreenRuleTests.closedDrawer(platform: .android)
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: [tree]), device: Self.android)
        let wait = try Wait.parse(["--id", "menu-inbox", "--gone", "--timeout", "2", "--device", Self.android.rawValue])

        let outcome = try await wait.evaluate(on: route, logger: OffsiderLogger(), clock: clock.poll)

        #expect(outcome.met)
        #expect(outcome.reason.hasPrefix("gone for "), "\(outcome.reason)")
        #expect(outcome.reason.contains(#": under button "Filter Chip""#), "\(outcome.reason)")
    }
}

/// A plain read that leaves out what `hidden` gives for each fill, counted from 1.
@MainActor
private final class FillingBackend: FakeDeviceBackend, TreeGapFilling {
    private let hidden: (Int) -> [UINode]
    private var fills = 0

    init(plain: UITree, hidden: @escaping (Int) -> [UINode]) {
        self.hidden = hidden
        super.init(platform: plain.platform, trees: [plain])
    }

    func startGapSamples(on id: DeviceID) async -> GapSamples? { nil }

    func fillingGaps(in tree: UITree, on id: DeviceID, samples: GapSamples?) async -> UITree {
        fills += 1
        let added = hidden(fills)
        guard !added.isEmpty else { return tree }
        var filled = tree
        filled.roots[0].children += added
        filled.filledFromGaps = added.count
        return filled
    }
}
