import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Disabled targets")
@MainActor
struct DisabledTargetTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func screen(continueEnabled: Bool?) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "continue", label: "Continue", frame: FakeUI.frame(20, 600, 350, 44), enabled: continueEnabled),
        ])
    }

    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async throws {
        try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
    }

    @Test("a selector tap on a control that says it is disabled exits 1 target_disabled, offers the wait, and sends nothing")
    func disabledRefuses() async {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: false)])
        let tracker = DispatchTracker()

        let error = await #expect(throws: CLIError.self) {
            try await DispatchTracker.$current.withValue(tracker) {
                try await Self.tap(["--id", "continue"], on: backend)
            }
        }

        #expect(error?.reason == .targetDisabled)
        #expect(error?.reason.exitCode == .failure)
        #expect(error?.userFacingDescription.hasPrefix("--id 'continue' is disabled, so the tap would do nothing. Nothing was sent.") == true)
        #expect(error?.userFacingDescription.hasSuffix("or pass --allow-disabled to tap anyway.") == true)
        #expect(error?.hint == "offsider wait --id continue --enabled --timeout 10 --device fake-device")
        #expect(error?.candidates.map(\.id) == ["continue"])
        #expect(tracker.state == .no)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a control that does not say whether it is enabled, or says it is, is tapped", arguments: [nil, true] as [Bool?])
    func enabledOrSilentTaps(enabled: Bool?) async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: enabled)])

        try await Self.tap(["--id", "continue"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("under --wait-timeout a control still loading is read again and tapped once it is enabled")
    func waitsForEnabled() async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: false), Self.screen(continueEnabled: false), Self.screen(continueEnabled: true)])

        try await Self.tap(["--id", "continue", "--wait-timeout", "5", "--poll-interval", "0.01"], on: backend)

        #expect(backend.treeReads == 3)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("text that says it is disabled inside an enabled row is tapped, as the row takes the touch")
    func disabledTextInEnabledRowTaps() async throws {
        let row = FakeUI.node(.cell, id: "row", frame: FakeUI.frame(0, 600, 393, 60), enabled: true, children: [
            FakeUI.node(.text, label: "Notifications", frame: FakeUI.frame(20, 610, 200, 40), enabled: false),
        ])
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 393, height: 852, [row])])

        try await Self.tap(["--label", "Notifications"], on: backend)

        #expect(backend.session.calls.count == 1)
    }

    @Test("text inside a disabled control refuses, naming the control")
    func textInDisabledControlRefuses() async {
        let button = FakeUI.node(.button, id: "pay", frame: FakeUI.frame(20, 600, 350, 44), enabled: false, children: [
            FakeUI.node(.text, label: "Pay now", frame: FakeUI.frame(40, 610, 200, 24)),
        ])
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 393, height: 852, [button])])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--label", "Pay now"], on: backend)
        }

        #expect(error?.reason == .targetDisabled)
        #expect(error?.userFacingDescription.hasPrefix("--label 'Pay now' is inside a disabled button \"pay\" (20, 600) 350x44, so the tap would do nothing.") == true)
        #expect(error?.hint == "offsider wait --label 'Pay now' --enabled --timeout 10 --device fake-device")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--allow-disabled taps with a warning, to prove a disabled control does nothing")
    func allowDisabledWarns() async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: false)])
        let capture = ConsoleCapture()

        try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await Self.tap(["--id", "continue", "--allow-disabled"], on: backend)
        }

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
        #expect(capture.err.contains("--id 'continue' is disabled; tapping anyway because of --allow-disabled."))
    }

    @Test("a coordinate tap on a disabled control is sent as before")
    func coordinateTapUnchanged() async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: false)])

        try await Self.tap(["-x", "195", "-y", "622"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("a batch tap step on a disabled control refuses before anything is sent")
    func batchRefuses() async {
        let backend = FakeDeviceBackend(trees: [Self.screen(continueEnabled: false)])
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, noSettle: true)

        let error = await #expect(throws: ReportedFailure.self) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Batch.runSteps(["tap --id continue"], context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())
            }
        }

        #expect(error?.exitCode == .failure)
        #expect(error?.userFacingDescription.hasPrefix("Step 1 failed: [tap]\n--id 'continue' is disabled, so the tap would do nothing.") == true)
        #expect(error?.userFacingDescription.hasSuffix("Dispatched: no") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("type --into-id on a disabled field refuses before the tap, with no way round it offered")
    func typeIntoRefuses() async {
        let android = DeviceID(rawValue: "emulator-5554", platform: .android)
        let form = FakeUI.tree(platform: .android, [
            FakeUI.node(.textField, id: "email", label: "Email", frame: FakeUI.frame(20, 300, 360, 44), enabled: false, platform: .android),
        ])
        let backend = FakeDeviceBackend(platform: .android, trees: [form])
        var sent: [InputEvent] = []

        let error = await #expect(throws: CLIError.self) {
            try await Type.parse(["--into-id", "email", "text", "--device", android.rawValue]).ensureFocus(
                backend: backend, device: android, logger: OffsiderLogger(), clock: ScriptedClock().poll, warn: { _ in }
            ) { sent.append($0) }
        }

        #expect(error?.reason == .targetDisabled)
        #expect(error?.userFacingDescription.hasSuffix("Wait for it to be enabled (`offsider wait --id email --enabled --timeout 10 --device emulator-5554`).") == true)
        #expect(sent.isEmpty)
    }
}
