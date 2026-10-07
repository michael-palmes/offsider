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

    @Test("a toast whose clear button works takes one tap at its right-hand end, mapped through the first read, and one read to confirm")
    func buttonPath() async throws {
        let (outcome, backend) = try await Self.dismiss([FakeUI.tree([Self.toast(1)]), FakeUI.tree()])

        #expect(outcome == LogBoxDismissal(cleared: 1, remaining: 0, method: .dismissButton))
        #expect(backend.session.calls == [.perform(.tapAt(x: 370, y: 830))])
        #expect(backend.treeReads == 2)
    }

    @Test("stacked toasts clear bottom first, with one read after each clear and no read of its own for a tap")
    func stackedButtons() async throws {
        let (outcome, backend) = try await Self.dismiss([
            Self.stacked(),
            FakeUI.tree([FakeUI.node(.other, label: "!, Login failed for token=abc123def456", frame: FakeUI.frame(10, 806, 382, 48))]),
            FakeUI.tree(),
        ])

        #expect(outcome == LogBoxDismissal(cleared: 2, remaining: 0, method: .dismissButton))
        #expect(backend.session.calls == [.perform(.tapAt(x: 370, y: 830)), .perform(.tapAt(x: 370, y: 830))])
        #expect(backend.treeReads == 3)
        #expect(backend.openedSessions.count == 1)
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
        #expect(backend.openedSessions.count == 1)
        #expect(backend.session.isClosed)
        #expect(backend.treeReads == 4)
    }

    @Test("an open inspector takes one Dismiss per log it counts, then a single read confirms it closed")
    func openInspectorPressesPerLog() async throws {
        let (outcome, backend) = try await Self.dismiss([
            FakeUI.tree(Self.inspector(log: 1, of: 2)), FakeUI.tree(Self.inspector(log: 1, of: 1)), FakeUI.tree(),
        ])

        #expect(outcome == LogBoxDismissal(cleared: 2, remaining: 0, method: .inspector))
        #expect(backend.session.calls == [.perform(.tapAt(x: 100, y: 847)), .perform(.tapAt(x: 100, y: 847))])
        #expect(backend.treeReads == 2)
    }

    @Test("a Dismiss the inspector misses is made up after the read, and never pressed past its last log")
    func missedDismissIsMadeUp() async throws {
        let (outcome, backend) = try await Self.dismiss([
            FakeUI.tree(Self.inspector(log: 1, of: 2)), FakeUI.tree(Self.inspector(log: 1, of: 2)),
            FakeUI.tree(Self.inspector(log: 1, of: 1)), FakeUI.tree(),
        ])

        #expect(outcome == LogBoxDismissal(cleared: 2, remaining: 0, method: .inspector))
        #expect(backend.session.calls == [RecordingInputSession.Call](repeating: .perform(.tapAt(x: 100, y: 847)), count: 3))
        #expect(backend.treeReads == 3)
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

    @Test("status reads each toast's index, count and message as JSON")
    func statusJSON() {
        let state = LogBoxState(tree: FakeUI.tree([Self.toast(2)]))
        #expect(state.jsonLine() == #"{"version":1,"logs":2,"toasts":[{"index":1,"count":2,"message":"Request failed","frame":{"x":10,"y":806,"width":382,"height":48}}],"inspector":false}"#)
        #expect(state.text() == "LogBox: 2 logs in 1 toast, bottom first\n  1. Request failed (2 logs)")
    }

    static func stacked() -> UITree {
        FakeUI.tree([
            FakeUI.node(.other, label: "!, Login failed for token=abc123def456", frame: FakeUI.frame(10, 754, 382, 48)),
            FakeUI.node(.other, label: "!, OffsiderFixture error", frame: FakeUI.frame(10, 806, 382, 48)),
        ])
    }

    @Test("status numbers stacked toasts from the bottom and redacts their messages unless asked not to")
    func statusRedacts() {
        let state = LogBoxState(tree: Self.stacked())
        #expect(state.text() == "LogBox: 2 logs in 2 toasts, bottom first\n  1. OffsiderFixture error\n  2. Login failed for token=[redacted]")
        #expect(state.text(redacts: false).hasSuffix("2. Login failed for token=abc123def456"))
        #expect(state.jsonLine().contains(#""index":2,"count":1,"message":"Login failed for token=[redacted]""#))
    }

    static func open(_ trees: [UITree], index: Int = 1) async throws -> (LogBoxOpening, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(trees: trees, advanceTreeOnInput: true)
        let command = try RNLogBoxOpen.parse(["--index", String(index), "--device", device.rawValue])
        let opened = try await command.open(on: DeviceRouter.Route(backend: backend, device: device), clock: ScriptedClock().poll)
        return (opened, backend)
    }

    @Test("open taps the chosen toast's body and waits for the inspector")
    func openTapsBody() async throws {
        let (opened, backend) = try await Self.open([Self.stacked(), FakeUI.tree(Self.inspector(log: 1, of: 2))], index: 2)

        #expect(opened.toast?.index == 2)
        #expect(opened.inspector.of == 2)
        #expect(backend.session.calls == [.perform(.tapAt(x: 162.8, y: 778))])
        #expect(backend.treeReads == 2)
        #expect(backend.session.isClosed)
        #expect(opened.jsonLine(redacts: true) == #"{"version":1,"index":2,"message":"Login failed for token=[redacted]","log":1,"of":2}"#)
        #expect(opened.textLine(redacts: true) == "✓ Opened LogBox toast 2 (Login failed for token=[redacted]): log 1 of 2")
    }

    @Test("open with the inspector already up reports it without a tap")
    func openAlreadyOpen() async throws {
        let (opened, backend) = try await Self.open([FakeUI.tree(Self.inspector(log: 2, of: 3))])

        #expect(opened.toast == nil)
        #expect(backend.session.calls.isEmpty)
        #expect(opened.textLine(redacts: true) == "LogBox inspector already open: log 2 of 3")
    }

    @Test("open on a toast that is not there exits 2 with the toasts as candidates, and sends nothing")
    func openMissingToast() async throws {
        let backend = FakeDeviceBackend(trees: [Self.stacked()])
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNLogBoxOpen.parse(["--index", "3", "--device", Self.device.rawValue])
                .open(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .selectorNotFound)
        #expect(error?.candidates.map(\.index) == [1, 2])
        #expect(backend.session.calls.isEmpty)
    }

    @Test("open exits 5 when the inspector never comes up")
    func openNeverOpens() async throws {
        let backend = FakeDeviceBackend(trees: [Self.stacked()])
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNLogBoxOpen.parse(["--device", Self.device.rawValue])
                .open(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .notVerified)
    }

    @Test("dismiss --index clears only that toast through its clear button")
    func dismissIndex() async throws {
        let backend = FakeDeviceBackend(trees: [Self.stacked(), FakeUI.tree([FakeUI.node(.other, label: "!, OffsiderFixture error", frame: FakeUI.frame(10, 806, 382, 48))])], advanceTreeOnInput: true)
        let outcome = try await RNLogBoxDismiss.parse(["--index", "2", "--device", Self.device.rawValue])
            .dismiss(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == LogBoxDismissal(cleared: 1, remaining: 0, method: .dismissButton))
        #expect(backend.session.calls == [.perform(.tapAt(x: 370, y: 778))])
    }

    @Test("dismiss --index refuses while the inspector hides the toasts, and for a toast that is not there")
    func dismissIndexRefusals() async throws {
        for (trees, reason) in [([FakeUI.tree(Self.inspector(log: 1, of: 1))], FailureReason.stateNotReached), ([Self.stacked()], .selectorNotFound)] {
            let backend = FakeDeviceBackend(trees: trees)
            let error = await #expect(throws: CLIError.self) {
                _ = try await RNLogBoxDismiss.parse(["--index", "3", "--device", Self.device.rawValue])
                    .dismiss(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
            }
            #expect(error?.reason == reason)
            #expect(backend.session.calls.isEmpty)
        }
    }
}
