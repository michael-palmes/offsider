import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android host")
struct AndroidHostTests {
    @Test("the live host takes its home folder from HOME, so tests can hide the real SDK")
    func liveHostHonoursHome() {
        let host = AndroidHost.live(environment: ["HOME": "/nonexistent/offsider-home"])
        #expect(host.homeDirectory.path == "/nonexistent/offsider-home")
    }

    @Test("an empty variable counts as unset")
    func emptyVariableIsUnset() {
        let host = AndroidHost.live(environment: ["HOME": "/x", "ANDROID_HOME": "", "ANDROID_SDK_ROOT": "/sdk"])
        #expect(host.variable("ANDROID_HOME") == nil)
        #expect(host.variable("ANDROID_SDK_ROOT") == "/sdk")
    }

    @Test("this process is alive and pid 0 or a reaped child is not")
    func processLiveness() async throws {
        #expect(AndroidHost.processIsAlive(getpid()))
        #expect(!AndroidHost.processIsAlive(0))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!AndroidHost.processIsAlive(child.processIdentifier))
    }

    @Test("a running process has an executable path and a reaped child has none")
    func executablePath() throws {
        let own = try #require(AndroidHost.executablePath(of: getpid()))
        #expect(own.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: own))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(AndroidHost.executablePath(of: child.processIdentifier) == nil)
        #expect(AndroidHost.executablePath(of: 0) == nil)
    }

    @Test("qemu and emulator binaries count as emulators; other programs do not", arguments: [
        ("/Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64", true),
        ("/sdk/emulator/emulator", true),
        ("/Applications/Safari.app/Contents/MacOS/Safari", false),
        ("/usr/local/bin/python3", false),
    ])
    func emulatorExecutables(path: String, expected: Bool) {
        #expect(EmulatorDiscovery.isEmulatorExecutable(path) == expected)
    }
}
