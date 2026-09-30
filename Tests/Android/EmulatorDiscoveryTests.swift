import Foundation
import Testing
@testable import OffsiderAndroid

/// Lists a file that has gone by the time it is read, as when an emulator exits mid-scan.
private struct VanishingFiles: FileSystemProbe {
    let listing: [String]

    func fileExists(atPath path: String) -> Bool { false }
    func isExecutableFile(atPath path: String) -> Bool { false }
    func contents(atPath path: String) -> Data? { nil }
    func contentsOfDirectory(atPath path: String) -> [String] { listing }
    func resolvingSymlinks(inPath path: String) -> String { path }
}

@Suite("Emulator discovery files")
struct EmulatorDiscoveryTests {
    static let contents = """
    emulator.build=14091262
    emulator.version=37.1.11
    avd.id=Offsider_E2E_Pixel_9
    avd.name=Offsider_E2E_Pixel_9
    port.serial=5556
    port.adb=5557
    grpc.port=8556
    grpc.token=s3cr3t-token-value
    grpc.jwks=/Users/x/Library/Caches/TemporaryItems/avd/running/68613/jwks/abc
    grpc.jwk_active=/Users/x/Library/Caches/TemporaryItems/avd/running/68613/jwks/abc/active.jwk
    grpc.allowlist=/Users/x/Library/Android/sdk/emulator/lib/emulator_access.json
    """

    @Test("pid_<pid>.ini parses into its fields")
    func parsesFile() throws {
        let discovery = try EmulatorDiscovery.parse(fileName: "pid_68613.ini", contents: Self.contents)
        #expect(discovery.pid == 68613)
        #expect(discovery.consolePort == 5556)
        #expect(discovery.grpcPort == 8556)
        #expect(discovery.avdID == "Offsider_E2E_Pixel_9")
        #expect(discovery.token == "s3cr3t-token-value")
        #expect(discovery.emulatorVersion == "37.1.11")
    }

    @Test("other file names are not discovery files", arguments: ["pid_x.ini", "pid_1_info.ini", "pid_.ini", "68613.ini", "pid_68613.ini.tmp"])
    func rejectsOtherNames(name: String) {
        #expect(throws: EmulatorDiscovery.NotADiscoveryFile.self) {
            try EmulatorDiscovery.parse(fileName: name, contents: Self.contents)
        }
    }

    @Test("the description never contains the token")
    func descriptionRedactsToken() throws {
        let discovery = try EmulatorDiscovery.parse(fileName: "pid_68613.ini", contents: Self.contents)
        #expect(!discovery.description.contains("s3cr3t"))
        #expect(discovery.description.contains("grpc.token=<redacted>"))
    }

    @Test("only files whose pid is alive count; stale files from a dead emulator are ignored")
    func deadPidsIgnored() throws {
        let home = try AndroidTestHost.temporaryHome()
        let running = "Library/Caches/TemporaryItems/avd/running"
        try AndroidTestHost.write(Self.contents, to: "\(running)/pid_68613.ini", in: home)
        try AndroidTestHost.write(Self.contents.replacingOccurrences(of: "5556", with: "5558"), to: "\(running)/pid_700.ini", in: home)
        try AndroidTestHost.write("junk", to: "\(running)/notes.txt", in: home)

        let live = EmulatorDiscovery.live(host: AndroidTestHost.make(home: home, liveProcesses: [700]))
        #expect(live.map(\.pid) == [700])
        #expect(live.first?.consolePort == 5558)
    }

    @Test("a file deleted between listing and reading is skipped")
    func vanishedFileSkipped() {
        let host = AndroidTestHost.make(files: VanishingFiles(listing: ["pid_700.ini"]), liveProcesses: [700])
        #expect(EmulatorDiscovery.live(host: host).isEmpty)
    }

    @Test("the running folder sits under the home folder's caches")
    func directory() {
        let host = AndroidTestHost.make(home: URL(fileURLWithPath: "/Users/x", isDirectory: true))
        #expect(EmulatorDiscovery.directory(host: host).path == "/Users/x/Library/Caches/TemporaryItems/avd/running")
    }
}
