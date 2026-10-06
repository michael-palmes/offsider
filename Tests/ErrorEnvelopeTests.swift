import Foundation
import Testing

@Suite("Error envelope")
struct ErrorEnvelopeTests {
    private static func envelope(_ stdout: String) throws -> [String: Any] {
        let lines = stdout.split(separator: "\n")
        try #require(lines.count == 1, "expected one JSON line, got: \(stdout)")
        return try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    }

    @Test("screenshot --json on an unknown device prints one envelope on stdout and exits 7")
    func unknownDeviceEnvelope() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json --device \(UUID().uuidString)")

        #expect(result.exitCode == 7)
        let json = try Self.envelope(result.stdout)
        #expect(json["ok"] as? Bool == false && json["command"] as? String == "screenshot" && json["exitCode"] as? Int == 7)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["reason"] as? String == "device_not_found")
        #expect(error["hint"] as? String == "offsider list-devices")
        #expect(error["dispatched"] is NSNull)
        #expect(result.stderr.hasPrefix("Error: "))
    }

    @Test("a coordinate tap on an unknown device exits 7 and prints no JSON without --json")
    func unknownDeviceTapExits7() async throws {
        let udid = TestDevices.simulatorUDID()
        defer { TestDevices.removePrivateFiles(platform: .ios, id: udid) }
        let result = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1 --device \(udid)")
        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("No device with ID \(udid) was found."))
    }

    @Test("OFFSIDER_DEVICE alone names the device, and an unknown one exits 7 naming it")
    func environmentDeviceIsUsed() async throws {
        let udid = TestDevices.simulatorUDID()
        defer { TestDevices.removePrivateFiles(platform: .ios, id: udid) }
        let result = try await TestHelpers.runOffsiderCommandSeparated("tap -x 1 -y 1", environment: ["OFFSIDER_DEVICE": udid])
        #expect(result.exitCode == 7)
        #expect(result.stderr.contains("No device with ID \(udid) was found."))
    }

    @Test("without --device or OFFSIDER_DEVICE a device command exits 64 naming both")
    func missingDeviceIsUsage() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json", environment: ["OFFSIDER_DEVICE": " "])
        #expect(result.exitCode == 64)
        let error = try #require(try Self.envelope(result.stdout)["error"] as? [String: Any])
        #expect(error["reason"] as? String == "usage")
        #expect(result.stderr.contains("Missing --device <id>. Pass --device, or set OFFSIDER_DEVICE; run offsider list-devices to see IDs."))
    }

    @Test("a usage error under --json still prints an envelope and exits 64")
    func usageEnvelope() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot --json --scale bogus --device \(UUID().uuidString)")

        #expect(result.exitCode == 64)
        let error = try #require(try Self.envelope(result.stdout)["error"] as? [String: Any])
        #expect(error["reason"] as? String == "usage")
        #expect(result.stderr.contains("Usage: offsider screenshot"))
    }

    @Test("a malformed device ID exits 64")
    func malformedDeviceID() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --device a/b")
        #expect(result.exitCode == 64)
        let error = try #require(try Self.envelope(result.stdout)["error"] as? [String: Any])
        #expect(error["reason"] as? String == "invalid_device_id")
    }

    @Test("help and version output are unchanged")
    func helpUnchanged() async throws {
        let help = try await TestHelpers.runOffsiderCommandSeparated("tap --help")
        #expect(help.exitCode == 0)
        #expect(help.stdout.hasPrefix("OVERVIEW:"))
        #expect(!help.stdout.contains("\"error\""))

        let version = try await TestHelpers.runOffsiderCommandSeparated("--version")
        #expect(version.exitCode == 0)
        #expect(!version.stdout.contains("{"))
    }
}

@Suite("Secret echo")
struct SecretEchoTests {
    static let sentinel = "S3NT1NEL"

    @Test("no failure ever echoes typed text", arguments: [
        "type '\(sentinel)'",
        "type '\(sentinel)£'",
        "type '\(sentinel)' --verify --json",
        "batch --json --step 'type \(sentinel)'",
    ])
    func noEcho(command: String) async throws {
        let udid = TestDevices.simulatorUDID()
        defer { TestDevices.removePrivateFiles(platform: .ios, id: udid) }
        let result = try await TestHelpers.runOffsiderCommandSeparated("\(command) --device \(udid)")
        #expect(result.exitCode != 0)
        #expect(!result.stdout.contains(Self.sentinel))
        #expect(!result.stderr.contains(Self.sentinel))
    }
}
