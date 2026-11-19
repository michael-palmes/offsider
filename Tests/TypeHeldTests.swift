import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A simulator with one text field that takes key events as a real one does: Command-A selects, Backspace deletes, a key adds its character.
@MainActor
class TypingFieldBackend: FakeDeviceBackend, ElementWatching {
    static let frame = FakeUI.frame(20, 200, 360, 44)

    var text: String
    var role: UIRole = .textField
    /// What a key does to the field's text; the default adds its character.
    var onKey: (inout String, Character) -> Void = { $0.append($1) }
    /// What Backspace does to the field's text; the default takes the last character.
    var onBackspace: (inout String) -> Void = { if !$0.isEmpty { $0.removeLast() } }
    /// False for a backend whose hit-test finds no element to keep open, so reads fall back to the tree.
    var watches = true
    /// When set, what a kept element reads, as one that went stale does while the tree moves on.
    var staleValue: String?
    /// What an empty field reads, as a React Native field reads its placeholder.
    var placeholder: String?
    /// Reads of the field that pass before the keys sent so far show in it, as in an app that is behind its keys.
    var lagReads = 0
    private var queued: [InputEvent] = []
    private(set) var watchesOpened = 0
    private(set) var readsAfterKeys = 0
    private(set) var keysSent = 0
    private var selected = false
    private var shift = false
    private var command = false

    init(text: String = "") {
        self.text = text
        super.init(platform: .ios, trees: [])
        session.onPerform = { [unowned self] event in
            if lagReads > 0 { queued.append(event) } else { apply(event) }
        }
    }

    var field: UINode {
        if lagReads > 0 {
            lagReads -= 1
            if lagReads == 0 {
                queued.forEach(apply)
                queued = []
            }
        }
        return FakeUI.node(role, id: "code", value: text.isEmpty ? placeholder : text, frame: Self.frame, state: UIState(focused: true))
    }

    override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        if keysSent > 0 { readsAfterKeys += 1 }
        return FakeUI.tree([field])
    }

    func watchElement(at point: UIPoint, on id: DeviceID) async throws -> (any ElementWatch)? {
        guard watches, Self.frame.contains(point) else { return nil }
        watchesOpened += 1
        return Watch(backend: self)
    }

    @MainActor
    final class Watch: ElementWatch {
        private weak var backend: TypingFieldBackend?
        init(backend: TypingFieldBackend) { self.backend = backend }

        func read() -> UINode? {
            guard let backend else { return nil }
            if backend.keysSent > 0 { backend.readsAfterKeys += 1 }
            guard let stale = backend.staleValue else { return backend.field }
            return FakeUI.node(backend.role, id: "code", value: stale, frame: TypingFieldBackend.frame, state: UIState(focused: true))
        }

        func close() { backend = nil }
    }

    private static let characters: [String: Character] = {
        var table: [String: Character] = [:]
        for character in "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-@." {
            let events = (try? TextToHIDEvents.convertTextToHIDEvents(String(character))) ?? []
            for case .keyboard(direction: .down, keyCode: let code) in events where code != 225 {
                table["\(code)-\(events.count > 2)"] = character
            }
        }
        return table
    }()

    private func apply(_ event: InputEvent) {
        keysSent += 1
        switch event {
        case .composite(let events): events.forEach(apply)
        case .keyboard(direction: .down, keyCode: 225): shift = true
        case .keyboard(direction: .up, keyCode: 225): shift = false
        case .keyboard(direction: .down, keyCode: 227): command = true
        case .keyboard(direction: .up, keyCode: 227): command = false
        case .keyboard(direction: .down, keyCode: let code), .shortKeyPress(let code): press(code)
        default: break
        }
    }

    private func press(_ code: UInt32) {
        if command, code == 4 {
            selected = true
        } else if code == 42 {
            if selected { text = "" } else { onBackspace(&text) }
            selected = false
        } else if let character = Self.characters["\(code)-\(shift)"] {
            if selected { text = "" }
            selected = false
            onKey(&text, character)
        }
    }
}

