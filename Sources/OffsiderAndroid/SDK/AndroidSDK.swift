import Foundation
import OffsiderCore

/// The Android SDK Offsider runs `adb` and the emulator from; never Google's Android CLI.
struct AndroidSDK: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case androidHome
        case androidSDKRoot
        case defaultLocation
        case adbOnPath
    }

    static let notFoundMessage = "Android SDK not found. Set ANDROID_HOME to your SDK (Android Studio installs it in ~/Library/Android/sdk), or put adb on PATH."

    let root: URL
    let source: Source
    /// Usually `<root>/platform-tools/adb`; the resolved `PATH` entry when adb came from there.
    let adb: URL

    var emulator: URL { root.appendingPathComponent("emulator/emulator") }

    /// ANDROID_HOME, then ANDROID_SDK_ROOT, then ~/Library/Android/sdk, then `adb` on PATH with symlinks resolved.
    /// A set variable without platform-tools/adb is an error naming it, never skipped.
    static func locate(host: AndroidHost) throws -> AndroidSDK {
        for (variable, source) in [("ANDROID_HOME", Source.androidHome), ("ANDROID_SDK_ROOT", .androidSDKRoot)] {
            guard let path = host.variable(variable) else { continue }
            let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            let adb = root.appendingPathComponent("platform-tools/adb")
            guard host.files.isExecutableFile(atPath: adb.path) else {
                throw AndroidError.sdkVariableWithoutAdb(variable: variable, path: path)
            }
            return AndroidSDK(root: root, source: source, adb: adb)
        }

        let defaultRoot = host.homeDirectory.appendingPathComponent("Library/Android/sdk", isDirectory: true)
        let defaultAdb = defaultRoot.appendingPathComponent("platform-tools/adb")
        if host.files.isExecutableFile(atPath: defaultAdb.path) {
            return AndroidSDK(root: defaultRoot, source: .defaultLocation, adb: defaultAdb)
        }

        for directory in (host.variable("PATH") ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("adb")
            guard host.files.isExecutableFile(atPath: candidate.path) else { continue }
            let adb = URL(fileURLWithPath: host.files.resolvingSymlinks(inPath: candidate.path))
            let root = adb.deletingLastPathComponent().deletingLastPathComponent()
            return AndroidSDK(root: root, source: .adbOnPath, adb: adb)
        }

        throw PlatformUnavailable(platform: .android, message: notFoundMessage)
    }
}
