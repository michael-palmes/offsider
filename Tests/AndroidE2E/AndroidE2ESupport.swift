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
let isAndroidFoldE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_FOLD_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()
/// OFFSIDER_ANDROID_PHONE: the one USB phone the phone suites may drive, named by its exact serial.
let androidPhoneSerial: String? = {
    let value = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_PHONE"]?.trimmingCharacters(in: .whitespaces) ?? ""
    return value.isEmpty ? nil : value
}()
let isAndroidPhoneE2EEnabled = androidPhoneSerial != nil
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

    /// The only AVDs any Android suite may drive; OFFSIDER_ANDROID_E2E_AVD picks one of them.
    static let allowedAVDs: Set<String> = ["Offsider_E2E_Pixel_9", "Offsider_E2E_Pixel_9_Pro_Fold"]
    static let foldAVD = "Offsider_E2E_Pixel_9_Pro_Fold"

    static var expectedAVD: String {
        let value = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_E2E_AVD"] ?? ""
        return value.isEmpty ? "Offsider_E2E_Pixel_9" : value
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// OFFSIDER_ANDROID_DEVICE checked through its console when a serial, else through `list-devices`; any AVD but the E2E one is refused before any input.
    /// With OFFSIDER_ANDROID_PHONE set, that phone alone, checked against `adb devices -l`.
    static func serial() async throws -> String {
        if isAndroidPhoneE2EEnabled {
            return try await GuardedPhone.shared.serial()
        }
        return try await GuardedEmulator.shared.serial()
    }

    private static func installOnce(_ body: () async throws -> Void) async throws {
        if isAndroidPhoneE2EEnabled {
            try await GuardedPhone.shared.installOnce(body)
        } else {
            try await GuardedEmulator.shared.installOnce(body)
        }
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
        try await installOnce {
            let apk = try apkPath()
            let digest = try apkDigest(apk)
            let installed = (try? await shell("cat \(marker) 2>/dev/null; pm path \(package)")) ?? ""
            if !(installed.contains(digest) && installed.contains("package:")) {
                if try await installedDigest() == digest {
                    try await shell("echo \(digest) > \(marker)")
                } else {
                    try await install(apk, digest: digest)
                }
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

    /// The SHA-256 of the installed package's base APK, so a build installed by hand is adopted instead of reinstalled.
    private static func installedDigest() async throws -> String? {
        let path = (try? await shell("pm path \(package)"))?.split(whereSeparator: \.isNewline).first { $0.hasPrefix("package:") }
        guard let path else { return nil }
        let sum = try await shell("sha256sum \(path.dropFirst("package:".count)) 2>/dev/null", timeout: 120)
        return sum.split(separator: " ").first.map(String.init)
    }

    /// Pushed and installed by `pm`, because `adb install` on a phone with Google Play waits on a Play Protect prompt.
    /// A signature mismatch with the installed build (debug over release or the reverse) needs an uninstall first.
    private static func install(_ apk: String, digest: String) async throws {
        let remote = "/data/local/tmp/offsider-e2e-playground.apk"
        try await adb("push \(quote(apk)) \(remote)", timeout: 300)
        do {
            try await shellInstall("pm install -r \(remote)")
        } catch let error as AndroidE2EError where error.description.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            try await adb("uninstall \(package)", timeout: 120)
            try await shellInstall("pm install \(remote)")
        }
        _ = try? await shell("rm \(remote)")
        try await shell("echo \(digest) > \(marker)")
    }

    /// `pm install` reports failure on stdout with exit 0 on some builds, so the text is checked too.
    private static func shellInstall(_ command: String) async throws {
        let output = try await shell(command, timeout: 300)
        guard output.contains("Success") else {
            throw AndroidE2EError(description: "\(command) answered \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
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

    /// Answers an "isn't responding" dialog with Wait when one has focus; otherwise one cheap focus read.
    static func dismissANRDialog() async throws {
        let focus = (try? await shell("dumpsys window | grep mCurrentFocus || true", timeout: 30)) ?? ""
        guard focus.contains("Not Responding") else { return }
        _ = try? await offsider("tap --id aerr_wait")
        try await Task.sleep(for: .seconds(2))
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
/// The pure decision behind every Android E2E device: only an `emulator-N` serial whose console names an allowed AVD.
enum AndroidE2EGuard {
    /// What can be decided before any adb call: the serial's shape (when known) and whether the expected AVD is allowed.
    static func preflight(serial: String?, expected: String, allowed: Set<String>) -> Result<Void, AndroidE2EError> {
        guard allowed.contains(expected) else {
            return .failure(AndroidE2EError(description: "OFFSIDER_ANDROID_E2E_AVD \(expected) is not one of the E2E AVDs: \(allowed.sorted().joined(separator: ", "))."))
        }
        if let serial, serial.wholeMatch(of: #/emulator-[0-9]+/#) == nil {
            return .failure(AndroidE2EError(description: "Refusing \(serial): Android E2E drives only emulator-N serials, never a phone or a network device."))
        }
        return .success(())
    }

    static func verdict(serial: String, avdName: String?, expected: String, allowed: Set<String>) -> Result<String, AndroidE2EError> {
        if case .failure(let error) = preflight(serial: serial, expected: expected, allowed: allowed) {
            return .failure(error)
        }
        guard let avdName, !avdName.isEmpty else {
            return .failure(AndroidE2EError(description: "Refusing \(serial): its console did not name an AVD."))
        }
        guard avdName == expected else {
            return .failure(AndroidE2EError(description: "Refusing \(serial): `adb -s \(serial) emu avd name` printed \(avdName), and Android E2E only drives \(expected) (OFFSIDER_ANDROID_E2E_AVD)."))
        }
        return .success(serial)
    }
}

/// The pure decision behind the phone suites: only the exact OFFSIDER_ANDROID_PHONE serial, attached over USB and authorised.
enum AndroidPhoneGuard {
    /// The emulator suites' switches; any one of them set keeps the phone suites off.
    static let emulatorFlags = ["OFFSIDER_ANDROID_E2E", "OFFSIDER_ANDROID_FOLD_E2E", "OFFSIDER_ANDROID_LANDSCAPE_E2E", "OFFSIDER_ANDROID_BOOT_E2E"]

    /// The emulator switches set to a true value in `environment`.
    static func emulatorFlagsSet(in environment: [String: String]) -> [String] {
        emulatorFlags.filter { ["1", "true", "yes"].contains(environment[$0]?.lowercased() ?? "") }
    }

    /// What can be decided before any adb call.
    static func preflight(requested: String, emulatorFlags set: [String]) -> Result<Void, AndroidE2EError> {
        if !set.isEmpty {
            let names = set.joined(separator: ", ")
            return .failure(AndroidE2EError(description: "OFFSIDER_ANDROID_PHONE and \(names) are both set; the phone suites and the emulator suites run one at a time, so unset \(names) or OFFSIDER_ANDROID_PHONE."))
        }
        if requested.wholeMatch(of: #/emulator-[0-9]+/#) != nil {
            return .failure(AndroidE2EError(description: "Refusing \(requested): OFFSIDER_ANDROID_PHONE names a USB phone; emulators run through OFFSIDER_ANDROID_DEVICE."))
        }
        if requested.wholeMatch(of: #/[A-Za-z0-9._-]+/#) == nil {
            return .failure(AndroidE2EError(description: "Refusing \(requested): OFFSIDER_ANDROID_PHONE must be a USB serial from `adb devices -l`, never a network address."))
        }
        return .success(())
    }

    /// The serial when `adb devices -l` lists exactly it, in state `device`, with a `usb:` field.
    static func verdict(requested: String, emulatorFlags set: [String], devices: String) -> Result<String, AndroidE2EError> {
        if case .failure(let error) = preflight(requested: requested, emulatorFlags: set) {
            return .failure(error)
        }
        let rows = devices.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let row = rows.first(where: { $0.first == requested }) else {
            return .failure(AndroidE2EError(description: "Refusing \(requested): `adb devices -l` does not list it. Connect the phone by USB and accept the debugging prompt."))
        }
        guard row.count > 1, row[1] == "device" else {
            let state = row.count > 1 ? row[1] : "unknown"
            return .failure(AndroidE2EError(description: "Refusing \(requested): its adb state is \(state), not device. Unlock it and accept the USB debugging prompt."))
        }
        guard row.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
            return .failure(AndroidE2EError(description: "Refusing \(requested): its `adb devices -l` row has no usb: field, so it is not attached by USB."))
        }
        return .success(requested)
    }
}

/// Resolves OFFSIDER_ANDROID_PHONE once from `adb devices -l`; never sends `emu` and never falls back to another serial.
actor GuardedPhone {
    static let shared = GuardedPhone()
    private var resolved: String?
    private var installed = false

    func serial() async throws -> String {
        if let resolved { return resolved }
        guard let requested = androidPhoneSerial else {
            throw AndroidE2EError(description: "OFFSIDER_ANDROID_PHONE must name the phone's USB serial.")
        }
        let emulatorFlags = AndroidPhoneGuard.emulatorFlagsSet(in: ProcessInfo.processInfo.environment)
        try AndroidPhoneGuard.preflight(requested: requested, emulatorFlags: emulatorFlags).get()
        let listing = try await CommandRunner.runSeparated(
            "\(AndroidE2E.quote(try AndroidE2E.adbPath())) devices -l", environment: ["ADB_MDNS": "0"], timeout: 30
        )
        guard listing.exitCode == 0 else {
            throw AndroidE2EError(description: "adb devices -l exited \(listing.exitCode): \(listing.stderr)")
        }
        let serial = try AndroidPhoneGuard.verdict(requested: requested, emulatorFlags: emulatorFlags, devices: listing.stdout).get()
        resolved = serial
        return serial
    }

    func installOnce(_ body: () async throws -> Void) async throws {
        guard !installed else { return }
        try await body()
        installed = true
    }
}

actor GuardedEmulator {
    static let shared = GuardedEmulator()
    private var resolved: String?
    private var installed = false

    func serial() async throws -> String {
        if let resolved { return resolved }
        guard let requested = ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_DEVICE"], !requested.isEmpty else {
            throw AndroidE2EError(description: "OFFSIDER_ANDROID_DEVICE must name the E2E emulator (a serial or AVD name).")
        }
        let serial = requested.wholeMatch(of: #/emulator-[0-9]+/#) != nil
            ? try await Self.checkedSerial(requested)
            : try await Self.listedSerial(requested)
        resolved = serial
        return serial
    }

    /// Checks the serial's shape before any adb call, so a phone is never sent `emu avd name`;
    /// then asks that emulator's console alone for its AVD name, and checks it finished booting.
    private static func checkedSerial(_ serial: String) async throws -> String {
        try AndroidE2EGuard.preflight(serial: serial, expected: AndroidE2E.expectedAVD, allowed: AndroidE2E.allowedAVDs).get()
        let adb = AndroidE2E.quote(try AndroidE2E.adbPath())
        let named = try await CommandRunner.runSeparated("\(adb) -s \(serial) emu avd name", timeout: 30)
        let name = named.stdout.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard named.exitCode == 0, !name.isEmpty else {
            let output = (named.stderr + named.stdout).split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidE2EError(description: "Refusing \(serial): `adb -s \(serial) emu avd name` exited \(named.exitCode) without an AVD name (\(output)).")
        }
        _ = try AndroidE2EGuard.verdict(serial: serial, avdName: name, expected: AndroidE2E.expectedAVD, allowed: AndroidE2E.allowedAVDs).get()
        let booted = try await CommandRunner.runSeparated("\(adb) -s \(serial) shell getprop sys.boot_completed", timeout: 30)
        let flag = booted.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard booted.exitCode == 0, flag == "1" else {
            throw AndroidE2EError(description: "\(name) (\(serial)) has not finished booting: sys.boot_completed is '\(flag)'. Wait, or start it with `offsider boot \(name)`.")
        }
        return serial
    }

    /// An AVD name is resolved through `list-devices`; the row's serial then passes the same console check,
    /// so a listed row never stands in for `emu avd name`.
    private static func listedSerial(_ requested: String) async throws -> String {
        try AndroidE2EGuard.preflight(serial: nil, expected: AndroidE2E.expectedAVD, allowed: AndroidE2E.allowedAVDs).get()
        let listing = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android --json")
        guard listing.exitCode == 0,
              let object = try JSONSerialization.jsonObject(with: Data(listing.stdout.utf8)) as? [String: Any],
              let rows = object["devices"] as? [[String: Any]],
              let row = rows.first(where: { $0["id"] as? String == requested || $0["name"] as? String == requested }) else {
            throw AndroidE2EError(description: "OFFSIDER_ANDROID_DEVICE \(requested) is not in `offsider list-devices --platform android`.")
        }
        let name = row["name"] as? String ?? ""
        guard row["state"] as? String == "Booted", let serial = row["id"] as? String else {
            throw AndroidE2EError(description: "\(name) is not booted; start it with `offsider boot \(name)`.")
        }
        return try await checkedSerial(serial)
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
