import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android adb fallback", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidFallbackTests {
    private let adbOnly = ["OFFSIDER_ANDROID_TRANSPORT": "adb"]

    @Test("tap, ASCII type and screenshot work over adb alone")
    func adbOnlyCommands() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field", environment: adbOnly)
        try await AndroidE2E.run("type 'adb only'", environment: adbOnly)
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 8" }

        let output = AndroidE2E.temporaryFile("adb.png")
        defer { try? FileManager.default.removeItem(at: output) }
        try await AndroidE2E.run("screenshot --output \(AndroidE2E.quote(output.path))", environment: adbOnly)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("non-ASCII type over adb alone fails before typing anything")
    func unicodeNeedsGrpc() async throws {
        let result = try await AndroidE2E.offsider("type 'héllo'", environment: adbOnly)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Typing non-ASCII text on Android needs the emulator's gRPC endpoint"))
    }
}

@Suite("Android JWT auth", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidJWTTests {
    private let jwt = ["OFFSIDER_ANDROID_GRPC_AUTH": "jwt", "OFFSIDER_ANDROID_TRANSPORT": "grpc"]

    @Test("tap, key, screenshot, non-ASCII type and a BGRA frame work with a signed key, and no key is left behind")
    func jwtSession() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field", environment: jwt)
        try await AndroidE2E.type("jwt \u{F1}", environment: jwt)
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 5" }
        try await AndroidE2E.run("key 42", environment: jwt)
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 4" }

        let serial = try await AndroidE2E.serial()
        let stream = try await CommandRunner.runSeparated(
            "OFFSIDER_ANDROID_GRPC_AUTH=jwt \(AndroidE2E.quote(try TestHelpers.getOffsiderPath())) stream-video --format bgra --device \(serial) | head -c 16 | wc -c",
            timeout: 60
        )
        #expect(stream.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "16")

        // A stream ended by SIGPIPE skips its exit hook; the next registration sweeps that key.
        let output = AndroidE2E.temporaryFile("jwt.png")
        defer { try? FileManager.default.removeItem(at: output) }
        try await AndroidE2E.run("screenshot --output \(AndroidE2E.quote(output.path))", environment: jwt)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let port = Int(serial.dropFirst("emulator-".count))
        let discovery = try #require(EmulatorDiscovery.live(host: .live()).first { $0.consolePort == port })
        let folder = try #require(discovery.jwksDirectory)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasPrefix("offsider-") }
        #expect(leftovers.isEmpty, "keys left in \(folder): \(leftovers)")
    }
}
