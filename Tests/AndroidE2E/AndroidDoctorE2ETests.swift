import Foundation
import Testing

@Suite("Android doctor and timings", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidDoctorE2ETests {
    static func checks(_ result: SeparatedCommandOutput) throws -> (object: [String: Any], checks: [[String: Any]]) {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return (object, try #require(object["checks"] as? [[String: Any]]))
    }

    @Test("doctor on the E2E emulator passes every device check with the playground open and stay awake on")
    func deviceChecksPass() async throws {
        let serial = try await AndroidE2E.serial()
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let restore = try await AndroidDeviceStateE2ETests.stayOnRestore()
        try await AndroidE2E.run("stay-awake on")
        let result = try await AndroidE2E.offsider("doctor --json")
        try await AndroidE2E.shell(restore)
        let (object, checks) = try Self.checks(result)

        #expect(result.exitCode != 4, "doctor failed: \(result.stderr)")
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["id"] as? String == serial)
        #expect(device["platform"] as? String == "android")
        let perDevice = checks.filter { ($0["id"] as? String)?.hasPrefix("android-device.") == true }
        #expect(perDevice.count == 12)
        #expect(perDevice.contains { $0["id"] as? String == "android-device.memory" })
        #expect(perDevice.contains { $0["id"] as? String == "android-device.lock" })
        let phoneOnly: Set = ["android-device.adb-expiry", "android-device.system-updates"]
        for check in perDevice {
            let expected = phoneOnly.contains(check["id"] as? String ?? "") ? "skip" : "pass"
            #expect(check["status"] as? String == expected, "\(check["id"] ?? ""): \(check["detail"] ?? "")")
        }
        #expect(!checks.contains { ($0["id"] as? String)?.hasPrefix("xcode.") == true })
    }

    @Test("doctor --json helper detail carries a ready time and the gRPC check names only the auth mode")
    func helperAndGrpcDetail() async throws {
        let (_, checks) = try Self.checks(try await AndroidE2E.offsider("doctor --json"))
        let helper = try #require(checks.first { $0["id"] as? String == "android-device.helper" })
        let grpc = try #require(checks.first { $0["id"] as? String == "android-device.grpc" })

        #expect((helper["detail"] as? String)?.hasPrefix("Ready in ") == true)
        let detail = try #require(grpc["detail"] as? String)
        #expect(detail.contains("token auth") || detail.contains("jwt auth"))
    }

    @Test("describe-ui with OFFSIDER_TIMINGS=1 prints the helper phases in the iOS line format")
    func describeTimings() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.run("describe-ui", environment: ["OFFSIDER_TIMINGS": "1"])
        let phases = result.stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard line.hasPrefix("offsider timing: "), parts.count == 5, parts[4] == "ms", Int(parts[3]) != nil else { return nil }
            return String(parts[2])
        }
        let helper = phases.filter { ["helper-launch", "helper-hello", "helper-dump", "tree-map", "helper-close"].contains($0) }

        #expect(phases.first == "prepare")
        #expect(helper == ["helper-launch", "helper-hello", "helper-dump", "tree-map", "helper-close"])
        #expect(phases.last == "total")
    }
}
