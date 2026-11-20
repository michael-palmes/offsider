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

    @Test("the emulator hint names the SDK's adb by its full path, quoted when it needs it, as adb may not be on PATH")
    func hintNamesSDKPath() {
        let keyboard = Self.form(focused: "second-field", keyboardField: true).roots.last!
        let plain = Type.keyboardFocusRefusal(keyboard, target: nil, device: Self.android, adb: "/opt/android-sdk/platform-tools/adb")
        #expect(plain.hint == "/opt/android-sdk/platform-tools/adb -s emulator-5554 shell settings put secure stylus_handwriting_enabled 0")
        let spaced = Type.textNotLandedRefusal(keyboard: keyboard, target: "id=second-field", device: Self.android, adb: "/opt/android sdk/platform-tools/adb")
        #expect(spaced.hint == "'/opt/android sdk/platform-tools/adb' -s emulator-5554 shell settings put secure stylus_handwriting_enabled 0")
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

    @Test("--replace --verify reads the same with the keyboard's field focused, as its set-text never goes through the keyboard")
    func replaceVerifyIgnoresKeyboard() {
        let typed = TypedExpectation(text: "123456", replacing: true, field: nil, query: .id("second-field"), secure: false, ignoringText: false)
        let withKeyboard = typed.check(before: nil, after: Self.form(focused: "second-field", value: "2 of 6 digits", keyboardField: true))
        #expect(withKeyboard == typed.check(before: nil, after: Self.form(focused: "second-field", value: "2 of 6 digits")))
        #expect(withKeyboard != .differs)
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

    @Test("a read that fails is tried again until the deadline, so a slow dump never lets keys the tutorial took pass")
    func failedReadRetried() async throws {
        var reads = 0
        let typed = TypedExpectation(text: "abc", replacing: false, field: nil, query: .id("second-field"), secure: false, ignoringText: false)
        let error = await #expect(throws: CLIError.self) {
            try await Type.confirmLanded(typed, before: nil, target: "id=second-field", device: Self.android, clock: ScriptedClock().poll) {
                reads += 1
                if reads == 1 { throw CLIError(errorDescription: "slow dump", reason: .helperTimedOut) }
                return Self.form(focused: "second-field", keyboardField: true)
            }
        }
        #expect(error?.reason == .textNotAccepted)
    }

    @Test("retyping the text a field already held passes, as a field that selects its text on focus ends the same")
    func sameTextRetyped() async throws {
        let typed = TypedExpectation(text: "abc", replacing: false, field: nil, query: .id("second-field"), secure: false, ignoringText: false)
        try await Type.confirmLanded(typed, before: "abc", target: "id=second-field", device: Self.android, clock: ScriptedClock().poll) {
            Self.form(focused: "second-field", value: "abc")
        }
    }

    @Test("a value too long to judge passes with a keyboard field focused, as the text may all be there")
    func longValueNotJudged() async throws {
        let long = String(repeating: "x", count: 600)
        let typed = TypedExpectation(text: "abc", replacing: false, field: nil, query: .id("second-field"), secure: false, ignoringText: false)
        try await Type.confirmLanded(typed, before: long, target: "id=second-field", device: Self.android, clock: ScriptedClock().poll) {
            Self.form(focused: "second-field", value: long + "abc", keyboardField: true)
        }
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

    @Test("plain type reads back the field that had focus: keys a tutorial opening after the check took are exit 5 text_not_accepted, never the text")
    func plainTypeTutorialAfterCheck() async throws {
        let backend = StagedBackend([Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true)])
        let error = await #expect(throws: CLIError.self) {
            try await Self.type(["s3cret-ish"], on: backend)
        }
        #expect(error?.reason == .textNotAccepted)
        let message = error?.userFacingDescription ?? ""
        #expect(message.contains("Typed into id=second-field, but its text did not change") && message.contains("stylus handwriting tutorial"), "\(message)")
        #expect(!message.contains("s3cret-ish"))
        #expect(error?.hint == "adb -s emulator-5554 shell settings put secure stylus_handwriting_enabled 0")
        #expect(backend.text.calls == [.typeText("s3cret-ish")])
    }

    @Test("plain type passes once the text shows in the field that had focus")
    func plainTypeLanded() async throws {
        let backend = StagedBackend([Self.form(focused: "second-field"), Self.form(focused: "second-field", value: "abc")])
        try await Self.type(["abc"], on: backend)
        #expect(backend.text.calls == [.typeText("abc")])
    }

    @Test("plain type never reads a password field back, so an unchanged one passes")
    func plainTypePasswordNotJudged() async throws {
        let backend = StagedBackend([Self.form(focused: "second-field", secure: true), Self.form(focused: "second-field", secure: true)])
        try await Self.type(["abc"], on: backend)
        #expect(backend.text.calls == [.typeText("abc")])
    }

    @Test("plain --replace is not read back, as its set-text checks itself")
    func plainReplaceNotReadBack() async throws {
        let backend = StagedBackend([Self.form(focused: "second-field"), Self.form(focused: "second-field")])
        try await Self.type(["--replace", "abc"], on: backend)
        #expect(backend.text.calls == [.replaceText("abc")])
    }

    @Test("plain type into a focused web view is not read back, as its page holds the text, not its value")
    func webViewNotJudged() async throws {
        let web = UINode(
            role: .other, id: "page", frame: FakeUI.frame(0, 100, 402, 600), state: UIState(focused: true),
            native: .android(AndroidNativeAttributes(className: "android.webkit.WebView"))
        )
        let tree = FakeUI.tree(platform: .android, [web])
        try await Self.type(["abc"], on: StagedBackend([tree]))
    }

    static func batch(_ steps: [String], on backend: StagedBackend) async throws -> [String] {
        let context = BatchContext(backend: backend, device: Self.android, axCachePolicy: .perStep, typeSubmissionMode: .chunked, typeChunkSize: 200)
        var lines: [String] = []
        let output = BatchOutput(json: true, write: { lines.append($0) }, writeError: { _ in })
        do {
            try await TypeIntoTests.quiet {
                try await Batch.runSteps(steps, context: context, session: backend.makeSession(), continueOnError: false, output: output, logger: OffsiderLogger())
            }
        } catch {
            lines.append("threw")
        }
        return lines
    }

    @Test("a batch tap then plain type fails with text_not_accepted when the tutorial opens after the type step's check, and passes when the text lands")
    func batchTapThenType() async throws {
        let lost = StagedBackend([
            Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true),
        ])
        let failed = try await Self.batch(["tap --id second-field", "type abc"], on: lost)
        #expect(failed.contains("threw") && failed.joined().contains("text_not_accepted"), "\(failed)")
        #expect(lost.text.calls.last == .typeText("abc"))

        let landed = StagedBackend([
            Self.form(focused: nil), Self.form(focused: "second-field"), Self.form(focused: "second-field", value: "abc"),
        ])
        let passed = try await Self.batch(["tap --id second-field", "type abc"], on: landed)
        #expect(!passed.contains("threw") && !passed.joined().contains("text_not_accepted"), "\(passed)")
        #expect(landed.text.calls.last == .typeText("abc"))
    }

    static func keySequence(_ keycodes: String, on backend: StagedBackend) async throws {
        try await TypeIntoTests.quiet {
            try await KeySequence.parse(["--keycodes", keycodes, "--delay", "0", "--device", Self.android.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.android), logger: OffsiderLogger())
        }
    }

    @Test("a key-sequence that spells text is read back as type is: keys the tutorial took are exit 5 text_not_accepted")
    func keySequenceReadBack() async throws {
        let lost = StagedBackend([Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true)])
        let error = await #expect(throws: CLIError.self) { try await Self.keySequence("11,8,15,15,18", on: lost) }
        #expect(error?.reason == .textNotAccepted)
        let message = error?.userFacingDescription ?? ""
        #expect(message.contains("Pressed the keys into id=second-field") && message.contains("type --replace") && !message.contains("hello"), "\(message)")

        try await Self.keySequence("11,8,15,15,18", on: StagedBackend([Self.form(focused: "second-field"), Self.form(focused: "second-field", value: "hello")]))
    }

    @Test("keys the tutorial took name the fix for where they went: stylus off on an emulator, close it on a phone, never --replace, which key-sequence lacks")
    func keysRefusalFix() {
        let keyboard = Self.form(focused: "second-field", keyboardField: true).roots.last!
        let emulator = Type.textNotLandedRefusal(keyboard: keyboard, target: "id=second-field", device: Self.android, keys: true)
        let phone = Type.textNotLandedRefusal(keyboard: keyboard, target: "id=second-field", device: Self.phone, keys: true)
        #expect(emulator.userFacingDescription.contains("Turn stylus handwriting off") && !emulator.userFacingDescription.contains("run it again with --replace"))
        #expect(phone.userFacingDescription.contains("Close it on the phone") && phone.hint?.contains("settings") == false)
    }

    @Test("a key-sequence with Return, Delete or arrows in it is not read back, as no text can be expected from it")
    func keySequenceWithControlKeys() async throws {
        let unchanged = [Self.form(focused: "second-field"), Self.form(focused: "second-field", keyboardField: true)]
        try await Self.keySequence("4,42", on: StagedBackend(unchanged))
        try await Self.keySequence("4,5,40", on: StagedBackend(unchanged))
    }

    @Test("keys spell text only when each is a letter, digit, space or punctuation mark")
    func spelledText() {
        #expect(KeySequence.spelledText([11, 8, 15, 15, 18]) == "hello")
        #expect(KeySequence.spelledText(Array(30...39)) == "1234567890")
        #expect(KeySequence.spelledText([44, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56]) == " -=[]\\;'`,./")
        #expect(KeySequence.spelledText([4, 42]) == nil)
        #expect(KeySequence.spelledText([225, 4]) == nil)
        #expect(KeySequence.spelledText([50]) == nil)
        #expect(KeySequence.spelledText([89]) == nil)
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
