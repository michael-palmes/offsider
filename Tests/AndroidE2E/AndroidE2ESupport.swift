import CryptoKit
import Foundation
import Testing

let isAndroidE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()
let isAndroidLandscapeE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_LANDSCAPE_E2E"]?.lowercased() ?? ""
    return isAndroidE2EEnabled && (raw == "1" || raw == "true" || raw == "yes")
}()
let isAndroidBootE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_BOOT_E2E"]?.lowercased() ?? ""
    return isAndroidE2EEnabled && (raw == "1" || raw == "true" || raw == "yes")
}()

struct AndroidE2EError: Error, CustomStringConvertible {
    let description: String
}

/// The guarded emulator, the playground APK, adb and describe-ui helpers for the Android E2E suites.
enum AndroidE2E {
    static let package = "com.mpalmes.offsider.playground.rn"
    static let marker = "/data/local/tmp/offsider-e2e-playground.sha256"

    static var expectedAVD: String {
        let value = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_E2E_AVD"] ?? ""
        return value.isEmpty ? "Offsider_E2E_Pixel_9" : value
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// OFFSIDER_ANDROID_DEVICE resolved through `list-devices`; any AVD but the E2E one is refused before any input.
    static func serial() async throws -> String {
        try await GuardedEmulator.shared.serial()
    }

    static func adbPath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let roots = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { environment[$0] }.filter { !$0.isEmpty }
            + [NSHomeDirectory() + "/Library/Android/sdk"]
        guard let adb = roots.map({ $0 + "/platform-tools/adb" }).first(where: FileManager.default.isExecutableFile) else {
            throw AndroidE2EError(description: "adb not found; set ANDROID_HOME to the Android SDK.")
        }
        return adb
    }

    @discardableResult
    static func adb(_ arguments: String, timeout: TimeInterval = 60) async throws -> String {
        let serial = try await serial()
        let result = try await CommandRunner.runSeparated("\(quote(try adbPath())) -s \(serial) \(arguments)", timeout: timeout)
        guard result.exitCode == 0 else {
            throw AndroidE2EError(description: "adb \(arguments) exited \(result.exitCode): \(result.stderr)")
        }
        return result.stdout
    }

    @discardableResult
    static func shell(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        try await adb("shell \(quote(command))", timeout: timeout)
    }

    /// Runs offsider with `--device` set to the guarded serial.
    static func offsider(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        let serial = try await serial()
        return try await TestHelpers.runOffsiderCommandSeparated("\(arguments) --device \(serial)", environment: environment, timeout: timeout)
    }

    /// Like `offsider`, but a non-zero exit is an error carrying stderr.
    @discardableResult
    static func run(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        let result = try await offsider(arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AndroidE2EError(description: "offsider \(arguments) exited \(result.exitCode): \(result.stderr)")
        }
        return result
    }

    /// OFFSIDER_ANDROID_APK, or OFFSIDER_ANDROID_DEBUG_APK with OFFSIDER_RN_DEBUG_E2E.
    static func apkPath() throws -> String {
        let (variable, kind) = isRNDebugE2EEnabled ? ("OFFSIDER_ANDROID_DEBUG_APK", "debug") : ("OFFSIDER_ANDROID_APK", "release")
        guard let apk = ProcessInfo.processInfo.environment[variable], !apk.isEmpty else {
            throw AndroidE2EError(description: "\(variable) must name the React Native playground's \(kind) APK.")
        }
        return apk
    }

    /// Installs the APK unless the emulator already has this exact one (its SHA-256 in a marker file).
    /// The debug and release APKs share the package, so each records its own digest and the other reinstalls.
    static func ensurePlaygroundInstalled() async throws {
        try await GuardedEmulator.shared.installOnce {
            let apk = try apkPath()
            let digest = try apkDigest(apk)
            let installed = (try? await shell("cat \(marker) 2>/dev/null; pm path \(package)")) ?? ""
            if !(installed.contains(digest) && installed.contains("package:")) {
                try await install(apk, digest: digest)
            }
            if isRNDebugE2EEnabled {
                try await run("rn prepare --bundle-id \(package)")
            }
        }
    }

    /// Uninstalls and installs the APK, leaving the dev client's first-launch state as a new user would see it.
    static func installFresh() async throws {
        let apk = try apkPath()
        _ = try? await adb("uninstall \(package)", timeout: 120)
        try await install(apk, digest: try apkDigest(apk))
    }

