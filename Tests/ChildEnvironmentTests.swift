import Foundation
import OffsiderCore
import Testing

@Suite("Child environments")
struct ChildEnvironmentTests {
    static let caller: [String: String] = [
        "HOME": "/Users/me", "PATH": "/usr/bin", "TMPDIR": "/tmp/x", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "LANG": "en_AU.UTF-8",
        "LC_ALL": "en_AU.UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0xF",
        "AWS_SECRET_ACCESS_KEY": "secret", "GITHUB_TOKEN": "ghp", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "SSH_AUTH_SOCK": "/tmp/agent",
        "ANDROID_HOME": "/sdk", "ANDROID_SDK_ROOT": "/sdk", "ANDROID_AVD_HOME": "/avd", "ANDROID_ADB_SERVER_PORT": "5037",
        "ADB_MDNS": "1", "ADB_TRACE": "all", "ADB_SERVER_SOCKET": "tcp:5037", "ADB_LIBUSB": "1", "ADB_VENDOR_KEYS": "/keys",
        "ANDROID_EMU_ENABLE_CRASH_REPORTING": "1", "ANDROID_EMU_CRASH_REPORTING_DATABASE": "/tmp/db",
        "DEVELOPER_DIR": "/Xcode.app/Contents/Developer", "OFFSIDER_IOS_SESSION_IDLE": "60",
        "TEST_RUNNER_OFFSIDER_RUNNER_PORT": "1", "HTTPS_PROXY": "http://proxy:3128", "NO_PROXY": "localhost",
    ]

    static let base: Set<String> = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"]

    @Test("the base profile keeps only the login basics and locale")
    func baseProfile() {
        #expect(Set(ChildEnvironment.make(.base, from: Self.caller).keys) == Self.base)
    }

    @Test("the emulator gets its SDK and AVD locations with mDNS and crash reporting forced off, and no secrets")
    func emulatorProfile() {
        let environment = ChildEnvironment.make(.androidEmulator, from: Self.caller)
        #expect(Set(environment.keys) == Self.base.union(["ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_ADB_SERVER_PORT", "ADB_MDNS", "ANDROID_EMU_ENABLE_CRASH_REPORTING"]))
        #expect(environment["ADB_MDNS"] == "0")
        #expect(environment["ANDROID_EMU_ENABLE_CRASH_REPORTING"] == "0")
    }

    @Test("adb start-server keeps its socket, USB and key settings, drops ADB_TRACE and forces mDNS off")
    func adbProfile() {
        let environment = ChildEnvironment.make(.adbServer, from: Self.caller)
        #expect(Set(environment.keys) == Self.base.union(["ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_ADB_SERVER_PORT", "ADB_SERVER_SOCKET", "ADB_LIBUSB", "ADB_VENDOR_KEYS", "ADB_MDNS"]))
        #expect(environment["ADB_MDNS"] == "0")
    }

    @Test("a broker keeps Xcode's location and Offsider's settings; xcodebuild adds the runner's settings and the proxy")
    func xcodeProfiles() {
        #expect(Set(ChildEnvironment.make(.offsiderBroker, from: Self.caller).keys) == Self.base.union(["DEVELOPER_DIR", "OFFSIDER_IOS_SESSION_IDLE"]))
        #expect(Set(ChildEnvironment.make(.xcodebuild, from: Self.caller).keys) == Self.base.union(["DEVELOPER_DIR", "TEST_RUNNER_OFFSIDER_RUNNER_PORT", "HTTPS_PROXY", "NO_PROXY"]))
    }

    @Test("an Android broker finds the SDK and the adb server, keeps Offsider's settings, forces mDNS off and gets no secrets")
    func androidBrokerProfile() {
        let environment = ChildEnvironment.make(.androidBroker, from: Self.caller)
        #expect(Set(environment.keys) == Self.base.union([
            "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_ADB_SERVER_PORT", "ADB_SERVER_SOCKET", "ADB_LIBUSB", "ADB_VENDOR_KEYS",
            "ADB_MDNS", "OFFSIDER_IOS_SESSION_IDLE",
        ]))
        #expect(environment["ADB_MDNS"] == "0")
    }
}