/// The same field on a backend whose hit-test answers with it, as a simulator's does.
@MainActor
final class HitTypingFieldBackend: TypingFieldBackend, PointHitTesting {
    private(set) var hitTests = 0

    func hitTest(at point: UIPoint, on id: DeviceID, appPIDs: Set<Int>) async throws -> UINode? {
        hitTests += 1
        return Self.frame.contains(point) ? field : nil
    }

    func processName(of pid: Int, on id: DeviceID) async -> String? { nil }
}

@Suite("Typed text read back on an iOS simulator")
@MainActor
struct TypeHeldTests {
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    /// The first pass as the command sends it, then the read-back on a clock only its own sleeps move; returns the warnings.
    @discardableResult
    static func type(_ arguments: [String], on backend: TypingFieldBackend, field: UINode? = nil, clock: ScriptedClock? = nil) async throws -> [String] {
        let command = try Type.parse(arguments + ["--device", simulator.rawValue])
        let text = try command.resolvedText()
        let focus = Type.FocusCheck(tree: FakeUI.tree([backend.field]), field: field ?? backend.field)
        let reader = await command.fieldReader(for: text, focus: focus, backend: backend, device: simulator, watching: backend.watches)
        let clock = clock ?? ScriptedClock()
        let cleared = try await command.sendKeys(text, paced: false, reader: reader, clock: clock.poll) { try await backend.session.perform($0) }
        var warnings: [String] = []
        try await command.confirmHeld(
            text, focus: focus, reader: reader, cleared: cleared, backend: backend, device: simulator, clock: clock.poll, warn: { warnings.append($0) }, send: nil
        )
        return warnings
    }

    /// A field that loses `character` the first `times` it is pressed.
    static func dropping(_ character: Character, times: Int = 1, text: String = "") -> TypingFieldBackend {
        let backend = TypingFieldBackend(text: text)
        var left = times
        backend.onKey = { text, key in
            if key == character, left > 0 { left -= 1 } else { text.append(key) }
        }
        return backend
    }

    @Test("a field that keeps up costs one hit-test before the keys and one quick read after them, with nothing sent again")
    func healthyField() async throws {
        let backend = TypingFieldBackend()
        let warnings = try await Self.type(["hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(backend.session.calls.count == 1)
        #expect(backend.watchesOpened == 1)
        #expect(backend.readsAfterKeys == 1)
        #expect(warnings.isEmpty)
    }

    @Test("an app that is not React Native gets no hit-test before the keys: its field is read from the tree once after them")
    func nativeAppReadsTheTree() async throws {
        let backend = TypingFieldBackend()
        try await TreeCacheFixture().run {
            try await Type.parse(["hello", "--device", Self.simulator.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger())
        }
        #expect(backend.text == "hello")
        #expect(backend.watchesOpened == 0)
        #expect(backend.readsAfterKeys == 1)
    }

    @Test("--replace sends the clear first and the keys as soon as the field shows it, with no fixed pause")
    func clearSeenAtOnce() async throws {
        let backend = TypingFieldBackend(text: "old")
        let clock = ScriptedClock()
        try await Self.type(["--replace", "hello"], on: backend, clock: clock)
        #expect(backend.text == "hello")
        #expect(backend.session.calls == [
            .perform(InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey)),
            .perform(.composite(try Type.iosEvents(for: "hello", replacing: false))),
        ])
        #expect(clock.now == 0)
    }

    @Test("the same text replaced in an app behind its keys is not taken for the text sent until the field has changed")
    func sameTextInLaggingApp() async throws {
        let backend = Self.dropping("l", text: "hello")
        backend.lagReads = 30
        let warnings = try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(warnings.count == 1)
    }

