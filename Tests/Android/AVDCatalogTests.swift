import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("AVD catalogue")
struct AVDCatalogTests {
    private static let config = """
    avd.ini.displayname=Offsider E2E Pixel 9
    abi.type = arm64-v8a
    hw.device.name=pixel_9
    image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/
    # a comment
    """

    private static func addAVD(_ name: String, in avdHome: URL, pointer: String? = nil, config: String? = AVDCatalogTests.config) throws {
        let directory = avdHome.appendingPathComponent("\(name).avd")
        try AndroidTestHost.write(pointer ?? "avd.ini.encoding=UTF-8\npath=\(directory.path)\ntarget=android-35\n", to: "\(name).ini", in: avdHome)
        if let config {
            try AndroidTestHost.write(config, to: "\(name).avd/config.ini", in: avdHome)
        }
    }

    @Test("the AVD home follows the SDK's variable precedence", arguments: [
        (["ANDROID_AVD_HOME": "/a", "ANDROID_USER_HOME": "/u", "ANDROID_EMULATOR_HOME": "/e"], "/a"),
        (["ANDROID_USER_HOME": "/u", "ANDROID_EMULATOR_HOME": "/e"], "/u/avd"),
        (["ANDROID_EMULATOR_HOME": "/e"], "/e/avd"),
        ([:], "/home/.android/avd"),
    ] as [([String: String], String)])
    func homePrecedence(environment: [String: String], expected: String) {
        let host = AndroidTestHost.make(home: URL(fileURLWithPath: "/home", isDirectory: true), environment: environment)
        #expect(AVDCatalog.home(host: host).path == expected)
    }

    @Test("an AVD's details come from its config.ini, with the API level from the system image")
    func readsConfig() throws {
        let home = try AndroidTestHost.temporaryHome()
        let avdHome = home.appendingPathComponent(".android/avd")
        try Self.addAVD("Offsider_E2E_Pixel_9", in: avdHome)

        let info = try #require(AVDCatalog(host: AndroidTestHost.make(home: home)).info(named: "Offsider_E2E_Pixel_9"))
        #expect(info.displayName == "Offsider E2E Pixel 9")
        #expect(info.apiLevel == 36)
        #expect(info.abi == "arm64-v8a")
        #expect(info.deviceProfile == "pixel_9")
    }

    @Test("path.rel is used when path is missing, and target gives the API level without a system image")
    func relativePathAndTarget() throws {
        let home = try AndroidTestHost.temporaryHome()
        let avdHome = home.appendingPathComponent(".android/avd")
        try Self.addAVD("Pixel_9a", in: avdHome, pointer: "path.rel=avd/Pixel_9a.avd\ntarget=android-35\n", config: "hw.device.name=pixel_9a\n")

        let info = try #require(AVDCatalog(host: AndroidTestHost.make(home: home)).info(named: "Pixel_9a"))
        #expect(info.apiLevel == 35)
        #expect(info.deviceProfile == "pixel_9a")
    }

    @Test("all() is sorted by name, skips broken AVDs, and lookups are case-sensitive")
    func listsAndSkipsBroken() throws {
        let home = try AndroidTestHost.temporaryHome()
        let avdHome = home.appendingPathComponent(".android/avd")
        try Self.addAVD("Pixel_9a", in: avdHome)
        try Self.addAVD("Offsider_E2E_Pixel_9", in: avdHome)
        try Self.addAVD("Broken", in: avdHome, config: nil)
        try AndroidTestHost.write("not an avd", to: "notes.txt", in: avdHome)
        let catalog = AVDCatalog(host: AndroidTestHost.make(home: home))

        #expect(catalog.all().map(\.name) == ["Offsider_E2E_Pixel_9", "Pixel_9a"])
        #expect(catalog.info(named: "pixel_9a") == nil)
    }

    @Test("ini parsing trims, skips comments and keeps the last duplicate")
    func iniParsing() {
        let values = IniFile.parse("  a = 1 \n#b=2\n;c=3\n\na=4\nnovalue\n=x\npath=/x?y=z\n")
        #expect(values == ["a": "4", "path": "/x?y=z"])
    }
}
