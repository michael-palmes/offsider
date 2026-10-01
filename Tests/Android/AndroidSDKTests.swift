import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android SDK discovery")
struct AndroidSDKTests {
    private static func sdk(at relativePath: String, in root: URL) throws -> URL {
        try AndroidTestHost.makeExecutable("\(relativePath)/platform-tools/adb", in: root)
        return root.appendingPathComponent(relativePath, isDirectory: true)
    }

    @Test("ANDROID_HOME wins over ANDROID_SDK_ROOT, the default folder and PATH")
    func androidHomeWins() throws {
        let home = try AndroidTestHost.temporaryHome()
        let first = try Self.sdk(at: "first", in: home)
        let second = try Self.sdk(at: "second", in: home)
        _ = try Self.sdk(at: "Library/Android/sdk", in: home)
        let host = AndroidTestHost.make(home: home, environment: ["ANDROID_HOME": first.path, "ANDROID_SDK_ROOT": second.path])

        let sdk = try AndroidSDK.locate(host: host)
        #expect(sdk.source == .androidHome)
        #expect(sdk.adb.path == first.appendingPathComponent("platform-tools/adb").path)
        #expect(sdk.emulator.path == first.appendingPathComponent("emulator/emulator").path)
    }

    @Test("ANDROID_SDK_ROOT is used when ANDROID_HOME is unset or empty")
    func sdkRootNext() throws {
        let home = try AndroidTestHost.temporaryHome()
        let second = try Self.sdk(at: "second", in: home)
        let host = AndroidTestHost.make(home: home, environment: ["ANDROID_HOME": "", "ANDROID_SDK_ROOT": second.path])
        #expect(try AndroidSDK.locate(host: host).source == .androidSDKRoot)
    }

    @Test("the Android Studio folder under the home folder comes before PATH")
    func defaultLocation() throws {
        let home = try AndroidTestHost.temporaryHome()
        _ = try Self.sdk(at: "Library/Android/sdk", in: home)
        _ = try Self.sdk(at: "elsewhere", in: home)
        let host = AndroidTestHost.make(home: home, environment: ["PATH": home.appendingPathComponent("elsewhere/platform-tools").path])
        #expect(try AndroidSDK.locate(host: host).source == .defaultLocation)
    }

    @Test("a set variable without platform-tools/adb is an error naming it, never skipped")
    func variableWithoutAdb() throws {
        let home = try AndroidTestHost.temporaryHome()
        _ = try Self.sdk(at: "Library/Android/sdk", in: home)
        let empty = home.appendingPathComponent("empty").path
        let host = AndroidTestHost.make(home: home, environment: ["ANDROID_HOME": empty])

        let error = #expect(throws: AndroidError.self) { try AndroidSDK.locate(host: host) }
        #expect(error?.message == "ANDROID_HOME is \(empty), which has no platform-tools/adb. Install Android SDK Platform-Tools there, or unset ANDROID_HOME.")
    }

    @Test("a symlinked adb on PATH resolves to the SDK it belongs to")
    func symlinkOnPath() throws {
        let home = try AndroidTestHost.temporaryHome()
        let sdkRoot = try Self.sdk(at: "Caskroom/platform-tools-35", in: home)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("adb").path,
            withDestinationPath: sdkRoot.appendingPathComponent("platform-tools/adb").path
        )
        let host = AndroidTestHost.make(home: home, environment: ["PATH": "/nonexistent:\(bin.path)"])

        let sdk = try AndroidSDK.locate(host: host)
        #expect(sdk.source == .adbOnPath)
        #expect(sdk.root.resolvingSymlinksInPath().path == sdkRoot.resolvingSymlinksInPath().path)
    }

    @Test("no SDK anywhere is PlatformUnavailable with the install hint")
    func nothingFound() throws {
        let home = try AndroidTestHost.temporaryHome()
        let host = AndroidTestHost.make(home: home, environment: ["PATH": "/usr/bin:/bin"])

        let error = #expect(throws: PlatformUnavailable.self) { try AndroidSDK.locate(host: host) }
        #expect(error?.platform == .android)
        #expect(error?.message == "Android SDK not found. Set ANDROID_HOME to your SDK (Android Studio installs it in ~/Library/Android/sdk), or put adb on PATH.")
    }
}