    @Test("a field still taking its keys when the send returns is waited for, not typed again")
    func lateKeysWaitedFor() async throws {
        let backend = TypingFieldBackend()
        backend.lagReads = 6
        let warnings = try await Self.type(["hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(backend.session.calls.count == 1)
        #expect(warnings.isEmpty)
    }

    @Test("a value that says nothing either way, as a box that keeps one digit of six shows, passes after a short wait with nothing typed again")
    func unjudgedValuePasses() async throws {
        let backend = TypingFieldBackend()
        backend.onKey = { text, key in if text.isEmpty { text.append(key) } }
        let clock = ScriptedClock()
        try await Self.type(["123456"], on: backend, clock: clock)
        #expect(backend.text == "1")
        #expect(backend.session.calls.count == 1)
        #expect(clock.now < 0.5)
    }

    @Test("a cleared field the keys never reach is typed again, though its placeholder says nothing about the text")
    func clearedFieldKeysLost() async throws {
        let backend = TypingFieldBackend(text: "old")
        backend.placeholder = "Search"
        var lost = true
        backend.onKey = { text, key in
            if !lost { text.append(key) }
            if key == "o" { lost = false }
        }
        let warnings = try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(warnings.count == 1)
    }

    @Test("a field that drops a key is cleared and typed once more, one key at a time, and says so")
    func droppedKeyRetyped() async throws {
        let backend = Self.dropping("l", text: "old")
        let warnings = try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
        // The first pass's clear and keys, the retype's clear, then one send per key.
        #expect(backend.session.calls.count == 3 + 5)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("id=code") == true)
        #expect(warnings.first?.contains("hello") == false)
    }

    @Test("a field that puts a key in the wrong place is typed once more and ends right")
    func reorderedKeysRetyped() async throws {
        let backend = TypingFieldBackend()
        var swapped = false
        backend.onKey = { text, key in
            if key == "d", !swapped {
                swapped = true
                text.insert(key, at: text.startIndex)
            } else {
                text.append(key)
            }
        }
        try await Self.type(["--replace", "code12"], on: backend)
        #expect(backend.text == "code12")
    }

    @Test("a key the retype loses is pressed once more, as the accent picker swallows the key after a held one")
    func swallowedKeyPressedAgain() async throws {
        let backend = Self.dropping("d", times: 2)
        try await Self.type(["--replace", "code12"], on: backend)
        #expect(backend.text == "code12")
        // The first pass's clear and keys, the retype's clear, six keys and the one pressed again.
        #expect(backend.session.calls.count == 3 + 6 + 1)
    }

    @Test("a field that still differs after the retype exits 5 as text_not_accepted, naming the field and never the text")
    func retryThatFails() async throws {
        let backend = Self.dropping("l", times: 100)
        let error = await #expect(throws: CLIError.self) { try await Self.type(["--replace", "hello"], on: backend) }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.exitCode.rawValue == 5)
        #expect(error?.userFacingDescription.contains("id=code") == true)
        #expect(error?.userFacingDescription.contains("twice") == true)
        #expect(error?.userFacingDescription.contains("hello") == false)
        #expect(error?.userFacingDescription.contains("heo") == false)
    }

    @Test("a field whose text never changes exits 5 without typing again, as an app that ignores keys would take them twice")
    func unchangedField() async throws {
        let backend = TypingFieldBackend(text: "kept")
        backend.onKey = { _, _ in }
        let error = await #expect(throws: CLIError.self) { try await Self.type(["hello"], on: backend) }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.userFacingDescription.contains("did not change") == true)
        #expect(backend.session.calls.count == 1)
    }

    @Test("plain type takes out only its own characters before typing again, so the text already there stays")
    func appendKeepsEarlierText() async throws {
        let backend = Self.dropping("e", text: "ab")
        try await Self.type(["cdefg"], on: backend)
        #expect(backend.text == "abcdefg")
        guard backend.session.calls.count > 1, case .perform(let clear) = backend.session.calls[1] else {
            Issue.record("expected the clear after the first pass")
            return
        }
        #expect(clear == .composite(Array(repeating: .shortKeyPress(42), count: 4)))
    }

    @Test("plain type into a field whose earlier text cannot be told from the keys' own exits 5 and types nothing again")
    func appendThatCannotTell() async throws {
        let backend = TypingFieldBackend(text: "ab")
        backend.onKey = { text, key in
            if key == "d" { text = "zcd" } else if key != "e" { text.append(key) }
        }
        let error = await #expect(throws: CLIError.self) { try await Self.type(["cde"], on: backend) }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.userFacingDescription.contains("--replace") == true)
        #expect(backend.session.calls.count == 1)
    }

    @Test("plain text into a field that empties itself once it has it, as a tag input does, is not typed again")
    func selfClearingField() async throws {
        let backend = TypingFieldBackend(text: "ab")
        backend.onKey = { text, key in text = key == "e" ? "" : text + String(key) }
        try await Self.type(["cde"], on: backend)
        #expect(backend.session.calls.count == 1)
    }

    @Test("plain type does not type again when its Backspaces leave anything but the earlier text, as a formatter that drops its own separator does")
    func backspacesTookTooMuch() async throws {
        let backend = Self.dropping("f", text: "ab")
        backend.onBackspace = { text in text = String(text.dropLast(2)) }
        let error = await #expect(throws: CLIError.self) { try await Self.type(["cdefg"], on: backend) }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.userFacingDescription.contains("did not type again") == true)
        #expect(backend.session.calls.count == 2)
    }

    @Test("a password field is never read: no element is opened and nothing is read after the keys, whatever the field holds")
    func passwordNeverRead() async throws {
        let backend = TypingFieldBackend()
        backend.role = .secureTextField
        backend.onKey = { _, _ in }
        try await Self.type(["hunter2"], on: backend)
        #expect(backend.watchesOpened == 0)
        #expect(backend.readsAfterKeys == 0)
        #expect(backend.session.calls.count == 1)
    }

    @Test("a secret typed by login is never read back, even into a plain field")
    func secretNeverRead() async throws {
        let backend = TypingFieldBackend()
        backend.onKey = { _, _ in }
        try await InputSecrecy.$isSecret.withValue(true) { try await Self.type(["hunter2"], on: backend) }
        #expect(backend.watchesOpened == 0)
        #expect(backend.readsAfterKeys == 0)
    }

    @Test("a focused web view is not judged, as its page holds the text, not its value")
    func webViewNotJudged() async throws {
        let backend = TypingFieldBackend()
        backend.onKey = { _, _ in }
        let web = FakeUI.node(.other, id: "page", frame: TypingFieldBackend.frame, state: UIState(focused: true))
        try await Self.type(["hello"], on: backend, field: web)
        #expect(backend.watchesOpened == 0)
        #expect(backend.readsAfterKeys == 0)
        #expect(backend.session.calls.count == 1)
    }

    @Test("text ending in Return is not judged, as it may submit the form")
    func returnNotJudged() async throws {
        let backend = TypingFieldBackend()
        backend.onKey = { _, _ in }
        try await Self.type(["hello\n"], on: backend)
        #expect(backend.readsAfterKeys == 0)
    }

    @Test("with no element to keep open the field is read from the tree, and the retype goes as one paced send")
    func treeFallback() async throws {
        let backend = Self.dropping("l", text: "old")
        backend.watches = false
        try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(backend.session.calls.count == 3)
        #expect(backend.session.calls.last == .perform(.composite(try Type.iosEvents(for: "hello", replacing: false, paced: true))))
    }

    @Test("a kept element that went stale cannot fail the text: the tree has the last word")
    func staleElement() async throws {
        let backend = TypingFieldBackend()
        backend.staleValue = "he"
        let warnings = try await Self.type(["hello"], on: backend, field: FakeUI.node(.textField, id: "code", frame: TypingFieldBackend.frame, state: UIState(focused: true)))
        #expect(backend.text == "hello")
        #expect(backend.session.calls.count == 1)
        #expect(warnings.isEmpty)
    }

    @Test("an emptied field holds none of the text, so it is typed again")
    func emptiedField() async throws {
        let backend = TypingFieldBackend(text: "old")
        var first = true
        backend.onKey = { text, key in
            if first, key == "o" { first = false; text = "" } else { text.append(key) }
        }
        try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
    }

    @Test("the command reads its field back, so a dropped key ends right")
    func throughTheCommand() async throws {
        let backend = Self.dropping("l")
        try await TreeCacheFixture().run {
            try await Type.parse(["hello", "--device", Self.simulator.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger())
        }
        #expect(backend.text == "hello")
    }

    @Test("a batch type step reads its field back as the command does")
    func batchStep() async throws {
        let healed = Self.dropping("l")
        let context = BatchContext(backend: healed, device: Self.simulator, axCachePolicy: .perStep, typeSubmissionMode: .composite, typeChunkSize: 200)
        _ = try await Batch.runSteps(["type hello"], context: context, session: healed.session, continueOnError: false, output: BatchOutput(json: true, write: { _ in }, writeError: { _ in }), logger: OffsiderLogger())
        #expect(healed.text == "hello")

        let broken = Self.dropping("o", times: 100)
        var out = ""
        let failing = BatchContext(backend: broken, device: Self.simulator, axCachePolicy: .perStep, typeSubmissionMode: .composite, typeChunkSize: 200)
        await #expect(throws: (any Error).self) {
            _ = try await Batch.runSteps(["type hello"], context: failing, session: broken.session, continueOnError: false, output: BatchOutput(json: true, write: { out += $0 }, writeError: { _ in }), logger: OffsiderLogger())
        }
        #expect(out.contains("text_not_accepted"))
        #expect(!out.contains("hello"))
    }

    @Test("a key that repeats, as one iOS took as held does, is not the text sent, so the field is typed again")
    func repeatedKeyRetyped() async throws {
        let backend = TypingFieldBackend(text: "old")
        var repeated = false
        backend.onKey = { text, key in
            text.append(key)
            if key == "l", !repeated {
                repeated = true
                text.append("ll")
            }
        }
        let warnings = try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(warnings.count == 1)
    }

    @Test("an app that is not React Native is read by a hit-test of its own each time, and a repeated key is typed again as one paced send")
    func nativeRetryThroughHitTests() async throws {
        let backend = HitTypingFieldBackend()
        var repeated = false
        backend.onKey = { text, key in
            text.append(key)
            if key == "-", !repeated {
                repeated = true
                text.append("-")
            }
        }
        backend.watches = false
        let warnings = try await Self.type(["wait-now"], on: backend)
        #expect(backend.text == "wait-now")
        #expect(warnings.count == 1)
        #expect(backend.hitTests > 0)
        #expect(backend.session.calls.last == .perform(.composite(try Type.iosEvents(for: "wait-now", replacing: false, paced: true))))
    }

    @Test("a repeat is a character of the text again straight after itself; a formatter's separators and zeros are not")
    func repeatsKey() {
        #expect(TypedText.repeatsKey(sent: "Test@123", before: nil, after: "Test@@@@123", replacing: false))
        #expect(TypedText.repeatsKey(sent: "hello", before: "ab", after: "abhelllo", replacing: false))
        #expect(TypedText.repeatsKey(sent: "Hello World", before: nil, after: "Hello.         World", replacing: true))
        #expect(!TypedText.repeatsKey(sent: "hello", before: nil, after: "hello", replacing: true))
        #expect(!TypedText.repeatsKey(sent: "50", before: nil, after: "50.00", replacing: true))
        #expect(!TypedText.repeatsKey(sent: "4111111111111111", before: nil, after: "4111 1111 1111 1111", replacing: true))
        #expect(!TypedText.repeatsKey(sent: "0400000000", before: nil, after: "+61 400 000 000", replacing: true))
        #expect(TypedText.repeatsKey(sent: "wait--now", before: nil, after: "wait---now", replacing: false))
        #expect(!TypedText.repeatsKey(sent: "one  two", before: nil, after: "one. two", replacing: false))
        #expect(!TypedText.repeatsKey(sent: "1234", before: nil, after: "••••", replacing: true))
    }

    @Test("what the keys left is told from what was there: past the earlier text, or all of it when only the text's own characters remain")
    func ownLength() {
        #expect(TypedText.ownLength(sent: "cde", before: "ab", after: "abce") == 2)
        #expect(TypedText.ownLength(sent: "code12", before: "Search codes", after: "COE12") == 5)
        #expect(TypedText.ownLength(sent: "cde", before: nil, after: "ce") == 2)
        #expect(TypedText.ownLength(sent: "cde", before: "ab", after: "zz") == nil)
    }
}
