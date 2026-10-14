import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("adb and SDK advice")
struct AdbAdviceTests {
    static let adb = "/sdk/platform-tools/adb"

    static var adbErrors: [AndroidError] {
        [
            .adbServerNotRunning(endpoint: "127.0.0.1:5037"),
            .adbServerStartFailed(adb: adb, status: 1, detail: "cannot bind"),
            .adbServerNoAnswer(endpoint: "127.0.0.1:5037", seconds: 5),
            .adbServerNoAnswer(endpoint: "127.0.0.1:5037", seconds: 5, adb: adb),
            .adbProtocol("bad length"),
            .adbProtocol("bad length", adb: adb),
        ]
    }

    @Test("no adb advice starts a server without ADB_MDNS=0")
    func neverStartsWithMDNS() {
        for error in Self.adbErrors {
            if let hint = error.hint, hint.contains("start-server") { #expect(hint.hasPrefix("ADB_MDNS=0 "), "\(hint)") }
            #expect(!error.message.contains("`adb start-server`"))
        }
    }

    @Test("a server that is not running is left to Offsider; a stuck one names the SDK's adb to stop it")
    func restartAdvice() {
        #expect(AndroidError.adbServerNotRunning(endpoint: "127.0.0.1:5037").message.hasSuffix("Run the command again and Offsider starts one."))
        let stuck = AndroidError.adbServerNoAnswer(endpoint: "127.0.0.1:5037", seconds: 5, adb: Self.adb)
        #expect(stuck.hint == "\(Self.adb) kill-server")
        #expect(AndroidError.adbServerStartFailed(adb: Self.adb, status: 1, detail: "").hint == "ADB_MDNS=0 \(Self.adb) start-server")
    }

    @Test("a mistyped AVD suggests the closest one; a name far from every AVD lists them")
    func closestAVD() {
        let close = AndroidError.noAVDNamed("Pixel_9", available: ["Pixel_9a", "Tablet"])
        #expect(close.message == "No AVD named Pixel_9; the closest is Pixel_9a.")
        #expect(close.hint == "offsider boot Pixel_9a")
        let far = AndroidError.noAVDNamed("Wear_OS", available: ["Pixel_9a", "Tablet"])
        #expect(far.message == "No AVD named Wear_OS. AVDs on this Mac: Pixel_9a, Tablet. Create one in Android Studio's Device Manager.")
    }

    @Test("a missing emulator names the SDK's sdkmanager; a missing playground names its install script")
    func installAdvice() {
        #expect(AndroidError.emulatorMissing(sdkRoot: "/sdk").hint == "/sdk/cmdline-tools/latest/bin/sdkmanager emulator")
        let playground = AndroidError.appNotInstalled(AndroidError.playgroundPackage, serial: "emulator-5554")
        #expect(playground.hint == "scripts/rn-playground.sh install-android emulator-5554")
        #expect(AndroidError.appNotInstalled("com.example", serial: "emulator-5554").hint == "adb -s emulator-5554 install <path-to-apk>")
    }
}
