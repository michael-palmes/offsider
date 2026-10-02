import CryptoKit
import Foundation

/// The React Native playground's Release app on the SIMULATOR_UDID simulator.
enum IOSRNPlayground {
    static let bundleID = "com.mpalmes.offsider.playground.rn"

    static func udid() throws -> String {
        guard let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !udid.isEmpty else {
            throw DescribeUIError(description: "SIMULATOR_UDID must name the booted simulator for the React Native iOS E2E suites.")
        }
        return udid
    }

    static func appPath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OFFSIDER_RN_IOS_APP"], !path.isEmpty else {
            throw DescribeUIError(description: "OFFSIDER_RN_IOS_APP must name the React Native playground's Release .app (build it with `scripts/rn-playground.sh build-ios`).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DescribeUIError(description: "OFFSIDER_RN_IOS_APP \(path) is not an .app bundle; build it with `scripts/rn-playground.sh build-ios`.")
        }
        return path
    }

    /// SHA-256 over the bundle's executable and `main.jsbundle`, so a rebuilt app or bundle is noticed.
    static func digest(ofApp path: String) throws -> String {
        let app = URL(fileURLWithPath: path)
        let plist = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String else {
            throw DescribeUIError(description: "\(path) has no CFBundleExecutable in its Info.plist")
        }
        var hasher = SHA256()
        for name in [executable, "main.jsbundle"] {
            hasher.update(data: try Data(contentsOf: app.appendingPathComponent(name), options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Installs the app once per test process, skipping the install when the simulator already has the same build.
    static func ensureInstalled() async throws {
        try await IOSRNInstallGate.shared.installOnce {
            let udid = try udid()
            let app = try appPath()
            let container = try await CommandRunner.runSeparated("xcrun simctl get_app_container \(udid) \(bundleID) app")
            let installed = container.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if container.exitCode == 0, !installed.isEmpty, (try? digest(ofApp: installed)) == (try digest(ofApp: app)) {
                return
            }
            let result = try await CommandRunner.runSeparated("xcrun simctl install \(udid) \(AndroidE2E.quote(app))", timeout: 300)
            guard result.exitCode == 0 else {
                throw DescribeUIError(description: "simctl install on \(udid) exited \(result.exitCode): \(result.stderr)")
            }
        }
    }

    /// Restarts the playground on a screen, without waiting for the screen to render.
    static func launch(_ route: String) async throws {
        try await ensureInstalled()
        let udid = try udid()
        let result = try await CommandRunner.runSeparated(
            "xcrun simctl launch --terminate-running-process \(udid) \(bundleID) -OffsiderScreen \(AndroidE2E.quote(route))",
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
