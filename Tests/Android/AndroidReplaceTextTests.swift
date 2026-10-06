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
        #expect(rig.device.injected == ["key press 66 meta 0"])
        #expect(Self.inputScripts(rig).isEmpty)
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

    @Test("a field without the set-text action warns once, then clears with Ctrl+A and Delete and types the text through the running helper")
    func actionUnsupported() async throws {
        let rig = try Self.rig(setText: .error(code: "action-unsupported", message: "android.widget.EditText does not offer ACTION_SET_TEXT"))
        try await Self.replace("bye\n", on: rig)

        #expect(rig.log.warnings == [
            "The focused field on emulator-5556 does not accept replacement text (android.widget.EditText does not offer ACTION_SET_TEXT), so Offsider clears it with Ctrl+A and Delete, then types.",
        ])
        #expect(rig.device.injected == [
            "key down 113 meta 12288", "key press 29 meta 12288", "key up 113 meta 0", "pause 50", "key press 67 meta 0",
            "text bye", "key press 66 meta 0",
        ])
        #expect(Self.inputScripts(rig).isEmpty)
        await rig.backend.close()
    }

    @Test("with OFFSIDER_ANDROID_INPUT=input, the Ctrl+A and Delete fallback goes through `input` though the helper runs")
    func actionUnsupportedOverInput() async throws {
        let rig = try Self.rig(
            environment: ["OFFSIDER_ANDROID_INPUT": "input"],
            setText: .error(code: "action-unsupported", message: "android.widget.EditText does not offer ACTION_SET_TEXT")
        )
        try await Self.replace("bye\n", on: rig)

        #expect(rig.device.injected.isEmpty)
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

    /// A dump whose focused EditText holds `text`, or is a password field, or is empty and shows `text` as its hint.
    nonisolated static func fieldDump(text: String, password: Bool = false, showingHint: Bool = false) -> String {
        let hint = showingHint ? #","hint":"\#(text)","showingHint":true"# : ""
        let field = #"{"i":1,"class":"android.widget.EditText","package":"com.mpalmes.offsider.playground.rn","resourceId":"amount","text":"\#(text)"\#(hint),"bounds":[42,510,1038,626],"clickable":true,"focusable":true,"focused":true,"editable":true\#(password ? #","password":true"# : "")}"#
        return #"{"generation":1,"idle":true,\#(FakeHelperDevice.display),"windows":[{"id":2292,"type":"application","layer":0,"title":"OffsiderPlaygroundRN","displayId":0,"bounds":[0,0,1080,2424],"active":true,"focused":true,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.mpalmes.offsider.playground.rn","bounds":[0,0,1080,2424],"children":[\#(field)]}}],"truncated":false,"eventSeq":3}"#
    }

    nonisolated static let refusedNumber = FakeHelperDevice.Answer.error(
        code: "action-unsupported", message: "android.widget.EditText does not offer ACTION_SET_TEXT",
        className: "android.widget.EditText", resourceId: "amount", inputType: 0x2002
    )

    /// emulator-5556 with gRPC for the clipboard, its focused field holding `before` until a paste sets `after`, or answering the paste with `pasteRefusal`.
    static func grpcRig(
        before: String, after: String, password: Bool = false, showingHint: Bool = false,
        pasteRefusal: FakeHelperDevice.Answer? = nil, emulator: FakeEmulator = FakeEmulator(clipboard: "saved")
    ) throws -> HelperRig {
        let device = FakeHelperDevice()
        device.dump = fieldDump(text: before, password: password, showingHint: showingHint)
        device.answer = { _, op, _ in
            switch op {
            case "setText": return refusedNumber
            case "paste":
                if let pasteRefusal { return pasteRefusal }
                device.dump = fieldDump(text: after, password: password)
                return .ok(#"{"className":"android.widget.EditText","resourceId":"amount","inputType":8194,"length":\#(after.utf16.count)}"#)
            default: return nil
            }
        }
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        return try HelperRig(device, emulator: FakeEmulatorConnector(.success(emulator)), home: home)
    }

    @Test("the key fallback's warning names the field's class, id and decoded inputType")
    func warningNamesInputType() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.fieldDump(text: "bye")
        let rig = try Self.rig(device, setText: Self.refusedNumber)
        try await Self.replace("bye", on: rig)

        #expect(rig.log.warnings.first?.contains("on emulator-5556 (android.widget.EditText, id amount, inputType number|decimal) does not accept replacement text") == true)
        await rig.backend.close()
    }

    @Test("when keys leave the wrong text, an emulator with gRPC pastes it with the helper and puts the clipboard back")
    func pasteWithGrpc() async throws {
        let emulator = FakeEmulator(clipboard: "saved")
        let rig = try Self.grpcRig(before: "12", after: "bye", emulator: emulator)
        try await Self.replace("bye", on: rig)

        let paste = try #require(rig.device.frames.first { $0.op == "paste" })
        #expect(paste.json.contains(#""expectClass":"android.widget.EditText","expectResourceId":"amount""#))
        #expect(emulator.calls.contains(.setClipboard("bye")))
        #expect(emulator.clipboardNow == "saved")
        await rig.backend.close()
    }

    @Test("a paste that adds to the text instead of replacing it is text_not_accepted, though the field is long enough")
    func pasteAppended() async throws {
        let rig = try Self.grpcRig(before: "by", after: "bybye")
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(error?.message.contains("does not hold exactly the text after Ctrl+A, Delete, typed keys and a paste") == true)
        #expect(rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("an empty field showing its hint reads as empty, so a hint longer than the text still gets the paste")
    func hintIsNotText() async throws {
        let rig = try Self.grpcRig(before: "Amount in dollars", after: "1000", showingHint: true)
        try await Self.replace("1000", on: rig)

        #expect(rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("when focus moved to another field, the helper's refusal stops the paste and the clipboard is put back")
    func pasteFocusMoved() async throws {
        let emulator = FakeEmulator(clipboard: "saved")
        let moved = FakeHelperDevice.Answer.error(
            code: "focus-moved", message: "the field with input focus is android.widget.EditText with id note, not the expected field",
            className: "android.widget.EditText", resourceId: "note", inputType: 1
        )
        let rig = try Self.grpcRig(before: "12", after: "bye", pasteRefusal: moved, emulator: emulator)
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(error?.message.contains("moved from the field Offsider typed into (android.widget.EditText, id amount) to android.widget.EditText, id note, inputType text") == true)
        #expect(emulator.clipboardNow == "saved")
        await rig.backend.close()
    }

    @Test("without gRPC there is no paste: wrong text is exit 5 text_not_accepted naming the field")
    func noPasteWithoutGrpc() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.fieldDump(text: "12")
        let rig = try Self.rig(device, setText: Self.refusedNumber)
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.message.contains("(android.widget.EditText, id amount, inputType number|decimal)") == true)
        #expect(!rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("a paste that still leaves the wrong text is text_not_accepted")
    func pasteStillWrong() async throws {
        let rig = try Self.grpcRig(before: "12", after: "12")
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("a password field is never checked or pasted into")
    func secureNeverPasted() async throws {
        let emulator = FakeEmulator(clipboard: "saved")
        let rig = try Self.grpcRig(before: "", after: "", password: true, emulator: emulator)
        try await Self.replace("secret", on: rig)

        #expect(!rig.device.ops.contains("paste"))
        #expect(!emulator.calls.contains(.setClipboard("secret")))
        await rig.backend.close()
    }

    @Test("a set-text the field cuts short is checked like the key fallback: pasted with gRPC, and still short is text_not_accepted")
    func setTextCutShort() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.fieldDump(text: "by")
        device.answer = { _, op, _ in
            switch op {
            case "setText": return .ok(#"{"className":"android.widget.EditText","resourceId":"amount","inputType":1,"length":2}"#)
            case "paste": return .ok(#"{"className":"android.widget.EditText","resourceId":"amount","inputType":1,"length":2}"#)
            default: return nil
            }
        }
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let rig = try HelperRig(device, emulator: FakeEmulatorConnector(.success(FakeEmulator(clipboard: "saved"))), home: home)
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("bye", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(rig.device.ops.contains("paste"))
        #expect(error?.message.contains("inputType text") == true)
        await rig.backend.close()
    }

    /// emulator-5556 with gRPC whose set-text succeeds reporting `length` while the field reads `reads`, until a paste sets `afterPaste`.
    static func setTextRig(length: Int, reads: String, afterPaste: String) throws -> HelperRig {
        let device = FakeHelperDevice()
        device.dump = fieldDump(text: reads)
        device.answer = { _, op, _ in
            switch op {
            case "setText": return .ok(#"{"className":"android.widget.EditText","resourceId":"amount","inputType":2,"length":\#(length)}"#)
            case "paste":
                device.dump = fieldDump(text: afterPaste)
                return .ok(#"{"className":"android.widget.EditText","resourceId":"amount","inputType":2,"length":\#(afterPaste.utf16.count)}"#)
            default: return nil
            }
        }
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        return try HelperRig(device, emulator: FakeEmulatorConnector(.success(FakeEmulator(clipboard: "saved"))), home: home)
    }

    @Test("a set-text the field formats longer (1,000 for 1000) is accepted with no paste")
    func setTextFormattedLonger() async throws {
        let rig = try Self.setTextRig(length: 5, reads: "1,000", afterPaste: "1,000")
        try await Self.replace("1000", on: rig)

        #expect(!rig.device.ops.contains("paste"))
        #expect(rig.log.warnings.isEmpty)
        await rig.backend.close()
    }

    @Test("after the key fallback, a field that formats the text longer is accepted with no paste")
    func keysFormattedLonger() async throws {
        let rig = try Self.grpcRig(before: "1,000", after: "1,000")
        try await Self.replace("1000", on: rig)

        #expect(!rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("a set-text that leaves the field empty goes through paste, then text_not_accepted")
    func setTextLeftEmpty() async throws {
        let rig = try Self.setTextRig(length: 0, reads: "", afterPaste: "")
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("1000", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        #expect(rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("a set-text that reads shorter goes through paste, and a paste that leaves exactly the text is accepted")
    func setTextShortThenPasted() async throws {
        let rig = try Self.setTextRig(length: 2, reads: "10", afterPaste: "1000")
        try await Self.replace("1000", on: rig)

        #expect(rig.device.ops.contains("paste"))
        await rig.backend.close()
    }

    @Test("after a paste, a reading other than the exact text (1,000 for 1000) is text_not_accepted")
    func setTextShortThenPastedDifferent() async throws {
        let rig = try Self.setTextRig(length: 2, reads: "10", afterPaste: "1,000")
        let error = await #expect(throws: AndroidError.self) { try await Self.replace("1000", on: rig) }

        #expect(error?.kind == .textNotAccepted)
        await rig.backend.close()
    }
}
