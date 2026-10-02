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
