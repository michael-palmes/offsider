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

    /// Installs OFFSIDER_ANDROID_APK unless the emulator already has this exact APK (its SHA-256 in a marker file).
    static func ensurePlaygroundInstalled() async throws {
        try await GuardedEmulator.shared.installOnce {
            guard let apk = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_APK"], !apk.isEmpty else {
                throw AndroidE2EError(description: "OFFSIDER_ANDROID_APK must name the React Native playground's release APK.")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: apk), options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let installed = (try? await shell("cat \(marker) 2>/dev/null; pm path \(package)")) ?? ""
            if installed.contains(digest), installed.contains("package:") {
                return
            }
            try await adb("install -r \(quote(apk))", timeout: 300)
            try await shell("echo \(digest) > \(marker)")
        }
    }

    /// Opens a playground screen by deep link and waits until describe-ui shows `id`.
    static func open(_ screen: String, waitingFor id: String) async throws {
        try await ensurePlaygroundInstalled()
        try await shell("am start -S -W -a android.intent.action.VIEW -d offsiderplaygroundrn://screen/\(screen) \(package)")
        _ = try await waitForNode(timeout: 40) { $0["id"] as? String == id }
    }

    static func tree() async throws -> [String: Any] {
        let result = try await run("describe-ui")
        guard let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            throw AndroidE2EError(description: "describe-ui printed no JSON object")
        }
        return object
    }

    static func nodes(in tree: [String: Any]) -> [[String: Any]] {
        func walk(_ node: [String: Any]) -> [[String: Any]] {
            [node] + ((node["children"] as? [[String: Any]]) ?? []).flatMap(walk)
        }
        return ((tree["roots"] as? [[String: Any]]) ?? []).flatMap(walk)
    }

    static func label(of id: String) async throws -> String? {
        nodes(in: try await tree()).first { $0["id"] as? String == id }?["label"] as? String
    }

    /// Polls describe-ui until a node matches, retrying failed reads and answering a starved app's ANR dialog with Wait.
    static func waitForNode(timeout: TimeInterval = 20, where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: (any Error)?
        repeat {
            do {
                let found = nodes(in: try await tree())
                if let node = found.first(where: predicate) {
                    return node
                }
                if found.contains(where: { ($0["id"] as? String)?.hasSuffix(":id/aerr_wait") == true }) {
                    try await run("tap --id aerr_wait")
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        throw AndroidE2EError(description: "no matching node within \(Int(timeout)) s" + (lastError.map { " (last error: \($0))" } ?? ""))
    }

    static func waitForLabel(of id: String, timeout: TimeInterval = 20, _ predicate: @escaping (String) -> Bool) async throws -> String {
        let node = try await waitForNode(timeout: timeout) { node in
            node["id"] as? String == id && (node["label"] as? String).map(predicate) == true
        }
        return node["label"] as? String ?? ""
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
        let node = try await waitForNode { $0["id"] as? String == id }
        guard let frame = node["frame"] as? [String: Double],
              let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else {
            throw AndroidE2EError(description: "\(id) has no frame")
        }
        return (Int((x + width / 2).rounded()), Int((y + height / 2).rounded()))
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
    /// `type --file`, because Foundation decomposes non-ASCII process arguments (é becomes e plus U+0301).
    @discardableResult
    static func type(_ text: String, environment: [String: String]? = nil) async throws -> SeparatedCommandOutput {
        let file = temporaryFile("type.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(text.utf8).write(to: file)
        return try await run("type --file \(quote(file.path))", environment: environment)
    }
}
