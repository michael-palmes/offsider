import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// An edge-to-edge app on Android with three-button navigation: the bar is a system window of its own over the bottom 48 dp, and takes every touch there.
@Suite("Android system bar covers")
@MainActor
struct AndroidSystemBarCoverTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let height = 874.0
    static let barTop = 826.0

    /// A list of rows reaching the bottom of the screen; `rowTop` places the last row.
    static func screen(rowTop: Double, rowHeight: Double = 40, navigationBar: Bool = true) -> UITree {
        let list = FakeUI.node(.list, id: "list", frame: FakeUI.frame(0, 100, 402, height - 100), platform: .android, children: [
            FakeUI.node(.button, id: "row-1", label: "Row 1", frame: FakeUI.frame(0, 400, 402, 64), platform: .android, drawingOrder: 1),
            FakeUI.node(.button, id: "row-2", label: "Row 2", frame: FakeUI.frame(0, rowTop, 402, rowHeight), platform: .android, drawingOrder: 2),
        ])
        var tree = FakeUI.tree(platform: .android, width: 402, height: height, [list])
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Playground", active: true, focused: true, package: "com.example", bounds: FakeUI.frame(0, 0, 402, height)),
            UIWindowInfo(id: 2, kind: "system", layer: 1, title: nil, active: false, focused: false, package: nil, bounds: FakeUI.frame(0, 0, 402, 54)),
        ]
        if navigationBar {
            tree.windows?.append(UIWindowInfo(id: 3, kind: "system", layer: 2, title: "Navigation bar", active: false, focused: false, package: nil, bounds: FakeUI.frame(0, barTop, 402, height - barTop)))
        }
        return tree
    }

    private static func tap(_ arguments: [String], on tree: UITree) async throws -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
        return backend
    }

    @Test("a row wholly under the navigation bar refuses target_covered with evidence systemBar and a scroll, and sends nothing")
    func rowUnderBarRefuses() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.screen(rowTop: 830)])

        let error = await #expect(throws: CLIError.self) {
            try await Tap.parse(["--id", "row-2", "--no-settle", "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.evidence == .systemBar)
        #expect(error?.coveredBy?.label == "Navigation bar")
        #expect(error?.userFacingDescription.contains("so the tap would land on the bar. Nothing was sent. Scroll it clear of the bar") == true)
        #expect(error?.hint == "offsider swipe --start-x 101 --start-y 572 --end-x 101 --end-y 354 --duration 0.5 --hold-end 300 --device emulator-5554")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a row showing 20 dp above the bar is tapped in the middle of that part")
    func partAboveBarTaps() async throws {
        let backend = try await Self.tap(["--id", "row-2"], on: Self.screen(rowTop: 806))

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 816))])
    }

    @Test("with gesture navigation Android lists no bar, so the row's centre is tapped as before")
    func gestureNavigationUnchanged() async throws {
        let backend = try await Self.tap(["--id", "row-2"], on: Self.screen(rowTop: 830, navigationBar: false))

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 850))])
    }

    @Test("--allow-covered taps the bar's point anyway")
    func allowCoveredTaps() async throws {
        let backend = try await Self.tap(["--id", "row-2", "--allow-covered"], on: Self.screen(rowTop: 830))

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 850))])
    }

    @Test("wait and assert agree with tap: a row under the bar is not on screen, and one showing beside it is")
    func onScreenRuleAgrees() async throws {
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: [Self.screen(rowTop: 830)]), device: Self.device)
        let waited = try await Wait.parse(["--id", "row-2", "--timeout", "0", "--device", Self.device.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(!waited.met)
        #expect(waited.reason == #"under other "Navigation bar" (0, 826) 402x48, so a tap would not reach it"#)

        let showing = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: [Self.screen(rowTop: 806)]), device: Self.device)
        let asserted = try await Assert.parse(["--id", "row-2", "--device", Self.device.rawValue]).evaluate(on: showing, logger: OffsiderLogger())
        #expect(asserted.met)
    }
}
