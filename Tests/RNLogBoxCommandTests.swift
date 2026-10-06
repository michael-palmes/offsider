import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("rn logbox")
@MainActor
struct RNLogBoxCommandTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func toast(_ count: Int) -> UINode {
        FakeUI.node(.other, label: "\(count == 1 ? "!" : String(count)), Request failed", frame: FakeUI.frame(10, 806, 382, 48))
    }

    static func inspector(log: Int, of: Int) -> [UINode] {
        [
            FakeUI.node(.text, label: "Log \(log) of \(of)", frame: FakeUI.frame(150, 60, 100, 20)),
            FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 820, 200, 54)),
            FakeUI.node(.button, label: "Minimize", frame: FakeUI.frame(202, 820, 200, 54)),
        ]
    }

    static func dismiss(_ trees: [UITree], timeout: String = "15") async throws -> (LogBoxDismissal, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(trees: trees, advanceTreeOnInput: true)
        let command = try RNLogBoxDismiss.parse(["--timeout", timeout, "--device", device.rawValue])
        let outcome = try await command.dismiss(on: DeviceRouter.Route(backend: backend, device: device), clock: ScriptedClock().poll)
        return (outcome, backend)
    }

    @Test("a toast whose clear button works takes one tap at its right-hand end")
    func buttonPath() async throws {
        let (outcome, backend) = try await Self.dismiss([FakeUI.tree([Self.toast(1)]), FakeUI.tree()])

        #expect(outcome == LogBoxDismissal(cleared: 1, remaining: 0, method: .dismissButton))
        #expect(backend.session.calls == [.perform(.tapAt(x: 370, y: 830))])
    }

    @Test("when the clear button does nothing, the toast's body opens the inspector and Dismiss goes once per log")
    func inspectorFallback() async throws {
        let (outcome, backend) = try await Self.dismiss([
            FakeUI.tree([Self.toast(2)]), FakeUI.tree([Self.toast(2)]),
            FakeUI.tree(Self.inspector(log: 1, of: 2)), FakeUI.tree(Self.inspector(log: 1, of: 1)), FakeUI.tree(),
        ])

        #expect(outcome == LogBoxDismissal(cleared: 2, remaining: 0, method: .inspector))
        #expect(backend.session.calls == [
            .perform(.tapAt(x: 370, y: 830)), .perform(.tapAt(x: 162.8, y: 830)),
            .perform(.tapAt(x: 100, y: 847)), .perform(.tapAt(x: 100, y: 847)),
        ])
    }

    @Test("logs still on screen are reported as remaining")
    func remaining() async throws {
        let (outcome, _) = try await Self.dismiss([FakeUI.tree([Self.toast(2)])], timeout: "2")

        #expect(outcome.remaining == 2 && outcome.cleared == 0)
        #expect(outcome.jsonLine() == #"{"version":1,"cleared":0,"remaining":2,"method":"none"}"#)
    }

    @Test("a screen without LogBox sends nothing")
    func nothingToClear() async throws {
        let (outcome, backend) = try await Self.dismiss([FakeUI.tree()])

        #expect(outcome == LogBoxDismissal(cleared: 0, remaining: 0, method: .none))
        #expect(backend.session.calls.isEmpty)
    }

    @Test("status reads the toasts as JSON")
    func statusJSON() {
        let state = LogBoxState(tree: FakeUI.tree([Self.toast(2)]))
        #expect(state.jsonLine() == #"{"version":1,"logs":2,"toasts":[{"count":2,"frame":{"x":10,"y":806,"width":382,"height":48}}],"inspector":false}"#)
        #expect(state.textLine() == "LogBox: 2 logs in 1 toast")
    }
}
