import CryptoKit
import Foundation

/// The React Native playground on the SIMULATOR_UDID simulator: the Release app, or with OFFSIDER_RN_DEBUG_E2E the Debug app on Metro.
enum IOSRNPlayground {
    static let bundleID = "com.mpalmes.offsider.playground.rn"

    static func udid() throws -> String {
        guard let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !udid.isEmpty else {
            throw DescribeUIError(description: "SIMULATOR_UDID must name the booted simulator for the React Native iOS E2E suites.")
        }
        return udid
    }

    static func appPath() throws -> String {
        let (variable, build) = isRNDebugE2EEnabled
            ? ("OFFSIDER_RN_IOS_DEBUG_APP", "build-ios --debug")
            : ("OFFSIDER_RN_IOS_APP", "build-ios")
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw DescribeUIError(description: "\(variable) must name the React Native playground's .app (build it with `scripts/rn-playground.sh \(build)`).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DescribeUIError(description: "\(variable) \(path) is not an .app bundle; build it with `scripts/rn-playground.sh \(build)`.")
        }
        return path
    }

    /// SHA-256 over the executable plus `main.jsbundle` (Release) or the `.debug.dylib` (Debug), so a rebuild or a switch of build is noticed.
    static func digest(ofApp path: String) throws -> String {
        let app = URL(fileURLWithPath: path)
        let plist = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String else {
            throw DescribeUIError(description: "\(path) has no CFBundleExecutable in its Info.plist")
        }
        var hasher = SHA256()
        for name in [executable, "main.jsbundle", "\(executable).debug.dylib"] {
            let file = app.appendingPathComponent(name)
            guard name == executable || FileManager.default.fileExists(atPath: file.path) else { continue }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The installed app's bundle path, or nil when it is not installed.
    static func installedAppPath() async throws -> String? {
        let container = try await CommandRunner.runSeparated("xcrun simctl get_app_container \(try udid()) \(bundleID) app")
        let path = container.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return container.exitCode == 0 && !path.isEmpty ? path : nil
    }

    /// Installs the app once per test process, skipping the install when the simulator already has the same build.
    static func ensureInstalled() async throws {
        try await IOSRNInstallGate.shared.installOnce {
            let app = try appPath()
            if let installed = try await installedAppPath(), (try? digest(ofApp: installed)) == (try digest(ofApp: app)) {
                try await prepareDevClientIfDebug()
                return
            }
            try await install(app)
            try await prepareDevClientIfDebug()
        }
    }

    /// Uninstalls and installs the app, leaving the dev client's first-launch state as a new user would see it.
    static func installFresh() async throws {
        let udid = try udid()
        _ = try await CommandRunner.runSeparated("xcrun simctl uninstall \(udid) \(bundleID)", timeout: 60)
        try await install(try appPath())
    }

    private static func install(_ app: String) async throws {
        let udid = try udid()
        let result = try await CommandRunner.runSeparated("xcrun simctl install \(udid) \(AndroidE2E.quote(app))", timeout: 300)
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "simctl install on \(udid) exited \(result.exitCode): \(result.stderr)")
        }
    }

    private static func prepareDevClientIfDebug() async throws {
        guard isRNDebugE2EEnabled else { return }
        let result = try await TestHelpers.runOffsiderCommandSeparated("rn prepare --bundle-id \(bundleID)", simulatorUDID: try udid())
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "offsider rn prepare exited \(result.exitCode): \(result.stderr)")
        }
    }

    /// Restarts the playground on a screen, without waiting for the screen to render; the Debug app loads from Metro by `--initialUrl`.
    static func launch(_ route: String) async throws {
        try await ensureInstalled()
        let udid = try udid()
        let metro = isRNDebugE2EEnabled ? "--initialUrl \(RNMetro.url) " : ""
        let result = try await CommandRunner.runSeparated(
            "xcrun simctl launch --terminate-running-process \(udid) \(bundleID) \(metro)-OffsiderScreen \(AndroidE2E.quote(route))",
            timeout: 60
        )
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "simctl launch \(route) on \(udid) exited \(result.exitCode): \(result.stderr)")
        }
    }
}

actor IOSRNInstallGate {
    static let shared = IOSRNInstallGate()
    private var installed = false

    func installOnce(_ body: () async throws -> Void) async throws {
        guard !installed else { return }
        try await body()
        installed = true
    }
}
