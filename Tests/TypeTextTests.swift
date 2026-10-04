import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Type text resolution")
@MainActor
struct TypeTextTests {
    static let decomposed = "cafe\u{301}"
    static let composed = "caf\u{E9}"

    static func context(_ platform: DevicePlatform) -> BatchContext {
        BatchContext(
            backend: StubBackend(session: RecordingInputSession()),
            device: DeviceID(rawValue: platform == .android ? "emulator-5556" : UUID().uuidString, platform: platform),
            axCachePolicy: .perBatch,
            typeSubmissionMode: .composite,
            typeChunkSize: 1
        )
    }

    @Test("an argument with e and a combining acute accent becomes one precomposed character")
    func argument() throws {
        let text = try Type.parse([Self.decomposed, "--device", "x"]).resolvedText()
        #expect(text == Self.composed)
        #expect(text.unicodeScalars.count == 4)
    }

    @Test("stdin text is composed the same way")
    func standardInput() throws {
        let text = try Type.parse(["--stdin", "--device", "x"]).resolvedText(readStandardInput: { Self.decomposed })
        #expect(text.unicodeScalars.map(\.value) == [0x63, 0x61, 0x66, 0xE9])
    }

    @Test("file text is composed the same way")
    func file() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-type-\(UUID().uuidString).txt")
        try Data(Self.decomposed.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try Type.parse(["--file", url.path, "--device", "x"]).resolvedText()
        #expect(text.unicodeScalars.map(\.value) == [0x63, 0x61, 0x66, 0xE9])
    }

    @Test("an Android batch type step carries the composed text")
    func batchAndroid() async throws {
        let primitives = try await Type.parse([Self.decomposed, "--device", "x"])
            .toBatchPrimitives(context: Self.context(.android), logger: OffsiderLogger())
        guard primitives.count == 1, case .text(let text, replace: false) = primitives[0] else {
            Issue.record("expected one text step, got \(primitives)")
            return
        }
        #expect(text.unicodeScalars.map(\.value) == [0x63, 0x61, 0x66, 0xE9])
    }

    @Test("an iOS batch type step counts a composed character once when it reports the position it cannot type")
    func batchIOSNamesComposedCharacter() async throws {
        let error = await #expect(throws: TextToHIDEvents.TextConversionError.self) {
            _ = try await Type.parse([Self.decomposed, "--device", "x"])
                .toBatchPrimitives(context: Self.context(.ios), logger: OffsiderLogger())
        }
        guard case .unsupportedCharacters(let positions, let length) = error else { return }
        #expect(positions == [4])
        #expect(length == 4)
    }
}
