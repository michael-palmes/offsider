import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Gboard's stylus handwriting tutorial: a field inside the keyboard takes the keys while the app's field still reports focus.
@Suite("type with a field inside the keyboard holding focus")
@MainActor
struct TypeKeyboardFocusTests {
    static let android = TypeIntoTests.android
    static let phone = DeviceID(rawValue: "0123456789ABCDEF", platform: .android)
    static let simulator = TypeIntoTests.simulator

    /// Two fields; `keyboardField` adds Gboard with its tutorial's practice field focused.
    static func form(
        focused: String?, value: String? = nil, keyboardField: Bool = false, secure: Bool = false, platform: DevicePlatform = .android
    ) -> UITree {
        let first = FakeUI.node(
            .textField, id: "first-field", label: "first-field", frame: FakeUI.frame(20, 200, 360, 44),
            state: UIState(focused: focused == "first-field" ? true : nil), platform: platform
        )
        let second = FakeUI.node(
            secure ? .secureTextField : .textField, id: "second-field", label: "second-field", value: value, frame: FakeUI.frame(20, 300, 360, 44),
            state: UIState(focused: focused == "second-field" ? true : nil), platform: platform
        )
        var tree = FakeUI.tree(platform: platform, [first, second])
        if keyboardField {
            let practice = FakeUI.node(.textField, frame: FakeUI.frame(64, 704, 283, 58), state: UIState(focused: true), platform: platform)
            tree.roots.append(FakeUI.node(.keyboard, label: "Gboard", frame: FakeUI.frame(0, 468, 402, 406), platform: platform, children: [practice]))
        }
        return tree
    }

    /// Serves one tree per stage, moving on with each input: before the tap, after it, then after the text.
    final class StagedBackend: FakeDeviceBackend {
        let stages: [UITree]
        let text = RecordingTextInputSession()
        private(set) var inputs = 0

        init(_ stages: [UITree], platform: DevicePlatform = .android) {
            self.stages = stages
            super.init(platform: platform, trees: stages)
        }

        override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
            stages[min(inputs, stages.count - 1)]
        }

        override func openInputSession(for id: DeviceID) async throws -> any InputSession { makeSession() }

