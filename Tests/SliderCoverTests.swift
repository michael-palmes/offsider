import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Slider covers")
@MainActor
struct SliderCoverTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func slider(percent: Int) -> UINode {
        FakeUI.node(.slider, id: "volume", label: "Volume", value: "\(percent)%", frame: FakeUI.frame(20, 700, 360, 20))
    }

    /// The fake's point read returns the deepest node by sibling order, so the sheet listed last is on top.
    static func underSheet(percent: Int) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            slider(percent: percent),
            FakeUI.node(.other, id: "sheet", label: "Filters", frame: FakeUI.frame(0, 500, 393, 352), children: [
                FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, 780, 350, 44)),
            ]),
        ])
    }

    private static func set(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> String {
        try await Slider.parse(arguments + ["--no-settle", "--device", device.rawValue])
            .setSlider(on: SliderTarget(backend: backend, device: device), logger: OffsiderLogger())
    }

    @Test("a slider under a sheet a hit-test finds refuses target_covered where the drag would start, and sends no touch")
    func coveredRefuses() async {
        let backend = HitTestingFakeBackend(trees: [Self.underSheet(percent: 25)])

        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.set(["--id", "volume", "--value", "60"], on: backend)
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.userFacingDescription.contains("so the drag would land on it. Nothing was sent.") == true)
        #expect(error?.userFacingDescription.hasSuffix("or pass --allow-covered to drag anyway.") == true)
        #expect(error?.coveredBy?.id == "sheet")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--allow-covered drags anyway")
    func allowCoveredDrags() async throws {
        let backend = HitTestingFakeBackend(trees: [Self.underSheet(percent: 25), Self.underSheet(percent: 60)], advanceTreeOnInput: true)

        let line = try await Self.set(["--id", "volume", "--value", "60", "--allow-covered"], on: backend)

        #expect(line == "✓ Slider set to 60 successfully (value: 60%)")
        #expect(TransitionGuardTests.dragStarts(backend).count == 1)
    }

    @Test("a slider under the keyboard refuses target_under_keyboard and sends no touch")
    func keyboardRefuses() async {
        let tree = FakeUI.tree(width: 393, height: 852, [
            Self.slider(percent: 25),
            FakeUI.node(.keyboard, frame: FakeUI.frame(0, 560, 393, 292), children: [
                FakeUI.node(.button, label: "q", frame: FakeUI.frame(0, 690, 393, 50)),
            ]),
        ])
        let backend = FakeDeviceBackend(trees: [tree])

        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.set(["--id", "volume", "--value", "60"], on: backend)
        }

        #expect(error?.reason == .targetUnderKeyboard)
        #expect(error?.userFacingDescription.contains("so the drag would press a key") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a sheet over the slider's far end, clear of its thumb, does not stop the drag")
    func coverClearOfThumbDrags() async throws {
        func screen(_ percent: Int) -> UITree {
            FakeUI.tree(width: 393, height: 852, [
                Self.slider(percent: percent),
                FakeUI.node(.button, id: "help", label: "Help", frame: FakeUI.frame(340, 690, 53, 40)),
            ])
        }
        let backend = HitTestingFakeBackend(trees: [screen(10), screen(30)], advanceTreeOnInput: true)

        let line = try await Self.set(["--id", "volume", "--value", "30"], on: backend)

        #expect(line == "✓ Slider set to 30 successfully (value: 30%)")
        #expect(TransitionGuardTests.dragStarts(backend).count == 1)
    }

    @Test("a slider that says it is disabled is not refused before the drag, as before")
    func disabledSliderUnchanged() async throws {
        func screen(_ percent: Int) -> UITree {
            FakeUI.tree(width: 393, height: 852, [
                FakeUI.node(.slider, id: "volume", value: "\(percent)%", frame: FakeUI.frame(20, 700, 360, 20), enabled: false),
            ])
        }
        let backend = FakeDeviceBackend(trees: [screen(25), screen(60)], advanceTreeOnInput: true)

        let line = try await Self.set(["--id", "volume", "--value", "60"], on: backend)

        #expect(line == "✓ Slider set to 60 successfully (value: 60%)")
    }
}
