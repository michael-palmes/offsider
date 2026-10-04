import Foundation
import OffsiderCore
import Testing

@Suite("bench-ab script")
struct BenchScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/bench-ab.sh").path

    /// An SDK whose adb answers `emu avd name` with `avd`, and records any other call.
    static func fakeSDK(avd: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-sdk-\(UUID().uuidString)")
        let adb = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        if [ "$3 $4 $5" = "emu avd name" ]; then printf '%s\\r\\nOK\\r\\n' '\(avd)'; exit 0; fi
        echo "$@" >> "$(dirname "$0")/calls"
        exit 1
        """
        try Data(body.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return root
    }

    static func run(_ arguments: [String], sdk: URL) async throws -> ProcessCaptureResult {
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = sdk.path
        environment["OFFSIDER_BENCH_DIR"] = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-test-\(UUID().uuidString)").path
        return try await ProcessCapture.run(
            executable: "/bin/bash",
            arguments: [script] + arguments + ["--base-bin", "/usr/bin/true", "--head-bin", "/usr/bin/true", "--pairs", "1", "--warmup", "0"],
            environment: environment,
            timeout: 60
        )
    }

    @Test("bench-ab refuses a device that is not an Offsider AVD or simulator, before sending it anything")
    func refusesOtherDevices() async throws {
        let sdk = try Self.fakeSDK(avd: "SomeoneElsesAVD")
        defer { try? FileManager.default.removeItem(at: sdk) }

        let otherAVD = try await Self.run(["--device", "emulator-5554", "--scenario", "android-describe"], sdk: sdk)
        let phone = try await Self.run(["--device", "RFCRA0TCR5B", "--scenario", "android-describe"], sdk: sdk)

        #expect(otherAVD.status == 2)
        #expect(otherAVD.stderr.contains("runs AVD 'SomeoneElsesAVD'"))
        #expect(phone.status == 2)
        #expect(phone.stderr.contains("is not an emulator serial"))
        #expect(!FileManager.default.fileExists(atPath: sdk.appendingPathComponent("platform-tools/calls").path))
    }

    @Test("bench-ab refuses an output directory inside the repo that git does not ignore")
    func refusesUnignoredOutput() async throws {
        let sdk = try Self.fakeSDK(avd: "Offsider_E2E_Pixel_9")
        defer { try? FileManager.default.removeItem(at: sdk) }
        let inside = Self.repo.appendingPathComponent("bench-records-\(UUID().uuidString)")

        let result = try await Self.run(["--device", "emulator-5556", "--scenario", "android-describe", "--out", inside.path], sdk: sdk)

        #expect(result.status == 2)
        #expect(result.stderr.contains("not ignored by git"))
        #expect(!FileManager.default.fileExists(atPath: inside.path))
    }
}
