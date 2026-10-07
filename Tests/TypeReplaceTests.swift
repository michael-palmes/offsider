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

    @Test("an iOS composite batch step puts the clear and the typing in one mergeable composite")
    func iosBatchComposite() async throws {
        let primitives = try await Self.primitives(["--replace", "bye"], Self.context(.ios))
        guard primitives.count == 1, case .hidMergeable(.composite(let events)) = primitives[0] else {
            Issue.record("expected one mergeable composite, got \(primitives)")
            return
        }
        #expect(events == (try Type.iosEvents(for: "bye", replacing: true)))
    }

    @Test("an iOS chunked batch step sends the clear as its own barrier first")
    func iosBatchChunked() async throws {
        let primitives = try await Self.primitives(["--replace", "bye"], Self.context(.ios, mode: .chunked))
        guard case .hidBarrier(let clear) = primitives.first else {
            Issue.record("expected the clear first, got \(primitives)")
            return
        }
        #expect(clear == Self.iosClear)
        let typed = primitives.dropFirst().flatMap { primitive -> [InputEvent] in
            guard case .hidBarrier(.composite(let events)) = primitive else { return [] }
            return events
        }
        #expect(typed == (try Type.iosEvents(for: "bye", replacing: false)))
    }

    @Test("an iOS batch --replace with empty text still clears")
    func iosBatchClearOnly() async throws {
        let primitives = try await Self.primitives(["--replace", ""], Self.context(.ios, mode: .chunked))
        guard primitives.count == 1, case .hidBarrier(let clear) = primitives[0] else {
            Issue.record("expected the clear alone, got \(primitives)")
            return
        }
        #expect(clear == Self.iosClear)
    }

    @Test("an Android batch step replaces, even with empty text, and plain type does not")
    func androidBatch() async throws {
        for (arguments, expected) in [(["--replace", "bye"], "bye"), (["--replace", ""], "")] {
            let primitives = try await Self.primitives(arguments, Self.context(.android))
            guard primitives.count == 1, case .text(let text, replace: true) = primitives[0] else {
                Issue.record("expected one replacing text step for \(arguments), got \(primitives)")
                continue
            }
            #expect(text == expected)
        }
        let plain = try await Self.primitives(["bye"], Self.context(.android))
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
