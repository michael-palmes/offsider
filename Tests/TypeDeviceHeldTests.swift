import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A USB iPhone's field: keys land as `TypingFieldBackend` takes them, and the runner's one-element read answers with the field while it holds keyboard focus.
@MainActor
final class DeviceTypingFieldBackend: TypingFieldBackend, FocusedElementReading {
    /// False for text the runner typed, which no key can send again.
    var keys = true
    /// False once another element holds keyboard focus.
    var fieldFocused = true
    private(set) var focusedReads = 0

    func typesWithKeys(_ text: String, on id: DeviceID) async -> Bool { keys }

    func focusedElement(on id: DeviceID) async throws -> UINode? {
        focusedReads += 1
        return fieldFocused ? field : nil
    }
}

@Suite("Typed text read back on a USB iPhone")
@MainActor
struct TypeDeviceHeldTests {
    static let iPhone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    /// The keys as the device session sends them, then the read-back on a clock only its own sleeps move; returns the warnings.
    @discardableResult
    static func type(_ arguments: [String], on backend: DeviceTypingFieldBackend, secure: KnownSecureFocus? = nil) async throws -> [String] {
        let command = try Type.parse(arguments + ["--device", iPhone.rawValue])
        let text = try command.resolvedText()
        let focus = Type.FocusCheck(secure: secure, tree: FakeUI.tree([backend.field]), field: backend.field)
        try await backend.session.perform(.composite(try Type.iosEvents(for: text, replacing: command.replace)))
        var warnings: [String] = []
        try await command.confirmHeldOnDevice(
            text, focus: focus, backend: backend, device: iPhone, clock: ScriptedClock().poll, warn: { warnings.append($0) }, send: nil
        )
        return warnings
    }

    @Test("a field that holds the text costs one read of the focused element, no tree read, and nothing is sent again")
    func healthyField() async throws {
        let backend = DeviceTypingFieldBackend()
        let warnings = try await Self.type(["hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(backend.focusedReads == 1)
        #expect(backend.readsAfterKeys == 0)
        #expect(backend.session.calls.count == 1)
        #expect(warnings.isEmpty)
    }

    @Test("a field that lost a key has its own characters deleted and the text typed once more, one key a send, with a warning")
    func retypesKeyByKey() async throws {
        let backend = TypeHeldDeviceFields.dropping("l")
        let warnings = try await Self.type(["hello"], on: backend)
        #expect(backend.text == "hello")
        #expect(backend.session.calls.count == 7, "the first pass, the delete, then five keys")
        #expect(warnings.count == 1)
    }

    @Test("--replace on a field that lost a key clears it and types the text once more")
    func retypesAReplace() async throws {
        let backend = TypeHeldDeviceFields.dropping("l", text: "old")
        try await Self.type(["--replace", "hello"], on: backend)
        #expect(backend.text == "hello")
    }

    @Test("a field that still lacks the text after the second try is exit 5 text_not_accepted, naming the field and never the text")
    func stillWrong() async throws {
        let backend = TypeHeldDeviceFields.dropping("l", times: 100)
        let error = await #expect(throws: CLIError.self) { try await Self.type(["hello"], on: backend) }
        #expect(error?.reason == .textNotAccepted)
        #expect(error?.exitCode == .unverified)
        #expect(error?.userFacingDescription.contains("id=code") == true)
        #expect(error?.userFacingDescription.contains("hello") == false)
    }

    @Test("a password field is never read: not its focused element, and not the tree")
    func passwordFieldUnread() async throws {
        let backend = DeviceTypingFieldBackend()
        backend.role = .secureTextField
        try await Self.type(["hunter2"], on: backend)
        #expect(backend.focusedReads == 0)
        #expect(backend.readsAfterKeys == 0)
    }

    @Test("a field only a raised keyboard proved, which may be a password field, is never read")
    func unknownFieldUnread() async throws {
        let backend = DeviceTypingFieldBackend()
        try await Self.type(["123456"], on: backend, secure: .unknown)
        #expect(backend.focusedReads == 0)
        #expect(backend.readsAfterKeys == 0)
    }

    @Test("text the runner typed is not read back, since no key could type it again")
    func runnerTextUnread() async throws {
        let backend = DeviceTypingFieldBackend()
        backend.keys = false
        try await Self.type(["hello"], on: backend)
        #expect(backend.focusedReads == 0)
    }

    @Test("text ending in Return, or longer than a read can judge, is not read back", arguments: ["hello\n", String(repeating: "a", count: TypedText.longest + 1)])
    func excludedText(text: String) async throws {
        let backend = DeviceTypingFieldBackend()
        try await Self.type([text], on: backend)
        #expect(backend.focusedReads == 0)
    }

    @Test("when keyboard focus has moved on, the field is read from the tree instead")
    func focusMovedOn() async throws {
        let backend = DeviceTypingFieldBackend()
        backend.fieldFocused = false
        let warnings = try await Self.type(["hello"], on: backend)
        #expect(backend.focusedReads == 1)
        #expect(backend.readsAfterKeys == 1)
        #expect(warnings.isEmpty)
    }
}

@MainActor
enum TypeHeldDeviceFields {
    /// A device field that loses `character` the first `times` it is pressed.
    static func dropping(_ character: Character, times: Int = 1, text: String = "") -> DeviceTypingFieldBackend {
        let backend = DeviceTypingFieldBackend(text: text)
        var left = times
        backend.onKey = { text, key in
            if key == character, left > 0 { left -= 1 } else { text.append(key) }
        }
        return backend
    }
}