    private static func apkDigest(_ apk: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: apk), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A signature mismatch with the installed build (debug over release or the reverse) needs an uninstall first.
    private static func install(_ apk: String, digest: String) async throws {
        do {
            try await adb("install -r \(quote(apk))", timeout: 300)
        } catch let error as AndroidE2EError where error.description.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            try await adb("uninstall \(package)", timeout: 120)
            try await adb("install \(quote(apk))", timeout: 300)
        }
        try await shell("echo \(digest) > \(marker)")
    }

    /// Restarts the playground on a screen by deep link, without waiting for the screen to render.
    /// The debug app first loads its bundle from Metro by the dev client's link, then follows the screen link.
    static func launch(_ screen: String) async throws {
        try await ensurePlaygroundInstalled()
        guard isRNDebugE2EEnabled else {
            try await shell("am start -S -W -a android.intent.action.VIEW -d offsiderplaygroundrn://screen/\(screen) \(package)")
            return
        }
        try await shell("am force-stop \(package)")
        try await shell("am start -W -a android.intent.action.VIEW -d \(quote(RNMetro.devClientURL)) \(package)")
        _ = try await waitForNode(timeout: 180) { $0["id"] as? String == "menu-title" }
        try await shell("am start -W -a android.intent.action.VIEW -d offsiderplaygroundrn://screen/\(screen) \(package)")
    }

    /// Lets the emulator reach Metro on the Mac at its own 127.0.0.1:8742.
    static func reverseMetro() async throws {
        try await adb("reverse tcp:\(RNMetro.port) tcp:\(RNMetro.port)")
    }

    static func removeMetroReverse() async throws {
        try await adb("reverse --remove tcp:\(RNMetro.port)")
    }

    /// Opens a playground screen by deep link and waits until describe-ui shows `id`.
    static func open(_ screen: String, waitingFor id: String) async throws {
        try await launch(screen)
        _ = try await waitForNode(timeout: 40) { $0["id"] as? String == id }
    }

    /// describe-ui on the guarded emulator; a miss answers a starved app's ANR dialog with Wait.
    static let describeUI = DescribeUITree(
        read: { try DescribeUITree.parse(try await run("describe-ui").stdout) },
        onMiss: { nodes in
            if nodes.contains(where: { ($0["id"] as? String)?.hasSuffix(":id/aerr_wait") == true }) {
                try await run("tap --id aerr_wait")
            }
        }
    )

    static func tree() async throws -> [String: Any] {
        try await describeUI.tree()
    }

    static func nodes(in tree: [String: Any]) -> [[String: Any]] {
        DescribeUITree.nodes(in: tree)
    }

    static func label(of id: String) async throws -> String? {
        try await describeUI.label(of: id)
    }

    /// Polls describe-ui until a node matches, retrying failed reads and answering a starved app's ANR dialog with Wait.
    static func waitForNode(timeout: TimeInterval = 20, where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        try await describeUI.waitForNode(timeout: timeout, where: predicate)
    }

    static func waitForLabel(of id: String, timeout: TimeInterval = 20, _ predicate: @escaping (String) -> Bool) async throws -> String {
        try await describeUI.waitForLabel(of: id, timeout: timeout, predicate)
    }
}

/// Resolves and caches the guarded serial, and installs the APK once per test run.
actor GuardedEmulator {
    static let shared = GuardedEmulator()
    private var resolved: String?
    private var installed = false

    func serial() async throws -> String {
        if let resolved { return resolved }
        guard let requested = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_DEVICE"], !requested.isEmpty else {
            throw AndroidE2EError(description: "OFFSIDER_ANDROID_DEVICE must name the E2E emulator (a serial or AVD name).")
        }
        let listing = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android --json")
        guard listing.exitCode == 0,
              let object = try JSONSerialization.jsonObject(with: Data(listing.stdout.utf8)) as? [String: Any],
              let rows = object["devices"] as? [[String: Any]],
              let row = rows.first(where: { $0["id"] as? String == requested || $0["name"] as? String == requested }) else {
            throw AndroidE2EError(description: "OFFSIDER_ANDROID_DEVICE \(requested) is not in `offsider list-devices --platform android`.")
        }
        let name = row["name"] as? String ?? ""
        guard name == AndroidE2E.expectedAVD else {
            throw AndroidE2EError(description: "Refusing \(requested): it is AVD \(name), and Android E2E only drives \(AndroidE2E.expectedAVD) (OFFSIDER_ANDROID_E2E_AVD).")
        }
        guard row["state"] as? String == "Booted", let serial = row["id"] as? String, serial.hasPrefix("emulator-") else {
            throw AndroidE2EError(description: "\(name) is not booted; start it with `offsider boot \(name)`.")
        }
        resolved = serial
        return serial
    }

    func installOnce(_ body: () async throws -> Void) async throws {
        guard !installed else { return }
        try await body()
        installed = true
    }
}

extension AndroidE2E {
    /// The centre of a node's frame, in dp, for coordinate commands.
    static func centre(of id: String) async throws -> (x: Int, y: Int) {
        try await describeUI.centre(of: id)
    }

    /// `Physical size`, or `Override size` when set, from `wm size`.
    static func logicalPixelSize() async throws -> (width: Int, height: Int) {
        let output = try await shell("wm size")
        let line = output.split(separator: "\n").last { $0.contains("Override size:") } ?? output.split(separator: "\n").first { $0.contains("Physical size:") }
        let parts = line?.split(separator: " ").last?.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        guard parts.count == 2 else { throw AndroidE2EError(description: "wm size printed \(output)") }
        return (parts[0], parts[1])
    }

    static func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("offsider-android-e2e-\(UUID().uuidString)-\(name)")
    }
}

extension AndroidE2E {
    /// Polls `check` until it holds; false when `timeout` passes first.
    static func eventually(timeout: TimeInterval, every interval: Duration = .milliseconds(300), _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await check() { return true }
            try await Task.sleep(for: interval)
        } while Date() < deadline
        return false
    }

    /// The text field's value once it equals `text` (an empty `text` also accepts no value).
    static func waitForFieldValue(_ text: String, id: String = "text-input-field", timeout: TimeInterval = 20) async throws -> [String: Any] {
        try await waitForNode(timeout: timeout) { node in
            node["id"] as? String == id && ((node["value"] as? String) ?? "") == text
        }
    }

    /// Whether describe-ui lists the on-screen keyboard as a root.
    static func keyboardShown() async throws -> Bool {
        ((try await tree()["roots"] as? [[String: Any]]) ?? []).contains { $0["role"] as? String == "keyboard" }
    }
}
