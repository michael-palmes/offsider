import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Type --replace")
@MainActor
struct TypeReplaceTests {
    /// Command down, `a`, Command up, 50 ms, Backspace, then 200 ms.
    static let iosClear = InputEvent.composite([
        .keyboard(direction: .down, keyCode: 227),
        .shortKeyPress(4),
        .keyboard(direction: .up, keyCode: 227),
        .delay(0.05),
        .shortKeyPress(42),
        .delay(0.2),
    ])

    static func context(_ platform: DevicePlatform, mode: TypeSubmissionMode = .composite) -> BatchContext {
        BatchContext(
            backend: StubBackend(session: RecordingInputSession()),
            device: DeviceID(rawValue: platform == .android ? "emulator-5556" : UUID().uuidString, platform: platform),
            axCachePolicy: .perBatch,
            typeSubmissionMode: mode,
            typeChunkSize: 2
        )
    }

    static func primitives(_ arguments: [String], _ context: BatchContext) async throws -> [BatchPrimitive] {
        try await Type.parse(arguments + ["--device", "x"]).toBatchPrimitives(context: context, logger: OffsiderLogger())
    }

    @Test("on iOS, --replace clears with Command-A and Backspace, then types as usual")
    func iosEvents() throws {
        let replacing = try Type.iosEvents(for: "bye", replacing: true)
        #expect(replacing.first == Self.iosClear)
        #expect(Array(replacing.dropFirst()) == (try Type.iosEvents(for: "bye", replacing: false)))
        #expect(replacing.count > 1)
    }

    @Test("on iOS, --replace with empty text is the clear alone")
    func iosClearOnly() throws {
        #expect(try Type.iosEvents(for: "", replacing: true) == [Self.iosClear])
    }

    /// What an iOS batch step sends once it runs, on a screen whose field has focus.
    static func iosBatchSent(_ arguments: [String], mode: TypeSubmissionMode) async throws -> [InputEvent] {
        let session = RecordingInputSession()
        let focused = FakeUI.tree([FakeUI.node(.textField, id: "field", frame: FakeUI.frame(20, 200, 360, 44), state: UIState(focused: true))])
        let backend = FakeDeviceBackend(platform: .ios, trees: [focused], session: session)
        let context = BatchContext(
            backend: backend, device: DeviceID(rawValue: UUID().uuidString, platform: .ios), axCachePolicy: .perBatch, typeSubmissionMode: mode, typeChunkSize: 2
        )
        let primitives = try await Self.primitives(arguments, context)
        try await BatchPlanRunner(session: session, logger: OffsiderLogger()).run(BatchPlan(primitives: primitives))
        return session.calls.compactMap { call in
            guard case .perform(let event) = call else { return nil }
            return event
        }
    }

    @Test("an iOS composite batch step sends the clear and the typing in one composite")
    func iosBatchComposite() async throws {
        #expect(try await Self.iosBatchSent(["--replace", "bye"], mode: .composite) == [.composite(try Type.iosEvents(for: "bye", replacing: true))])
    }

    @Test("an iOS chunked batch step sends the clear on its own first, then the typing in chunks")
    func iosBatchChunked() async throws {
        let sent = try await Self.iosBatchSent(["--replace", "bye"], mode: .chunked)
        #expect(sent.first == Self.iosClear)
        let typed = sent.dropFirst().flatMap { event -> [InputEvent] in
            guard case .composite(let events) = event else { return [] }
            return events
        }
        #expect(typed == (try Type.iosEvents(for: "bye", replacing: false)))
        #expect(sent.count > 2)
    }

    @Test("an iOS batch --replace with empty text still clears")
    func iosBatchClearOnly() async throws {
        #expect(try await Self.iosBatchSent(["--replace", ""], mode: .chunked) == [Self.iosClear])
    }

    @Test("an Android batch step replaces, even with empty text, and plain type does not (past its password-field check)")
    func androidBatch() async throws {
        for (arguments, expected) in [(["--replace", "bye"], "bye"), (["--replace", ""], "")] {
            let primitives = try await Self.primitives(arguments, Self.context(.android)).filter { if case .run = $0 { false } else { true } }
            guard primitives.count == 1, case .text(let text, replace: true) = primitives[0] else {
                Issue.record("expected one replacing text step for \(arguments), got \(primitives)")
                continue
            }
            #expect(text == expected)
        }
        let plain = try await Self.primitives(["bye"], Self.context(.android)).filter { if case .run = $0 { false } else { true } }
        guard plain.count == 1, case .text("bye", replace: false) = plain[0] else {
            Issue.record("expected one plain text step, got \(plain)")
            return
        }
    }

    @Test("type --help documents --replace")
    func help() async throws {
        let result = try await TestHelpers.runOffsiderCommand("type --help")
        #expect(result.output.contains("--replace"))
        #expect(result.output.contains("Replace the focused"))
    }
}
