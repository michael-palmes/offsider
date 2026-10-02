import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android type --replace")
@MainActor
struct AndroidReplaceTextTests {
    static let device = HelperRig.device
    nonisolated static let replaced = #"{"className":"android.widget.EditText","resourceId":"text-input-field","length":3}"#

    static func rig(
        _ device: FakeHelperDevice = FakeHelperDevice(),
        environment: [String: String] = [:],
        setText: FakeHelperDevice.Answer = .ok(replaced)
    ) throws -> HelperRig {
        device.answer = { _, op, _ in op == "setText" ? setText : nil }
        return try HelperRig(device, environment: environment)
    }

    static func replace(_ text: String, on rig: HelperRig) async throws {
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        do {
            try await session.replaceText(text)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// The `input` scripts the session ran, in order.
    static func inputScripts(_ rig: HelperRig) -> [String] {
        rig.server.services
            .filter { $0.hasPrefix("shell,v2,raw:input ") }
            .map { String($0.dropFirst("shell,v2,raw:".count)) }
    }

    static func sentText(_ rig: HelperRig) throws -> String? {
        let frame = try #require(rig.device.frames.first { $0.op == "setText" })
        let object = try JSONSerialization.jsonObject(with: Data(frame.json.utf8)) as? NSDictionary
        return object?["text"] as? String
    }

    @Test("the helper sets the focused field's text in one action, any Unicode included, with no key events")
    func setsText() async throws {
        let rig = try Self.rig()
        try await Self.replace("héllo 日本", on: rig)

        #expect(try Self.sentText(rig) == "héllo 日本")
        #expect(Self.inputScripts(rig).isEmpty)
        #expect(rig.log.warnings.isEmpty)
        await rig.backend.close()
    }

    @Test("a trailing newline is set without it, then pressed as Return; other newlines are set literally")
    func trailingNewline() async throws {
        let rig = try Self.rig()
        try await Self.replace("one\ntwo\n", on: rig)

        #expect(try Self.sentText(rig) == "one\ntwo")
        #expect(Self.inputScripts(rig) == ["input keyevent 66"])
        await rig.backend.close()
    }

    @Test("with nothing focused, the error says to tap the field first")
    func noFocus() async throws {
        let rig = try Self.rig(setText: .error(code: "no-focus", message: "nothing has input focus"))
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .noFocusedField)
        #expect(error?.message == "type --replace needs a focused text field on emulator-5556, and nothing has input focus. Tap the field first, for example `offsider tap --id <field> --device emulator-5556`.")
        #expect(Self.inputScripts(rig).isEmpty)
        await rig.backend.close()
    }

    @Test("a focused element that is not editable is named by its class and id")
    func notEditable() async throws {
        let rig = try Self.rig(setText: .error(
            code: "not-editable", message: "the element with input focus is not editable", className: "android.widget.Button", resourceId: "submit"
        ))
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .fieldNotEditable)
        #expect(error?.message == "The element with input focus on emulator-5556 (`android.widget.Button`, id `submit`) is not a text field, so type --replace cannot set its text. Tap the text field first.")
        await rig.backend.close()
    }

    @Test("a field without the set-text action warns once, then clears with Ctrl+A and Delete and types the text")
    func actionUnsupported() async throws {
        let rig = try Self.rig(setText: .error(code: "action-unsupported", message: "android.widget.EditText does not offer ACTION_SET_TEXT"))
        try await Self.replace("bye\n", on: rig)

        #expect(rig.log.warnings == [
            "The focused field on emulator-5556 does not accept replacement text (android.widget.EditText does not offer ACTION_SET_TEXT), so Offsider clears it with Ctrl+A and Delete, then types.",
        ])
        let scripts = Self.inputScripts(rig)
        #expect(scripts.first == "input keycombination 113 29 && sleep 0.05 && input keyevent 67")
        #expect(scripts.dropFirst().joined(separator: " && ").contains("input text 'bye'"))
        #expect(scripts.last?.hasSuffix("input keyevent 66") == true)
        await rig.backend.close()
    }

    @Test("an unavailable helper warns about replace alone, keys the text, and the screen read later still warns once")
    func helperUnavailable() async throws {
        let rig = try Self.rig(FakeHelperDevice(starts: [.exit(status: 6, stderr: "java.lang.VerifyError: bad dex\n")]))
        try await Self.replace("bye", on: rig)

        #expect(rig.log.warnings == [
            "type --replace could not use the UiAutomation helper on emulator-5556 (it exited with status 6 before it was ready: java.lang.VerifyError: bad dex), so Offsider clears the field with Ctrl+A and Delete, then types.",
        ])
        #expect(Self.inputScripts(rig).first == "input keycombination 113 29 && sleep 0.05 && input keyevent 67")

        _ = try await rig.read()
        _ = try await rig.read()
        #expect(rig.log.warnings.count == 2)
        #expect(rig.log.warnings.last?.hasPrefix("The UiAutomation helper is unavailable on emulator-5556") == true)
        #expect(rig.startShells == 1)
    }

    @Test("with OFFSIDER_ANDROID_TREE=uiautomator, replace uses keys silently and never starts the helper")
    func forcedUIAutomator() async throws {
        let rig = try Self.rig(environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        try await Self.replace("", on: rig)

        #expect(rig.log.warnings.isEmpty)
        #expect(rig.startShells == 0)
        #expect(Self.inputScripts(rig) == ["input keycombination 113 29 && sleep 0.05 && input keyevent 67"])
    }

    @Test("a busy UiAutomation slot is an error, never a key fallback")
    func busy() async throws {
        let rig = try Self.rig(FakeHelperDevice(starts: [AndroidBackendHelperTests.busy]))
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .helperBusy)
        #expect(Self.inputScripts(rig).isEmpty)
    }
}