        func makeSession() -> StagingSession {
            StagingSession(inner: text) { [unowned self] in inputs += 1 }
        }
    }

    final class StagingSession: TextInputSession {
        let inner: RecordingTextInputSession
        let onInput: () -> Void
        var device: DeviceID { inner.device }
        init(inner: RecordingTextInputSession, onInput: @escaping () -> Void) {
            self.inner = inner
            self.onInput = onInput
        }
        func perform(_ event: InputEvent) async throws {
            try await inner.perform(event)
            onInput()
        }
        func typeText(_ text: String) async throws {
            try await inner.typeText(text)
            onInput()
        }
        func replaceText(_ text: String) async throws {
            try await inner.replaceText(text)
            onInput()
        }
        func close() async {}
    }

    static func type(_ arguments: [String], on backend: StagedBackend, device: DeviceID = android) async throws {
        try await TypeIntoTests.quiet {
            try await Type.parse(arguments + ["--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
        }
    }

    @Test("--into-id with the keyboard's own field focused after the tap is exit 2 focus_mismatch naming the tutorial and the fix, and types nothing")
    func intoIDRefusedBeforeTyping() async throws {
        let backend = StagedBackend([Self.form(focused: nil), Self.form(focused: "second-field", keyboardField: true)])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(["--into-id", "second-field", "abc"], on: backend)
        }
        #expect(error?.reason == .focusMismatch)
        #expect(error?.exitCode == .selectorNotFound)
        let message = error?.userFacingDescription ?? ""
        #expect(message.contains("Gboard") && message.contains("stylus handwriting tutorial") && message.contains("id=second-field"), "\(message)")
        #expect(message.contains("--replace"), "\(message)")
        #expect(error?.hint == "adb -s emulator-5554 shell settings put secure stylus_handwriting_enabled 0")
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322))])
    }

    @Test("--require-focus-id and plain type refuse the same way before any key goes out", arguments: [["--require-focus-id", "second-field"], []])
    func focusedFieldRefused(focus: [String]) async throws {
        let backend = StagedBackend([Self.form(focused: "second-field", keyboardField: true)])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(focus + ["abc"], on: backend)
        }
        #expect(error?.reason == .focusMismatch)
        #expect(error?.userFacingDescription.contains("Offsider typed nothing") == true)
        #expect(backend.text.calls.isEmpty)
    }

    @Test("a key-sequence that spells text presses no keys while the keyboard's own field has focus")
    func keySequenceRefused() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Type.checkTextFocus(
                readTree: { Self.form(focused: "second-field", keyboardField: true) }, device: Self.android, clock: ScriptedClock().poll,
                warn: { _ in }, refusingSecureTarget: nil, keys: true
            )
        }
        #expect(error?.reason == .focusMismatch)
        #expect(error?.userFacingDescription.contains("pressed no keys") == true)
    }

    @Test("on a phone the fix is to close it there, and no adb command changes its settings")
    func phoneFix() async throws {
        let backend = StagedBackend([Self.form(focused: "second-field", keyboardField: true)])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(["--require-focus-id", "second-field", "abc"], on: backend, device: Self.phone)
        }
        #expect(error?.userFacingDescription.contains("Close it on the phone") == true)
        #expect(error?.hint?.contains("settings") == false)
    }

    @Test("--replace sets the text without keys, so the keyboard's own field does not stop it")
    func replaceStillTypes() async throws {
        let backend = StagedBackend([Self.form(focused: nil), Self.form(focused: "second-field", keyboardField: true)])
        try await Self.type(["--into-id", "second-field", "--replace", "abc"], on: backend)
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322)), .replaceText("abc")])
    }

    @Test("keys a tutorial opening after the focus check takes leave the field as it was: exit 5 text_not_accepted naming it, never the text")
    func tutorialAfterFocusCheck() async throws {
        let backend = StagedBackend([
            Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true),
        ])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(["--into-id", "second-field", "s3cret-ish"], on: backend)
        }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.exitCode == .unverified)
        let message = error?.userFacingDescription ?? ""
        #expect(message.contains("Typed into id=second-field, but its text did not change") && message.contains("stylus handwriting tutorial"), "\(message)")
        #expect(!message.contains("s3cret-ish"))
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322)), .typeText("s3cret-ish")])
    }

    @Test("under --verify, keys the tutorial took fail the read-back, as an empty Android field reads as no value")
    func verifyCatchesTutorial() async throws {
        let backend = StagedBackend([
            Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true),
        ])
        #expect(try await TypeIntoTests.verifying(["abc", "--into-id", "second-field", "--verify", "--verify-timeout", "0.5"], backend: backend, device: Self.android))
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322)), .typeText("abc")])
    }

    @Test("a named field whose text did not change with no keyboard field in sight is exit 5 text_not_accepted too")
    func unchangedWithoutKeyboard() async throws {
        let backend = StagedBackend([Self.form(focused: nil, value: "12"), Self.form(focused: "second-field", value: "12")])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(["--into-id", "second-field", "abc"], on: backend)
        }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.userFacingDescription.contains("went somewhere else or the app ignored them") == true)
    }

    @Test("text that reached the field passes on the first read")
    func landedPasses() async throws {
        let backend = StagedBackend([Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", value: "abc")])
        try await Self.type(["--into-id", "second-field", "abc"], on: backend)
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322)), .typeText("abc")])
    }

    @Test("a password field's value is never judged, so an unchanged one passes and nothing about it is printed")
    func passwordNotJudged() async throws {
        let backend = StagedBackend([Self.form(focused: nil, secure: true), Self.form(focused: "second-field", secure: true)])
        try await Self.type(["--into-id", "second-field", "abc"], on: backend)
        #expect(backend.text.calls.last == .typeText("abc"))
    }

    static func landing(_ value: String?, keyboardField: Bool) async throws {
        let tree = Self.form(focused: "second-field", value: value, keyboardField: keyboardField)
        let typed = TypedExpectation(text: "abcdef", replacing: false, field: nil, query: .id("second-field"), secure: false, ignoringText: false)
        try await Type.confirmLanded(typed, before: nil, target: "id=second-field", device: Self.android, clock: ScriptedClock().poll) { tree }
    }

    @Test("part of the text is enough without a keyboard field, as a field that cuts its text shows; with one holding focus it is not")
    func partialText() async throws {
        try await Self.landing("abc", keyboardField: false)
        try await Self.landing("ABCDEF", keyboardField: true)
        let error = await #expect(throws: CLIError.self) { try await Self.landing("abc", keyboardField: true) }
        #expect(error?.reason == .textNotAccepted)
    }

    @Test("a batch type step reads its field back too, and fails when the keys did not reach it")
    func batchStep() async throws {
        let backend = StagedBackend([
            Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true),
        ])
        let context = BatchContext(backend: backend, device: Self.android, axCachePolicy: .perStep, typeSubmissionMode: .chunked, typeChunkSize: 200)
        var lines: [String] = []
        let output = BatchOutput(json: true, write: { lines.append($0) }, writeError: { _ in })
        await #expect(throws: (any Error).self) {
            try await TypeIntoTests.quiet {
                try await Batch.runSteps(
                    ["type --into-id second-field abc"], context: context, session: backend.makeSession(), continueOnError: false, output: output, logger: OffsiderLogger()
                )
            }
        }
        #expect(backend.text.calls == [.perform(.tapAt(x: 200, y: 322)), .typeText("abc")])
        #expect(lines.joined().contains("text_not_accepted"), "\(lines)")
    }

    @Test("an iOS simulator keeps its behaviour: a keyboard's own focused field is not read as Gboard's")
    func iosUnchanged() async throws {
        let sent = try await TypeIntoTests.focus(
            ["--into-id", "second-field"],
            trees: [Self.form(focused: nil, platform: .ios), Self.form(focused: "second-field", keyboardField: true, platform: .ios)],
            device: Self.simulator
        )
        #expect(sent == [.tapAt(x: 200, y: 322)])
    }
}
