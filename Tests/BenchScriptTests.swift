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
        let phone = try await Self.run(["--device", "R5CRFAKE03", "--scenario", "android-describe"], sdk: sdk)

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

    /// An SDK whose adb lists fake phones and answers shell reads; every call is recorded.
    static func fakePhoneSDK(playgroundInstalled: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-phone-sdk-\(UUID().uuidString)")
        let adb = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        echo "$@" >> "$(dirname "$0")/calls"
        case "$*" in
          "devices -l") printf 'List of devices attached\\nR5CRFAKE01             device usb:1-1 product:q2q model:SM_F926B device:q2q transport_id:4\\nR5CRFAKE01X device usb:1-2 model:Other transport_id:5\\nZYFAKE0002 unauthorized usb:2-1 transport_id:6\\nNOUSB0003 device product:x model:y transport_id:7\\n' ;;
          *"pm path"*) \(playgroundInstalled ? "echo package:/data/app/base.apk" : "exit 1") ;;
          *"ro.product.model"*) echo SM-F926B ;;
          *"ro.build.version.sdk"*) echo 35 ;;
          *"dumpsys battery"*) printf '  AC powered: false\\n  level: 87\\n' ;;
          *"dumpsys thermalservice"*) echo 'Thermal Status: 0' ;;
        esac
        exit 0
        """
        try Data(body.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return root
    }

    static func calls(_ sdk: URL) -> [String] {
        let text = (try? String(contentsOf: sdk.appendingPathComponent("platform-tools/calls"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test("--phone refuses a serial that is not an exact USB row in state device, and sends it nothing", arguments: [
        ("R5CRFAKE0", "does not list"), ("ZYFAKE0002", "unauthorized in adb"), ("NOUSB0003", "no usb: field"), ("emulator-5554", "is an emulator"),
    ])
    func phoneGuard(serial: String, reason: String) async throws {
        let sdk = try Self.fakePhoneSDK(playgroundInstalled: true)
        defer { try? FileManager.default.removeItem(at: sdk) }

        let result = try await Self.run(["--phone", "--device", serial, "--scenario", "android-tap-id"], sdk: sdk)

        #expect(result.status == 2)
        #expect(result.stderr.contains(reason), "stderr: \(result.stderr)")
        #expect(Self.calls(sdk).allSatisfy { $0 == "devices -l" }, "calls: \(Self.calls(sdk))")
    }

    @Test("--phone refuses a phone without the playground and never installs it")
    func phoneWithoutPlayground() async throws {
        let sdk = try Self.fakePhoneSDK(playgroundInstalled: false)
        defer { try? FileManager.default.removeItem(at: sdk) }

        let result = try await Self.run(["--phone", "--device", "R5CRFAKE01", "--scenario", "android-tap-id"], sdk: sdk)

        #expect(result.status == 2)
        #expect(result.stderr.contains("never installs"))
        #expect(!Self.calls(sdk).contains { $0.contains("install") })
    }

    @Test("a phone run opens the scenario's screen by deep link and records the phone's state, without emu or install")
    func phoneRun() async throws {
        let sdk = try Self.fakePhoneSDK(playgroundInstalled: true)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-phone-out-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sdk)
            try? FileManager.default.removeItem(at: out)
        }

        let result = try await Self.run(["--phone", "--device", "R5CRFAKE01", "--scenario", "android-type-ascii", "--out", out.path], sdk: sdk)

        #expect(result.status == 0, "stderr: \(result.stderr)")
        let calls = Self.calls(sdk)
        let deepLink = "-s R5CRFAKE01 shell am start -S -W -a android.intent.action.VIEW -d offsiderplaygroundrn://screen/text-input com.mpalmes.offsider.playground.rn"
        #expect(calls.contains(deepLink), "calls: \(calls)")
        #expect(!calls.contains { $0.contains("emu") || $0.contains(" install") || $0.contains("R5CRFAKE01X") })

        let data = try Data(contentsOf: out.appendingPathComponent("result.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let info = try #require(object["deviceInfo"] as? [String: Any])
        #expect(info["phone"] as? Bool == true)
        #expect(info["model"] as? String == "SM-F926B")
        #expect(info["apiLevel"] as? Int == 35)
        #expect((info["batteryLevel"] as? [String: Any])?["start"] as? Int == 87)
        #expect((info["batteryLevel"] as? [String: Any])?["end"] as? Int == 87)
        #expect((info["thermalStatus"] as? [String: Any])?["start"] as? Int == 0)
        #expect(object["device"] as? String == "SM_F926B (USB phone)")
    }

    @Test("every scenario the script knows has a command")
    func scenariosHaveCommands() throws {
        let source = try String(contentsOfFile: Self.script, encoding: .utf8)
        let known = try #require(source.firstMatch(of: #/KNOWN_SCENARIOS="([^"]+)"/#)).1.replacingOccurrences(of: "\\\n", with: " ")
        for scenario in known.split(whereSeparator: \.isWhitespace) {
            #expect(source.contains("\"\(scenario)\""), "\(scenario) has no command")
        }
    }
}
