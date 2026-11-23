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
        let sdk = try Self.fakeSDK(avd: "Offsider_E2E")
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
          "devices -l") printf 'List of devices attached\\nR5CRFAKE01             device usb:1-1 product:f0ld model:SM_F000B device:f0ld transport_id:4\\nR5CRFAKE01X device usb:1-2 model:Other transport_id:5\\nZYFAKE0002 unauthorized usb:2-1 transport_id:6\\nNOUSB0003 device product:x model:y transport_id:7\\n' ;;
          *"pm path"*) \(playgroundInstalled ? "echo package:/data/app/base.apk" : "exit 1") ;;
          *"ro.product.model"*) echo SM-F000B ;;
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
        #expect(info["model"] as? String == "SM-F000B")
        #expect(info["apiLevel"] as? Int == 35)
        #expect((info["batteryLevel"] as? [String: Any])?["start"] as? Int == 87)
        #expect((info["batteryLevel"] as? [String: Any])?["end"] as? Int == 87)
        #expect((info["thermalStatus"] as? [String: Any])?["start"] as? Int == 0)
        #expect(object["device"] as? String == "SM_F000B (USB phone)")
    }

    /// A throwaway repository whose base pins idb `basePin` and head `headPin`, with head's frameworks built; the base's `build.sh dev` records its call and builds its own pin.
    static func pinnedRepo(basePin: String, headPin: String) throws -> (root: URL, base: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-repo-\(UUID().uuidString)")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: script, toPath: scripts.appendingPathComponent("bench-ab.sh").path)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/lib/adb.sh"), to: scripts.appendingPathComponent("lib/adb.sh"))
        func git(_ arguments: [String]) throws -> String { try Self.git(arguments, in: root) }
        func writeBuildScript(pin: String) throws {
            let body = """
            #!/bin/bash
            DEFAULT_IDB_GIT_REF="\(pin)"
            echo "$@" >> "$(pwd)/build-calls"
            mkdir -p build_products/XCFrameworks idb_checkout
            echo "IDB_SHA=\(pin)" > build_products/XCFrameworks/IDB_BUILD_EVIDENCE.txt
            """
            let path = scripts.appendingPathComponent("build.sh")
            try Data(body.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try Data("build_products/\nidb_checkout/\nbuild-calls\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(["init", "-q"])
        try writeBuildScript(pin: basePin)
        _ = try git(["add", "-A"])
        _ = try git(["commit", "-q", "-m", "base"])
        let base = try git(["rev-parse", "--short", "HEAD"])
        try writeBuildScript(pin: headPin)
        _ = try git(["commit", "-q", "-am", "head"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build_products/XCFrameworks"), withIntermediateDirectories: true)
        try Data("IDB_SHA=\(headPin)\n".utf8).write(to: root.appendingPathComponent("build_products/XCFrameworks/IDB_BUILD_EVIDENCE.txt"))
        return (root, base)
    }

    @discardableResult
    static func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=Bench", "-c", "user.email=bench@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runBase(in repo: URL, base: String, sdk: URL, benchDir: URL) async throws -> ProcessCaptureResult {
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = sdk.path
        environment["OFFSIDER_BENCH_DIR"] = benchDir.path
        return try await ProcessCapture.run(
            executable: "/bin/bash",
            arguments: [repo.appendingPathComponent("scripts/bench-ab.sh").path, "--device", "emulator-5556", "--scenario", "android-describe",
                        "--base", base, "--head-bin", "/usr/bin/true", "--pairs", "1", "--warmup", "0"],
            environment: environment,
            timeout: 120
        )
    }

    static let pinA = String(repeating: "a", count: 40)
    static let pinB = String(repeating: "b", count: 40)

    @Test("a base that pins another idb builds its own frameworks in its worktree, never this checkout's", arguments: [true, false])
    func baseGetsItsOwnFrameworks(samePin: Bool) async throws {
        let sdk = try Self.fakeSDK(avd: "Offsider_E2E")
        let (repo, base) = try Self.pinnedRepo(basePin: samePin ? Self.pinB : Self.pinA, headPin: Self.pinB)
        let bench = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-pins-\(UUID().uuidString)")
        defer {
            for url in [sdk, repo, bench] { try? FileManager.default.removeItem(at: url) }
        }

        let result = try await Self.runBase(in: repo, base: base, sdk: sdk, benchDir: bench)

        let worktree = bench.appendingPathComponent("worktrees/\(base)")
        let evidence = try String(contentsOf: worktree.appendingPathComponent("build_products/XCFrameworks/IDB_BUILD_EVIDENCE.txt"), encoding: .utf8)
        let calls = (try? String(contentsOf: worktree.appendingPathComponent("build-calls"), encoding: .utf8)) ?? ""
        #expect(evidence.contains("IDB_SHA=\(samePin ? Self.pinB : Self.pinA)"), "stderr: \(result.stderr)")
        #expect(calls.contains("dev") == !samePin, "build calls: \(calls)")
        #expect(result.stderr.contains("gets its own frameworks") == !samePin)
    }

    @Test("every scenario the script knows has a command")
    func scenariosHaveCommands() throws {
        let source = try String(contentsOfFile: Self.script, encoding: .utf8)
        let known = try #require(source.firstMatch(of: #/KNOWN_SCENARIOS="([^"]+)"/#)).1.replacingOccurrences(of: "\\\n", with: " ")
        for scenario in known.split(whereSeparator: \.isWhitespace) {
            #expect(source.contains("\"\(scenario)\""), "\(scenario) has no command")
        }
    }

    @Test("a verified command's timing suffix and report times are left out of the output hash, so its pairs are kept")
    func verifyTimingNormalised() async throws {
        let sdk = try Self.fakePhoneSDK(playgroundInstalled: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bench-timing-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sdk)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("offsider")
        let body = """
        #!/bin/sh
        echo "✓ Tap on id=tap-test-area verified: accessibility tree changed, attempt 1 of 2, sent as one tap event (settle 0.$$ s, tap 0.1 s, verify 1.$$ s)"
        echo '{"verified":true,"elapsedMs":'$$',"phasesMs":{"settle":'$$',"verify":1}}'
        """
        try Data(body.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = sdk.path
        let out = root.appendingPathComponent("records")
        let result = try await ProcessCapture.run(
            executable: "/bin/bash",
            arguments: [Self.script, "--phone", "--device", "R5CRFAKE01", "--scenario", "android-tap-id-verify", "--out", out.path,
                        "--base-bin", fake.path, "--head-bin", fake.path, "--pairs", "3", "--warmup", "0"],
            environment: environment,
            timeout: 60
        )

        #expect(result.status == 0, "stderr: \(result.stderr)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("result.json"))) as? [String: Any])
        let scenario = try #require((object["scenarios"] as? [[String: Any]])?.first)
        #expect(scenario["kept"] as? Int == 3)
        #expect(scenario["verdict"] as? String != "unstable")
    }
}
