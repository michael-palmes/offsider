import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// While the keyboard's window hides the whole app, Android marks every view not visible, drawn or not, so a view at zero opacity reads like any other: its drawing order is then only a guess.
@Suite("Keyboard-hidden app window")
@MainActor
struct HiddenWindowCoverTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .android)
    static let width = 411.4, height = 923.4
    static let keys = FakeUI.frame(12, 351, 359, 548)

    static func node(_ role: UIRole, id: String? = nil, label: String? = nil, _ frame: UIFrame, order: Int? = nil, visible: Bool? = nil, layer: Int? = nil, children: [UINode] = []) -> UINode {
        var node = FakeUI.node(role, id: id, label: label, frame: frame, platform: .android, children: children)
        node.native = .android(AndroidNativeAttributes(className: "android.view.ViewGroup", resourceId: id, visibleToUser: visible, drawingOrder: order, windowLayer: layer))
        return node
    }

    /// A form under a guide parked over the whole screen. With `windowHidden`, a panel of the keyboard holds input focus and every app node reads not visible; otherwise only `guideVisible` says whether the guide is drawn.
    static func form(windowHidden: Bool, guideVisible: Bool = true, keyboard: Bool = true) -> UITree {
        let seen: Bool? = windowHidden ? false : nil
        let guide = node(.group, id: "parked-guide", label: "Typing Guide", FakeUI.frame(0, 0, width, height), order: 8, visible: windowHidden ? false : guideVisible, children: [
            node(.text, label: "Guide Title", FakeUI.frame(158, 120, 96, 27), order: 1, visible: windowHidden ? false : guideVisible),
            node(.text, label: "Guide Tip", FakeUI.frame(170, 700, 72, 23), order: 2, visible: windowHidden ? false : guideVisible),
        ])
        let app = node(.application, label: "Playground", FakeUI.frame(0, 0, width, height), visible: seen, layer: 0, children: [
            guide,
            node(.text, id: "form-title", label: "Form Title", FakeUI.frame(16, 113, 379, 27), order: 3, visible: seen),
            node(.textField, id: "first-field", label: "First field", FakeUI.frame(16, 192, 379, 44), order: 4, visible: seen),
            node(.textField, id: "low-field", label: "Low field", FakeUI.frame(16, 500, 379, 44), order: 7, visible: seen),
        ])
        var tree = UITree(platform: .android, device: device.rawValue, roots: [app])
        guard keyboard else { return tree }
        let panel = node(.keyboard, label: "Keyboard", keys, visible: true, layer: 1, children: [
            node(.button, label: "Done", FakeUI.frame(40, 851, 88, 48), order: 1, visible: true),
        ])
        tree.roots.append(panel)
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Playground", active: true, focused: true, package: "com.example", bounds: FakeUI.frame(0, 0, width, height)),
            UIWindowInfo(id: 2, kind: "inputMethod", layer: 1, title: "Keyboard", active: false, focused: false, package: nil, bounds: FakeUI.frame(0, 0, width, height)),
        ]
        return tree
    }

    static func tap(_ arguments: [String], tree: UITree) async throws -> (backend: FakeDeviceBackend, err: String) {
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        let capture = ConsoleCapture()
        try await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
            }
        }
        return (backend, capture.err)
    }

    static func judge(_ tree: UITree, target: String) throws -> CoverVerdict? {
        var judged = tree
        judged.roots = AccessibilityTargetResolver.coverRoots(tree.roots, android: true)
        return try TapCoverTests.judge(judged, target: target, hit: nil)
    }

    // MARK: The fault

    @Test("with the window hidden, the parked guide over a field is a guess, not a sure cover")
    func hiddenGuideIsAGuess() throws {
        let verdict = try #require(try Self.judge(Self.form(windowHidden: true), target: "first-field"))
        #expect(verdict.cover.id == "parked-guide")
        #expect(!verdict.isConfident && verdict.evidence == .hiddenWindow)
    }

    @Test("with the window hidden, nothing in it is a page, so the screen is not folded beneath the guide")
    func hiddenGuideIsNoPage() async throws {
        let tree = Self.form(windowHidden: true)
        #expect(ScreenStack.build(roots: tree.roots, viewport: tree.viewport).pages.isEmpty)

        let summary = try await OnScreenRuleTests.describe(["--summary"], on: FakeDeviceBackend(platform: .android, trees: [tree]), device: Self.device)
        #expect(summary.contains("id=form-title") && summary.contains("id=first-field"), "\(summary)")
        #expect(!summary.contains("# beneath"), "\(summary)")
    }

    @Test("with the window hidden, wait finds the form's title")
    func hiddenWindowWaitPasses() async throws {
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: [Self.form(windowHidden: true)]), device: Self.device)
        let outcome = try await Wait.parse(["--id", "form-title", "--timeout", "0", "--device", Self.device.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(outcome.met, "\(outcome.reason ?? "")")
    }

    @Test("with the window hidden, a tap on the field goes out with a warning that says why Android cannot tell")
    func hiddenWindowTapWarns() async throws {
        let (backend, err) = try await Self.tap(["--id", "first-field"], tree: Self.form(windowHidden: true))
        #expect(backend.session.calls.count == 1)
        #expect(err.contains(#"may be covered by group "Typing Guide""#) && err.contains("The app's window reads hidden, as under a keyboard panel, so Android cannot say whether that view is drawn."), "\(err)")
        #expect(err.contains("Pass --fail-if-covered to stop instead."), "\(err)")
    }

    // MARK: What must not change

    @Test("with the window hidden, --fail-if-covered still stops, and its hint is a screenshot, never Back, which would leave the screen")
    func hiddenWindowFailIfCoveredStops() async throws {
        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "first-field", "--fail-if-covered"], tree: Self.form(windowHidden: true)) }
        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "parked-guide" && error?.coveredBy?.evidence == .hiddenWindow)
        #expect(error?.errorDescription?.hasSuffix("Nothing was sent. Close the panel, or check a screenshot and tap without --fail-if-covered.") == true)
        #expect(error?.hint == "offsider screenshot --device fake-device")
    }

    @Test("with the window hidden, a field under the keyboard's own panel is still refused as under the keyboard")
    func hiddenWindowKeyboardStillCovers() async throws {
        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "low-field"], tree: Self.form(windowHidden: true)) }
        #expect(error?.reason == .targetUnderKeyboard)
    }

    @Test("a guide that is drawn, in a window Android can see, is still a sure cover and still a page, keyboard up or not", arguments: [true, false])
    func visibleGuideStillCovers(keyboard: Bool) async throws {
        let tree = Self.form(windowHidden: false, keyboard: keyboard)
        let verdict = try #require(try Self.judge(tree, target: "first-field"))
        #expect(verdict.cover.id == "parked-guide" && verdict.isConfident && verdict.evidence == .drawingOrder)
        #expect(ScreenStack.build(roots: tree.roots, viewport: tree.viewport).pages.map(\.name) == ["parked-guide"])

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "first-field"], tree: tree) }
        #expect(error?.reason == .targetCovered && error?.coveredBy?.evidence == .drawingOrder)
    }

    @Test("a guide hidden under a parent Android can see still takes no touch, as before")
    func hiddenNodeUnderVisibleParent() async throws {
        let tree = Self.form(windowHidden: false, guideVisible: false)
        #expect(try Self.judge(tree, target: "first-field") == nil)
        let (backend, err) = try await Self.tap(["--id", "first-field"], tree: tree)
        #expect(backend.session.calls.count == 1)
        #expect(err.isEmpty, "\(err)")
    }

    @Test("with the window hidden, a point nothing else is drawn over is still clear, so a plain field taps with no warning")
    func hiddenWindowClearPoint() async throws {
        var tree = Self.form(windowHidden: true)
        tree.roots[0].children.removeFirst()
        let (backend, err) = try await Self.tap(["--id", "first-field"], tree: tree)
        #expect(backend.session.calls.count == 1)
        #expect(err.isEmpty, "\(err)")
    }
}
