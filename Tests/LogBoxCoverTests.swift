import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A LogBox toast takes touches a little beyond the frame the tree gives it, as its wrapper and container are unlisted.
@Suite("LogBox toast cover")
@MainActor
struct LogBoxCoverTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let toastLabel = "!, Request failed"

    /// A 36-point row whose centre sits 0.7 points above a toast at 800.7.
    static func edgeScreen(row: UIFrame = FakeUI.frame(0, 782, 402, 36), toastLabel: String = toastLabel, platform: DevicePlatform = .ios) -> UITree {
        FakeUI.tree(platform: platform, [
            FakeUI.node(.button, id: "row", label: "Settings", frame: row, platform: platform, drawingOrder: 1),
            FakeUI.node(.other, label: toastLabel, frame: FakeUI.frame(10, 800.7, 382, 48), platform: platform, drawingOrder: 2),
        ])
    }

    static func judge(_ tree: UITree, hit: UINode?) throws -> CoverVerdict? {
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("row"))
        let target = try #require(resolution.target)
        let viewport = try #require(tree.viewport)
        return CoverJudge.judge(
            target: target, matched: resolution.matched ?? target, point: UIPoint(x: resolution.point.x, y: resolution.point.y),
            candidates: resolution.coverCandidates, roots: tree.roots, viewport: viewport,
            stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: hit
        )
    }

    @Test("a hit-test that finds the row, or the toast's unlisted wrapper, at a point just above the toast is a confident cover by its touch area")
    func edgeGeometryRefuses() throws {
        let tree = Self.edgeScreen()
        let row = tree.roots[0].children[0]
        let wrapper = FakeUI.node(.group, frame: FakeUI.frame(10, 799.7, 382, 48.3))

        for hit in [row, wrapper] {
            let verdict = try #require(try Self.judge(tree, hit: hit))
            #expect(verdict.cover.label == Self.toastLabel)
            #expect(verdict.evidence == .logBoxTouchArea && verdict.isConfident)
        }
    }

    @Test("on Android, where drawing order says the row is on top, a point just above the toast is the same confident cover")
    func androidEdgeRefuses() throws {
        let tree = Self.edgeScreen(row: FakeUI.frame(0, 778.2, 402, 44), platform: .android)

        let verdict = try #require(try Self.judge(tree, hit: nil))

        #expect(verdict.cover.label == Self.toastLabel)
        #expect(verdict.evidence == .logBoxTouchArea && verdict.isConfident)
    }

    @Test("a row whose centre is 12 points above the toast and whose frame stops short of its touch area is no cover")
    func rowAboveIsClear() throws {
        let tree = Self.edgeScreen(row: FakeUI.frame(0, 778.7, 402, 20))
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("row"))

        #expect(resolution.coverCandidates.isEmpty)
        #expect(try Self.judge(tree, hit: tree.roots[0].children[0]) == nil)
    }

    @Test("a row whose frame reaches the touch area while its centre stays clear is only a guess")
    func overlapIsGuess() throws {
        let tree = Self.edgeScreen(row: FakeUI.frame(0, 773, 402, 40))

        let verdict = try #require(try Self.judge(tree, hit: tree.roots[0].children[0]))

        #expect(verdict.cover.label == Self.toastLabel)
        #expect(verdict.evidence == .logBoxTouchArea && !verdict.isConfident)
    }

    @Test("an ordinary banner in the toast's place covers only its own frame")
    func ordinaryBannerHasNoMargin() throws {
        let tree = Self.edgeScreen(toastLabel: "Connection lost. Can’t reach the server.")
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("row"))

        #expect(resolution.coverCandidates.isEmpty)
        #expect(try Self.judge(tree, hit: tree.roots[0].children[0]) == nil)
    }

    @Test("a toast on a screen beneath the page the row is on is no cover")
    func toastBeneathPage() throws {
        let lower = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Products", frame: FakeUI.frame(60, 60, 282, 20)),
            FakeUI.node(.other, label: Self.toastLabel, frame: FakeUI.frame(10, 800.7, 382, 48)),
        ])
        let upper = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Kettle", frame: FakeUI.frame(60, 60, 282, 20)),
            FakeUI.node(.button, id: "row", label: "Add to Cart", frame: FakeUI.frame(0, 782, 402, 36)),
        ])
        let tree = FakeUI.tree([lower, upper])
        let viewport = try #require(tree.viewport)
        let nodes = tree.roots.flatMap { $0.flattened() }
        let row = try #require(nodes.first { $0.id == "row" })
        let toast = try #require(nodes.first { $0.label == Self.toastLabel })

        let verdict = CoverJudge.judge(
            target: row, matched: row, point: UIPoint(x: 201, y: 800), candidates: [toast], roots: tree.roots, viewport: viewport,
            stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: row
        )

        #expect(verdict == nil)
    }

    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async throws {
        try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
    }

    @Test("tap --fail-if-covered on the edge row refuses with target_covered, names the toast's touch area, and sends nothing")
    func tapRefusesAtTheEdge() async {
        let backend = HitTestingFakeBackend(trees: [Self.edgeScreen()])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "row", "--fail-if-covered"], on: backend)
        }

        #expect(error?.reason == .targetCovered && error?.exitCode == .failure)
        #expect(error?.coveredBy?.evidence == .logBoxTouchArea)
        #expect(error?.coveredBy?.label == Self.toastLabel)
        #expect(error?.userFacingDescription.contains("(LogBox's toast takes touches beyond its frame there), so the tap would land on it. Nothing was sent.") == true)
        #expect(backend.hitTests == 1)
        #expect(backend.openedSessions.isEmpty && backend.session.calls.isEmpty)
    }

    @Test("--allow-covered taps the row anyway")
    func allowCoveredTaps() async throws {
        let backend = HitTestingFakeBackend(trees: [Self.edgeScreen()])

        try await Self.tap(["--id", "row", "--allow-covered"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 800))])
    }

    // MARK: Android, where LogBox's toast list pads itself by the status bar when the app draws under it

    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let toastTop = 806.0

    /// A row centred `lift` above a toast at 806, over a backdrop that starts under a 54-point status bar when `edgeToEdge`.
    static func androidScreen(lift: Double, edgeToEdge: Bool = true, appWindowTop: Double = 0) -> UITree {
        let android = DevicePlatform.android
        let backdrop = FakeUI.node(.group, frame: edgeToEdge ? FakeUI.frame(0, 0, 402, 874) : FakeUI.frame(0, 54, 402, 796), platform: android, drawingOrder: 1)
        let row = FakeUI.node(.button, id: "row", label: "Settings", frame: FakeUI.frame(0, toastTop - lift - 22, 402, 44), platform: android, drawingOrder: 2)
        let toast = FakeUI.node(.button, label: toastLabel, frame: FakeUI.frame(10, toastTop, 382, 48), platform: android, drawingOrder: 3)
        var tree = FakeUI.tree(platform: android, [backdrop, row, toast])
        tree.windows = [
            UIWindowInfo(id: 1, kind: "system", layer: 1, title: nil, active: false, focused: false, package: nil, bounds: FakeUI.frame(0, 0, 402, 54)),
            UIWindowInfo(id: 2, kind: "application", layer: 0, title: "Playground", active: true, focused: true, package: LogBoxTrees.package,
                         bounds: FakeUI.frame(0, appWindowTop, 402, 874 - appWindowTop)),
        ]
        return tree
    }

    private static func tapAndroid(_ arguments: [String], on tree: UITree) async throws -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        try await Tap.parse(arguments + ["--no-settle", "--device", android.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: android), progress: nil, logger: OffsiderLogger())
        return backend
    }

    @Test("the inset is the status bar's height when an element of the app sits under the status bar or reaches past the navigation bar, and 0 otherwise, when its window stops above the bar, or on iOS")
    func topInset() {
        #expect(KnownOverlays.logBoxTopInset(in: Self.androidScreen(lift: 30)) == 54)
        #expect(KnownOverlays.logBoxTopInset(in: Self.androidScreen(lift: 30, edgeToEdge: false)) == 0)
        #expect(KnownOverlays.logBoxTopInset(in: Self.androidScreen(lift: 30, appWindowTop: 54)) == 0)
        var tabBarToBottom = Self.androidScreen(lift: 30, edgeToEdge: false)
        tabBarToBottom.roots[0].children.append(FakeUI.node(.group, id: "tab-bar", frame: FakeUI.frame(0, 830, 402, 44), platform: .android, drawingOrder: 4))
        #expect(KnownOverlays.logBoxTopInset(in: tabBarToBottom) == 54)
        #expect(KnownOverlays.logBoxTopInset(in: Self.edgeScreen()) == 0)
        var noWindows = Self.androidScreen(lift: 30)
        noWindows.windows = nil
        #expect(KnownOverlays.logBoxTopInset(in: noWindows) == 0)
    }

    @Test("edge-to-edge on Android, a row 30 points above the toast is inside the band and refused with nothing sent")
    func bandRefuses() async {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.tapAndroid(["--id", "row"], on: Self.androidScreen(lift: 30))
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.evidence == .logBoxTouchArea && error?.coveredBy?.label == Self.toastLabel)
    }

    @Test("the same row is tapped when the app stops below the status bar, and a row clearly above the band is tapped edge-to-edge too")
    func outsideBandTaps() async throws {
        let stopsBelowBar = try await Self.tapAndroid(["--id", "row", "--fail-if-covered"], on: Self.androidScreen(lift: 30, edgeToEdge: false))
        #expect(stopsBelowBar.session.calls == [.perform(.tapAt(x: 201, y: 776))])

        let above = try await Self.tapAndroid(["--id", "row", "--fail-if-covered"], on: Self.androidScreen(lift: 90))
        #expect(above.session.calls == [.perform(.tapAt(x: 201, y: 716))])
    }

    @Test("a row whose frame only reaches the band is a guess: --fail-if-covered refuses, and without it the tap goes ahead")
    func bandOverlapIsGuess() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.tapAndroid(["--id", "row", "--fail-if-covered"], on: Self.androidScreen(lift: 70))
        }
        #expect(error?.coveredBy?.evidence == .logBoxTouchArea)
        #expect(error?.userFacingDescription.contains("may be covered by") == true)

        let warned = try await Self.tapAndroid(["--id", "row"], on: Self.androidScreen(lift: 70))
        #expect(warned.session.calls == [.perform(.tapAt(x: 201, y: 736))])
    }
}
