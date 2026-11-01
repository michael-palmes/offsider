import Foundation
import OffsiderCore
import Testing

/// Set by `--rn-debug`: a debuggable build under the playground's own id, which `app prefs` needs.
private let debugAPK = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_DEBUG_APK"].flatMap { $0.isEmpty ? nil : $0 }

@Suite("Android app install, prefs, broadcast and airplane", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidAppManagementE2ETests {
    static let app = "--app \(AndroidE2E.package)"
    /// The stock receiver every Android app's profile installer declares: it answers with a non-zero result code.
    static let receiverAction = "androidx.profileinstaller.action.INSTALL_PROFILE"
    static let secret = "PLANTED-SECRET-VALUE-7f3a9"

    static func json(_ output: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    @Test("uninstall, then install of an APK checked against its package, then a cold launch with Android's timings")
    func installCycle() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        let apk = try AndroidE2E.apkPath()

        let refused = try await AndroidE2E.offsider("app install \(AndroidE2E.quote(apk)) --app com.example.other --json")
        #expect(refused.exitCode == 1)
        #expect((refused.stdout + refused.stderr).contains("package_mismatch"))

        let removed = try await AndroidE2E.run("app uninstall \(Self.app) --json")
        #expect(try Self.json(removed.stdout)["wasInstalled"] as? Bool == true)
        #expect((try? await AndroidE2E.shell("pm path \(AndroidE2E.package)"))?.contains("package:") != true)
        let again = try await AndroidE2E.run("app uninstall \(Self.app) --json")
        #expect(try Self.json(again.stdout)["wasInstalled"] as? Bool == false)

        // Later suites expect the release build, so it comes back whatever this test finds.
        let installed = try await AndroidE2E.run("app install \(AndroidE2E.quote(apk)) --json", timeout: 300)
        let report = try Self.json(installed.stdout)
        #expect(report["app"] as? String == AndroidE2E.package)
        #expect(report["replaced"] as? Bool == false)
        #expect(try await AndroidE2E.shell("pm path \(AndroidE2E.package)").contains("package:"))

        let launch = try Self.json(try await AndroidE2E.run("app launch --cold --json \(Self.app)").stdout)
        #expect(launch["start"] as? String == "cold")
        #expect(launch["launchState"] as? String == "COLD")
        #expect((launch["milliseconds"] as? Int ?? 0) > 0)
        #expect((launch["waitMilliseconds"] as? Int ?? 0) > 0)
        _ = try? await AndroidE2E.offsider("app stop \(Self.app)")
    }

    @Test("a broadcast reaches the app's own receiver; a protected action, a missing receiver and another app's package do not")
    func broadcast() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        let sent = try Self.json(try await AndroidE2E.run("app broadcast \(Self.receiverAction) \(Self.app) --json").stdout)
        #expect((sent["resultCode"] as? Int ?? 0) != 0)
        #expect((sent["receivers"] as? [String])?.contains("androidx.profileinstaller.ProfileInstallReceiver") == true)

        let protected = try await AndroidE2E.offsider("app broadcast android.appwidget.action.APPWIDGET_UPDATE \(Self.app)")
        #expect(protected.exitCode == 1)
        #expect(protected.stderr.contains("Nothing was sent"))
        #expect(protected.stderr.contains(Self.receiverAction) || protected.stderr.contains("Send an action"))

        let missing = try await AndroidE2E.offsider("app broadcast a.b.C --receiver .NoSuchReceiver \(Self.app)")
        #expect(missing.exitCode == 1)
        #expect(missing.stderr.contains("no receiver"))

        let absent = try await AndroidE2E.offsider("app broadcast a.b.C --app com.example.notinstalled")
        #expect(absent.exitCode == 1)
        #expect(absent.stderr.contains("not installed"))
    }

    @Test("a release build refuses prefs and names the fix")
    func prefsOnRelease() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        let refused = try await AndroidE2E.offsider("app prefs \(Self.app)")
        #expect(refused.exitCode == 1)
        #expect(refused.stderr.contains("offsider app install"))
    }

    @Test("a planted value reaches neither stdout, stderr, the tree cache nor a run's manifest", .enabled(if: debugAPK != nil))
    func plantedSecret() async throws {
        let apk = try #require(debugAPK)
        try await AndroidE2E.ensurePlaygroundInstalled()
        _ = try await AndroidE2E.run("app uninstall \(Self.app)")
        try await AndroidE2E.run("app install \(AndroidE2E.quote(apk)) \(Self.app)", timeout: 300)
        // The other suites expect the release build, so it comes back whatever this test finds.
        let release = try AndroidE2E.apkPath()
        try await AndroidDeviceStateE2ETests.restoring({ _ = try? await AndroidE2E.offsider("app install \(AndroidE2E.quote(release))", timeout: 300) }) {
            try await Self.checkPlantedSecret()
        }
    }

    private static func checkPlantedSecret() async throws {
        let file = """
        <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map>
            <string name="auth_token">\(secret)</string>
            <int name="launch_count" value="314159" />
            <set name="tags"><string>\(secret)</string></set>
        </map>
        """
        let encoded = Data(file.utf8).base64EncodedString()
        _ = try await AndroidE2E.shell("run-as \(AndroidE2E.package) sh -c 'mkdir -p shared_prefs && echo \(encoded) | base64 -d > shared_prefs/offsider_e2e.xml'")

        let run = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-prefs-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: run) }
        var environment = ProcessInfo.processInfo.environment
        environment["OFFSIDER_RUN"] = run.path
        _ = try await TestHelpers.runOffsiderCommandSeparated("run start \(AndroidE2E.quote(run.path)) --label e2e", environment: environment, timeout: 30)

        let text = try await AndroidE2E.run("app prefs \(app)", environment: environment)
        let json = try await AndroidE2E.run("app prefs \(app) --json", environment: environment)
        _ = try await AndroidE2E.run("describe-ui --summary", environment: environment)
        for output in [text.stdout, text.stderr, json.stdout, json.stderr] {
            #expect(!output.contains(secret))
            #expect(!output.contains("314159"))
        }
        #expect(text.stdout.contains("auth_token") && json.stdout.contains(#""name":"auth_token","type":"string""#))

        let manifest = try String(contentsOf: run.appendingPathComponent(RunFolder.manifestName), encoding: .utf8)
        #expect(manifest.contains(#""command":"app prefs""#))
        #expect(manifest.contains(#""entries":3"#))
        #expect(!manifest.contains(secret))

        let trees = URL(fileURLWithPath: OffsiderPrivateDirectory.root).appendingPathComponent("trees")
        let cached = FileManager.default.enumerator(at: trees, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(!cached.isEmpty, "describe-ui should have written the tree cache")
        for url in cached {
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(url.lastPathComponent)")
        }
    }

    @Test("what airplane on set, session stop resets; what was already on, it leaves")
    func airplane() async throws {
        _ = try await AndroidE2E.shell("cmd connectivity airplane-mode disable")
        try await AndroidDeviceStateE2ETests.restoring({ _ = try? await AndroidE2E.shell("cmd connectivity airplane-mode disable") }) {
            try await Self.checkAirplane()
        }
    }

    private static func checkAirplane() async throws {
        let setting = { try await AndroidE2E.shell("settings get global airplane_mode_on").trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(try json(try await AndroidE2E.run("airplane --json").stdout)["airplane"] as? String == "off")

        let on = try json(try await AndroidE2E.run("airplane on --json").stdout)
        #expect(on["airplane"] as? String == "on" && on["resetBySessionStop"] as? Bool == true)
        #expect(try await setting() == "1")
        let stopped = try await AndroidE2E.run("session stop --json")
        #expect(stopped.stdout.contains(#""airplane":true"#))
        #expect(try await setting() == "0")

        _ = try await AndroidE2E.shell("cmd connectivity airplane-mode enable")
        let already = try json(try await AndroidE2E.run("airplane on --json").stdout)
        #expect(already["resetBySessionStop"] as? Bool == false)
        _ = try await AndroidE2E.run("session stop")
        #expect(try await setting() == "1")
        let off = try json(try await AndroidE2E.run("airplane off --json").stdout)
        #expect(off["airplane"] as? String == "off")
    }
}
