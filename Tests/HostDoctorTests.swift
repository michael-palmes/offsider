import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("host doctor rules")
struct HostDoctorRulesTests {
    static func facts(load: Double = 1, cpus: Int? = 10, disk: Double? = 100, sessions: [HostSession] = []) -> HostFacts {
        HostFacts(loadAverage: [load, 1, 1], cpuCount: cpus, memoryGB: 32, diskFreeGB: disk, diskPath: "/Users/me", sessions: sessions)
    }

    @Test("load warns only above four times the CPU count", arguments: [(40.0, CheckStatus.pass), (40.1, .warn), (3, .pass)])
    func load(load: Double, status: CheckStatus) {
        let verdict = HostDoctorRules.load(Self.facts(load: load))
        #expect(verdict.status == status)
        #expect((verdict.hint != nil) == (status == .warn))
    }

    @Test("an unreadable load skips")
    func unreadableLoad() {
        #expect(HostDoctorRules.load(HostFacts(loadAverage: [], cpuCount: 10, memoryGB: nil, diskFreeGB: nil, diskPath: "/", sessions: [])).status == .skip)
    }

    @Test("free disk warns under 10 GB and fails under 2 GB", arguments: [(10.0, CheckStatus.pass), (9.9, .warn), (2.0, .warn), (1.9, .fail)])
    func disk(free: Double, status: CheckStatus) {
        #expect(HostDoctorRules.disk(Self.facts(disk: free)).status == status)
    }

    @Test("other Offsider commands always pass and are named by subcommand and device")
    func sessions() {
        #expect(HostDoctorRules.sessions([]) == (.pass, "No other Offsider commands are running", nil))
        let verdict = HostDoctorRules.sessions([
            HostSession(pid: 12, command: "tap", device: "emulator-5554", startedAt: nil),
            HostSession(pid: 13, command: nil, device: nil, startedAt: nil),
        ])
        #expect(verdict == (.pass, "2 other Offsider commands: pid 12 tap on emulator-5554, pid 13 offsider", nil))
    }

    @Test("every report carries host facts and the three host checks after its own")
    func withHost() throws {
        let base = DoctorReport(offsiderVersion: "0.8.0", udid: nil, xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil), booted: [], checks: [])
        let report = Doctor.withHost(base, Self.facts())
        #expect(report.checks.map(\.id) == [.hostLoad, .hostDisk, .hostSessions])
        let object = try #require(try JSONSerialization.jsonObject(with: try report.jsonData()) as? [String: Any])
        let host = try #require(object["host"] as? [String: Any])
        #expect(Set(host.keys) == ["loadAverage", "cpuCount", "memoryGB", "diskFreeGB", "diskPath", "sessions"])
        #expect(DoctorRenderer.render(report).split(separator: "\n").dropFirst().first == "Host: load 1.0 on 10 CPUs, 32 GB RAM, 100 GB free on /Users/me, 0 other Offsider commands")
    }
}

@Suite("host probe")
struct HostProbeTests {
    /// `KERN_PROCARGS2` as the kernel lays it out: argc, the executable path, padding, argv, then the environment.
    static func procargs(_ arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count).littleEndian) { Array($0) }
        bytes += Array("/opt/homebrew/bin/offsider".utf8) + [0, 0, 0, 0]
        for string in arguments + environment {
            bytes += Array(string.utf8) + [0]
        }
        return bytes
    }

    static let commands: Set<String> = ["type", "tap", "rn", "runner", "doctor"]

    @Test("a typed secret never leaves the parser: only the subcommand and the device are kept")
    func typedTextStaysOut() throws {
        let buffer = Self.procargs(["offsider", "type", "hunter2", "--device", "X"], environment: ["HOME=/Users/me", "SECRET_TOKEN=abc"])
        let parsed = HostSessionParser.parse(buffer, isCommand: Self.commands.contains)
        #expect(parsed.command == "type")
        #expect(parsed.device == "X")

        let probe = HostProbe(
            loadAverage: { [1, 1, 1] }, cpuCount: { 10 }, memoryBytes: { 34_359_738_368 }, diskPath: { "/Users/me" }, diskFreeBytes: { _ in 107_374_182_400 },
            offsiderPids: { [4242] }, processArguments: { _ in buffer }, startTime: { _ in nil }, isCommand: Self.commands.contains
        )
        let report = Doctor.withHost(
            DoctorReport(offsiderVersion: "0.8.0", udid: nil, xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil), booted: [], checks: []),
            probe.facts()
        )
        let json = try #require(String(data: try report.jsonData(), encoding: .utf8))
        let text = DoctorRenderer.render(report)
        for secret in ["hunter2", "SECRET_TOKEN", "abc", "/Users/me/"] {
            #expect(!json.contains(secret), "\(secret) reached the JSON")
            #expect(!text.contains(secret), "\(secret) reached the text")
        }
        #expect(report.host?.sessions == [HostSession(pid: 4242, command: "type", device: "X", startedAt: nil)])
    }

    @Test("nested commands keep their subcommand; the device comes from --device=, else OFFSIDER_DEVICE; odd values are dropped", arguments: [
        (["offsider", "runner", "status"], [String](), "runner status", nil),
        (["offsider", "tap", "--device=emulator-5554", "-x", "1"], [], "tap", "emulator-5554"),
        (["offsider", "tap", "-x", "1"], ["OFFSIDER_DEVICE=Pixel_9"], "tap", "Pixel_9"),
        (["offsider", "hunter2", "--device", "a b"], [], nil, nil),
        (["offsider", "type", "--", "--device", "Y"], [], "type", nil),
    ] as [([String], [String], String?, String?)])
    func parsing(arguments: [String], environment: [String], command: String?, device: String?) {
        let parsed = HostSessionParser.parse(Self.procargs(arguments, environment: environment), isCommand: Self.commands.contains)
        #expect(parsed.command == command)
        #expect(parsed.device == device)
    }

    @Test("the live probe reads this process's own arguments buffer and the Mac's load")
    func live() {
        let buffer = HostProbe.procargs(getpid())
        #expect((buffer?.count ?? 0) > 4)
        #expect(HostProbe.live.facts().loadAverage.count == 3)
    }
}
