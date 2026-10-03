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

    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async throws {
        try await Tap.parse(arguments + ["--device", device.rawValue])
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

    @Test("a selector tap on iOS reads the tree once and converts the point with that tree")
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

    @Test("a covered tap reads the point once and still sends input by default")
    func coveredTapStillTaps() async throws {
        let backend = FakeDeviceBackend(trees: [Self.bannerScreen()])

        try await Self.tap(["--id", "tab-search"], on: backend)

        #expect(backend.treeReads == 2)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])
    }

    @Test("--fail-if-covered names the cover the hit-test found and sends no input")
    func failIfCoveredStops() async {
        let backend = FakeDeviceBackend(trees: [Self.bannerScreen()])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: backend)
        }

        let label = AccessibilityTargetResolverTests.bannerLabel
        #expect(error?.userFacingDescription == "--id 'tab-search' at (201, 814.5) may be covered by other '\(label)' (0, 767) 402x107; the tap may land on it.")
        #expect(backend.openedSessions.isEmpty)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a candidate the hit-test does not find is no cover")
    func hitOnTargetIsNoCover() async throws {
        let underneath = FakeDeviceBackend(trees: [Self.bannerScreen(bannerOnTop: false)])
        try await Self.tap(["--id", "tab-search", "--fail-if-covered"], on: underneath)
        #expect(underneath.session.calls == [.perform(.tapAt(x: 201, y: 814.5))])

        let bannerItself = FakeDeviceBackend(trees: [Self.bannerScreen()])
        try await Self.tap(["--id", "banner", "--fail-if-covered"], on: bannerItself)
        #expect(bannerItself.session.calls == [.perform(.tapAt(x: 201, y: 820.5))])
    }

    @Test("on Android a candidate warns without a point read, which only walks tree order")
    func androidWarnsWithoutPointRead() async throws {
        func screen() -> UITree {
            let banner = FakeUI.node(.group, id: "banner", label: AccessibilityTargetResolverTests.bannerLabel, frame: FakeUI.frame(0, 767, 402, 107), platform: .android)
            let tabs = FakeUI.node(.group, frame: FakeUI.frame(0, 790, 402, 84), platform: .android, children: [
                FakeUI.node(.button, id: "tab-search", label: "Search", frame: FakeUI.frame(134, 790, 134, 49), platform: .android),
            ])
            return FakeUI.tree(platform: .android, width: 402, height: 874, [banner, tabs])
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
        let error = await #expect(throws: CLIError.self) {
            try await run(["tap --id tab-home", "tap --id tab-search --fail-if-covered"], on: stopped)
        }
        #expect(error?.userFacingDescription.hasPrefix("Step 2 failed: [tap]\n--id 'tab-search' at (201, 814.5) may be covered by other") == true)
        #expect(stopped.session.calls == [.perform(.tapAt(x: 67, y: 814.5))])
    }

    @Test("a long cover label is cut to 60 characters")
    func coverLabelTruncated() {
        let cover = FakeUI.node(.other, label: String(repeating: "a", count: 80), frame: FakeUI.frame(0, 0, 10, 10))

        let message = Tap.coverMessage(selector: "--id 'x'", at: (x: 5, y: 5), cover: cover)

        #expect(message.contains("other '\(String(repeating: "a", count: 59))…' (0, 0) 10x10"))
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
}
