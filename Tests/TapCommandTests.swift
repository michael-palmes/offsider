import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Tap command")
@MainActor
struct TapCommandTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private static func sheetScreen(applyY: Double) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, applyY, 350, 44)),
        ])
    }

    /// Without `settle`, the transition guard is off, so read counts show only what the test is about.
    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend, settle: Bool = false) async throws {
        try await Tap.parse(arguments + (settle ? [] : ["--no-settle"]) + ["--device", device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
    }

    @Test("a coordinate outside the reported screen gets a warning; one inside, or with no screen, does not")
    func coordinateOffScreenWarning() {
        let screen = UISize(width: 402, height: 874)
        #expect(Tap.offScreenWarning(x: 500, y: 100, screen: screen) == "Warning: (500, 100) is outside the 402x874 screen; the tap may do nothing.")
        #expect(Tap.offScreenWarning(x: 200, y: 100, screen: screen) == nil)
        #expect(Tap.offScreenWarning(x: 500, y: 100, screen: nil) == nil)
    }

    @Test("a coordinate tap off the screen still taps; the warning never refuses", arguments: [100.0, 500.0])
    func coordinateTapNeverRefuses(x: Double) async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 600)])

        try await Self.tap(["-x", String(x), "-y", "100"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: x, y: 100))])
    }

    @Test("an empty selector on tap is a validation error, not a not-found run", arguments: ["--id", "--label", "--value"])
    func emptySelectorRejected(flag: String) {
        #expect {
            _ = try Tap.parse([flag, "  ", "--device", Self.device.rawValue])
        } throws: { error in
            Tap.message(for: error) == "\(flag) must not be empty."
        }
    }

    @Test("a selector tap with --no-settle on iOS reads the tree once and converts the point with that tree")
    func selectorTapReadsTreeOnce() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 600)])

        try await Self.tap(["--id", "apply"], on: backend)

        #expect(backend.treeReads == 1)
        #expect(backend.coordinateCalls.map(\.hadTree) == [true])
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("an off-screen selector tap fails and sends no input")
    func offScreenTapSendsNothing() async {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)])

        let error = await #expect(throws: ElementResolutionError.self) {
            try await Self.tap(["--id", "apply"], on: backend)
        }

        #expect(error?.isOffScreen == true)
        #expect(backend.openedSessions.isEmpty)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--allow-offscreen taps an off-screen element anyway")
    func allowOffscreenTaps() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)])

        try await Self.tap(["--id", "apply", "--allow-offscreen"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 10722))])
    }

    /// The fake's point read returns the deepest node by sibling order, so listing the banner last puts it on top.
    private static func bannerScreen(bannerOnTop: Bool = true) -> UITree {
        let banner = AccessibilityTargetResolverTests.banner
        let tabBar = AccessibilityTargetResolverTests.tabBar()
        return FakeUI.tree(width: 402, height: 874, bannerOnTop ? [tabBar, banner] : [banner, tabBar])
    }

    @Test("a cover a simulator's hit-test finds refuses with target_covered, naming it in coveredBy, and sends nothing")
    func hitTestedCoverRefuses() async {
        let backend = HitTestingFakeBackend(trees: [Self.bannerScreen()])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "tab-search"], on: backend)
        }

        let label = AccessibilityTargetResolverTests.bannerLabel
        #expect(error?.reason == .targetCovered)
        #expect(error?.userFacingDescription.hasPrefix("--id 'tab-search' at (201, 814.5) is covered by other '\(label)' (0, 767) 402x107 (a hit-test at the point found it), so the tap would land on it. Nothing was sent.") == true)
        #expect(error?.coveredBy == CoverReport(role: "other", id: "banner", label: label, frame: FakeUI.frame(0, 767, 402, 107), screen: nil, evidence: .hitTest))
        #expect(backend.hitTests == 1)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--allow-covered taps through a confident cover")
    func allowCoveredTaps() async throws {
        let backend = HitTestingFakeBackend(trees: [Self.bannerScreen()])

        try await Self.tap(["--id", "tab-search", "--allow-covered"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])
    }

    @Test("--allow-covered and --fail-if-covered together are a usage error")
    func allowAndFailExclusive() {
        let error = #expect(throws: (any Error).self) { try Tap.parse(["--id", "a", "--allow-covered", "--fail-if-covered", "--device", "emulator-5554"]) }
        #expect(error.map { Tap.exitCode(for: $0) } == .validationFailure)
        #expect(error.map { Tap.message(for: $0) } == "Use only one of --allow-covered or --fail-if-covered.")
    }

    @Test("without a hit-test, as on a physical iPhone, a cover is a tree-order guess: it warns and taps from one tree read")
    func guessWarnsFromOneRead() async throws {
        let backend = FakeDeviceBackend(trees: [Self.bannerScreen()])

        try await Self.tap(["--id", "tab-search"], on: backend)

        #expect(backend.treeReads == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])
    }

    @Test("--fail-if-covered refuses a tree-order guess, naming the cover, and sends no input")
    func failIfCoveredStops() async {
        let backend = FakeDeviceBackend(trees: [Self.bannerScreen()])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: backend)
        }

        let label = AccessibilityTargetResolverTests.bannerLabel
        #expect(error?.userFacingDescription == "--id 'tab-search' at (201, 814.5) may be covered by other '\(label)' (0, 767) 402x107; the tap may land on it.")
        #expect(error?.coveredBy?.evidence == .treeOrder)
        #expect(backend.openedSessions.isEmpty)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a candidate the hit-test does not find is no cover")
    func hitOnTargetIsNoCover() async throws {
        let underneath = HitTestingFakeBackend(trees: [Self.bannerScreen(bannerOnTop: false)])
        try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: underneath)
        #expect(underneath.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])

        let bannerItself = HitTestingFakeBackend(trees: [Self.bannerScreen()])
        try await Self.tap(["--id", "banner", "--fail-if-covered"], on: bannerItself)
        #expect(bannerItself.session.calls == [.perform(.tapAt(x: 201, y: 820.5))])
    }

    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)

    private static func tapAndroid(_ arguments: [String], on backend: FakeDeviceBackend) async throws {
        try await Tap.parse(arguments + ["--no-settle", "--device", android.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: android), progress: nil, logger: OffsiderLogger())
    }

    static func fullPage() throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: .android, screen: "stack-test@full"))
    }

    @Test("on Android, drawing order refuses the Home Tab under the full page's Buy from one tree read, and taps Buy")
    func androidDrawingOrderRefuses() async throws {
        let covered = FakeDeviceBackend(platform: .android, trees: [try Self.fullPage()])
        let error = await #expect(throws: CLIError.self) {
            try await Self.tapAndroid(["--id", "stack-test-tab-dashboard"], on: covered)
        }
        #expect(error?.coveredBy?.id == "stack-test-full-buy")
        #expect(error?.coveredBy?.evidence == .drawingOrder)
        #expect(error?.coveredBy?.screen == "stack-test-full-page-1")
        #expect(covered.treeReads == 1)
        #expect(covered.session.calls.isEmpty)

        let home = FakeDeviceBackend(platform: .android, trees: [try Self.fullPage()])
        let homeError = await #expect(throws: CLIError.self) {
            try await Self.tapAndroid(["--id", "stack-test-tab-home"], on: home)
        }
        #expect(homeError?.coveredBy?.id == "stack-test-full-page-1")

        let buy = FakeDeviceBackend(platform: .android, trees: [try Self.fullPage()])
        try await Self.tapAndroid(["--id", "stack-test-full-buy"], on: buy)
        #expect(buy.session.calls.count == 1)
    }

    @Test("--wait-timeout reads again while a confident cover stays, and taps once it has gone")
    func waitOutlastsCover() async throws {
        let page = try Self.fullPage()
        var closed = page
        closed.roots[0].children.removeAll { node in
            guard let order = node.drawingOrder else { return false }
            return order >= 17
        }
        let backend = FakeDeviceBackend(platform: .android, trees: [page, page, closed])

        try await Self.tapAndroid(["--id", "stack-test-tab-dashboard", "--wait-timeout", "3", "--poll-interval", "0.01"], on: backend)

        #expect(backend.treeReads == 3)
        #expect(backend.session.calls.count == 1)
    }

    @Test("on Android a candidate warns without a point read, which only walks tree order")
    func androidWarnsWithoutPointRead() async throws {
        func screen() -> UITree {
            let banner = FakeUI.node(.group, id: "banner", label: AccessibilityTargetResolverTests.bannerLabel, frame: FakeUI.frame(0, 767, 402, 107), platform: .android)
            let tabs = FakeUI.node(.group, frame: FakeUI.frame(0, 790, 402, 84), platform: .android, children: [
                FakeUI.node(.button, id: "tab-search", label: "Search", frame: FakeUI.frame(134, 790, 134, 49), platform: .android),
            ])
            return FakeUI.tree(platform: .android, width: 402, height: 874, [tabs, banner])
        }

        let covered = FakeDeviceBackend(platform: .android, trees: [screen()])
        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: covered)
        }
        #expect(error?.userFacingDescription.contains("may be covered by group '\(AccessibilityTargetResolverTests.bannerLabel)'") == true)
        #expect(covered.treeReads == 1)
        #expect(covered.session.calls.isEmpty)

        let bannerItself = FakeDeviceBackend(platform: .android, trees: [screen()])
        try await Self.tap(["--id", "banner", "--fail-if-covered"], on: bannerItself)
        #expect(bannerItself.session.calls == [.perform(.tapAt(x: 201, y: 820.5))])
    }

    @Test("--fail-if-covered lets a tap with no candidates through without a point read")
    func failIfCoveredAllowsClearTap() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 600)])

        try await Self.tap(["--id", "apply", "--fail-if-covered"], on: backend)

        #expect(backend.treeReads == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("a batch tap step honours --fail-if-covered per step")
    func batchStepFailIfCovered() async throws {
        func run(_ steps: [String], on backend: FakeDeviceBackend) async throws {
            let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
            try await Batch.runSteps(steps, context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())
        }

        let warned = FakeDeviceBackend(trees: [Self.bannerScreen()])
        try await run(["tap --id tab-search"], on: warned)
        #expect(warned.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])

        let stopped = FakeDeviceBackend(trees: [Self.bannerScreen()])
        let error = await #expect(throws: ReportedFailure.self) {
            try await run(["tap --id tab-home", "tap --id tab-search --fail-if-covered"], on: stopped)
        }
        #expect(error?.exitCode == .failure)
        #expect(error?.userFacingDescription.hasPrefix("Step 2 failed: [tap]\n--id 'tab-search' at (201, 814.5) may be covered by other") == true)
        #expect(stopped.session.calls == [.perform(.tapAt(x: 67, y: 814.5))])
    }

    @Test("a keyboard cover on iOS says to dismiss it in the app, since iOS has no back button, and hints describe-ui")
    func keyboardCoverOnIOS() {
        let error = Tap.keyboardCoverError(selector: "--id 'x'", at: (x: 160, y: 710), device: Self.device)

        #expect(error.userFacingDescription == "The keyboard covers --id 'x' at (160, 710), so the tap would press a key. Dismiss the keyboard in the app (or scroll the target above it), then retry. Nothing was sent.")
        #expect(error.hint == "offsider describe-ui --summary --device \(Self.device.rawValue)")
    }

    @Test("--topmost on Android taps the last on-screen match, and --nth taps the one asked for")
    func topmostAndNth() async throws {
        let roots = StackedScreenTests.stack(platform: .android)
        let topmost = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: "emulator-5554", roots: roots)])
        try await Tap.parse(["--label", "Back", "--topmost", "--no-settle", "--device", "emulator-5554"])
            .execute(on: DeviceRouter.Route(backend: topmost, device: DeviceID(rawValue: "emulator-5554", platform: .android)), progress: nil, logger: OffsiderLogger())
        #expect(topmost.session.calls == [.perform(.tapAt(x: 76, y: 222))])

        let first = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: "emulator-5554", roots: roots)])
        try await Tap.parse(["--label", "Back", "--nth", "1", "--no-settle", "--device", "emulator-5554"])
            .execute(on: DeviceRouter.Route(backend: first, device: DeviceID(rawValue: "emulator-5554", platform: .android)), progress: nil, logger: OffsiderLogger())
        #expect(first.session.calls == [.perform(.tapAt(x: 46, y: 222))])
    }

    @Test("--topmost on Android takes the match drawn over the others, even where nothing in the tree covers the other's point")
    func topmostByDrawingOrder() async throws {
        func page(_ number: Int, x: Double, order: Int) -> [UINode] {
            [FakeUI.node(.button, id: "mark", label: "Mark Page", frame: FakeUI.frame(x + 148, 447, 115, 44), platform: .android, drawingOrder: order)]
        }
        let tree = FakeUI.tree(platform: .android, device: Self.android.rawValue, page(1, x: -123, order: 1) + page(2, x: 0, order: 2))
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])

        try await Self.tapAndroid(["--id", "mark", "--topmost"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 205.5, y: 469))])
    }

    @Test("iOS --topmost hit-tests the tree it taps from, not an earlier read that had no match yet")
    func topmostPicksOnPolledTree() async throws {
        var root = StackedScreenTests.stack(platform: .ios)[0]
        let stacked = UITree(platform: .ios, device: Self.device.rawValue, roots: [root])
        root.children.reverse()
        // The fake's point read serves the next tree, where page 1 is listed last and so drawn on top.
        let pageOneOnTop = UITree(platform: .ios, device: Self.device.rawValue, roots: [root])
        let backend = HitTestingFakeBackend(trees: [FakeUI.tree([]), stacked, pageOneOnTop])

        try await Self.tap(["--label", "Back", "--topmost", "--wait-timeout", "2", "--poll-interval", "0.01"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 46, y: 222))])
    }

    /// Two Back buttons on stacked Android pages, page 2 at `pageTwoX`.
    private static func androidStack(pageTwoX: Double, extra: [UINode] = []) -> UITree {
        func page(_ number: Int, x: Double) -> UINode {
            FakeUI.node(.other, id: "page-\(number)", label: "Page \(number)", frame: FakeUI.frame(x, 100, 402, 774), platform: .android, children: [
                FakeUI.node(.button, id: "stack-back", label: "Back", frame: FakeUI.frame(x + 16, 200, 120, 44), platform: .android),
            ])
        }
        return FakeUI.tree(platform: .android, device: "emulator-5554", [page(1, x: -30), page(2, x: pageTwoX)] + extra)
    }

    @Test("--verify re-resolves --nth on its second read, so the match that moved is tapped where it is now")
    func verifyKeepsPick() async throws {
        let saved = FakeUI.node(.text, id: "saved", label: "Saved", frame: FakeUI.frame(20, 600, 300, 20), platform: .android)
        let backend = FakeDeviceBackend(platform: .android, trees: [
            Self.androidStack(pageTwoX: 0), Self.androidStack(pageTwoX: 10), Self.androidStack(pageTwoX: 10, extra: [saved]),
        ])
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)

        try await DispatchTracker.$current.withValue(DispatchTracker()) {
            try await Tap.parse(["--label", "Back", "--nth", "2", "--verify", "--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: VerifyProgress(), logger: OffsiderLogger())
        }

        #expect(backend.session.calls == [.perform(.tapAt(x: 86, y: 222))])
    }

    @Test("--nth and --topmost need a selector, exclude each other and count from 1", arguments: [
        (["-x", "1", "-y", "1", "--nth", "1"], "use them with --id, --label or --value"),
        (["--id", "a", "--nth", "1", "--topmost"], "Use only one of --nth or --topmost."),
        (["--id", "a", "--nth", "0"], "--nth must be 1 or more"),
    ])
    func pickValidation(arguments: [String], message: String) {
        let error = #expect(throws: (any Error).self) { try Tap.parse(arguments + ["--device", "emulator-5554"]) }
        #expect(error.map { Tap.message(for: $0).contains(message) } == true)
    }

    @Test("a long cover label is cut to 60 characters")
    func coverLabelTruncated() {
        let cover = FakeUI.node(.other, label: String(repeating: "a", count: 80), frame: FakeUI.frame(0, 0, 10, 10))

        let message = TapCover.describe(CoverVerdict(cover: cover, evidence: .hitTest, isConfident: true))

        #expect(message == "other '\(String(repeating: "a", count: 59))…' (0, 0) 10x10")
    }

    @Test("a slider drag on iOS converts its points with the tree it resolved from")
    func sliderDragPassesTree() async throws {
        func screen(_ percent: Int) -> UITree {
            FakeUI.tree([FakeUI.node(.slider, id: "volume", label: "Volume", value: "\(percent)%", frame: FakeUI.frame(20, 400, 360, 20))])
        }
        let backend = FakeDeviceBackend(trees: [screen(25), screen(60)], advanceTreeOnInput: true)

        let line = try await Slider.parse(["--id", "volume", "--value", "60", "--device", Self.device.rawValue])
            .setSlider(on: SliderTarget(backend: backend, device: Self.device), logger: OffsiderLogger())

        #expect(line == "✓ Slider set to 60 successfully (value: 60%)")
        #expect(backend.coordinateCalls.map(\.hadTree) == [true])
    }

    @Test("a missing selector exits 2 with dispatched no")
    func missingSelectorExits2() async {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 600)])
        let tracker = DispatchTracker()

        let error = await #expect(throws: ElementResolutionError.self) {
            try await DispatchTracker.$current.withValue(tracker) {
                try await Self.tap(["--id", "missing"], on: backend)
            }
        }

        #expect(error?.exitCode == .selectorNotFound)
        #expect(tracker.state == .no)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a duplicated id exits 6 and names both candidates")
    func duplicatedIDExits6() async {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, 600, 350, 44)),
            FakeUI.node(.button, id: "apply", label: "Apply all", frame: FakeUI.frame(20, 660, 350, 44)),
        ])])

        let error = await #expect(throws: ElementResolutionError.self) {
            try await Self.tap(["--id", "apply"], on: backend)
        }

        #expect(error?.exitCode == .ambiguousSelector)
        #expect(error?.candidates.map(\.label) == ["Apply", "Apply all"])
        #expect(backend.session.calls.isEmpty)
    }

    @Test("the keyboard over the target is target_under_keyboard even without --fail-if-covered; another cover is target_covered with it")
    func coverReasons() async throws {
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 560, 393, 292), children: [
            FakeUI.node(.button, label: "q", frame: FakeUI.frame(0, 600, 393, 50)),
        ])
        let field = FakeUI.node(.textField, id: "field", label: "Field", frame: FakeUI.frame(20, 600, 350, 44))
        let underKeyboard = FakeDeviceBackend(trees: [FakeUI.tree(width: 393, height: 852, [field, keyboard])])
        let keyboardError = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "field"], on: underKeyboard)
        }
        #expect(keyboardError?.reason == .targetUnderKeyboard)

        let banner = FakeDeviceBackend(trees: [Self.bannerScreen()])
        let bannerError = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: banner)
        }
        #expect(bannerError?.reason == .targetCovered)
        #expect(banner.session.calls.isEmpty && underKeyboard.session.calls.isEmpty)
    }

    @Test("a send that fails part way reports dispatched unknown; one that returns reports yes")
    func trackedSendStates() async throws {
        let failing = TrackedInputSession.wrapping(RecordingInputSession(failingOn: .shortKeyPress(40), with: CLIError(errorDescription: "lost")))
        let failed = DispatchTracker()
        await #expect(throws: CLIError.self) {
            try await DispatchTracker.$current.withValue(failed) { try await failing.perform(.shortKeyPress(40)) }
        }
        #expect(failed.state == .unknown)

        let sent = DispatchTracker()
        try await DispatchTracker.$current.withValue(sent) {
            try await TrackedInputSession.wrapping(RecordingInputSession()).perform(.shortKeyPress(41))
        }
        #expect(sent.state == .yes)
    }
}
