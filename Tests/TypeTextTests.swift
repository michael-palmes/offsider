import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

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
            .filter { if case .run = $0 { false } else { true } }
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

@Suite("Type on an adb route")
@MainActor
struct TypeAdbRouteTests {
    static func plainField(text: String) -> String {
        AndroidSecureTextTests.xml(
            AndroidSecureTextTests.passwordNode(text: text, focused: true).replacingOccurrences(of: #"password="true""#, with: #"password="false""#)
        )
    }

    static func run(_ text: String, rig: AndroidGrpcInputTests.Rig) async throws {
        let route = DeviceRouter.Route(backend: rig.backend, device: AndroidGrpcTextTests.device)
        try await Type.parse([text, "--device", AndroidGrpcTextTests.device.rawValue])
            .execute(on: route, progress: nil, logger: OffsiderLogger(), refusingSecureArgument: true)
    }

    @Test("type 'x' on an adb route reads the screen once before the keys, as the command's password-field check serves the session too, and once after to read the field back")
    func oneTreeRead() async throws {
        let rig = try AndroidGrpcInputTests.rig(
            environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb", "OFFSIDER_ANDROID_TREE": "uiautomator"],
            uiautomatorDump: Self.plainField(text: ""), typedDump: Self.plainField(text: "x")
        )
        try await Self.run("x", rig: rig)

        let services = rig.server.services
        let typedAt = try #require(services.firstIndex { $0.contains("input text") })
        #expect(services[..<typedAt].filter { $0.contains("uiautomator dump") }.count == 1)
        #expect(services[typedAt...].filter { $0.contains("uiautomator dump") }.count == 1)
    }

    @Test("type with argument text and an unreadable screen sends no input text script and says the text was not sent")
    func unreadableScreen() async throws {
        let rig = try AndroidGrpcInputTests.rig(environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb", "OFFSIDER_ANDROID_TREE": "uiautomator"])
        let error = await #expect(throws: AndroidError.self) { try await Self.run("S3NT1NEL", rig: rig) }

        #expect(error?.reason == .helperUnavailable)
        #expect(error?.message.contains("The text was not sent") == true)
        #expect(!rig.adbScripts.contains { $0.hasPrefix("input text") })
    }
}
