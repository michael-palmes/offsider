import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Broker process lookup")
struct BrokerProcessTests {
    static let serving = ["hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]

    @Test("a process matches when its arguments hold the broker's in a row, device id in any case, and a bound socket narrows it")
    func matching() {
        let argv: (pid_t) -> [String]? = { pid in
            switch pid {
            case 1: ["/opt/homebrew/bin/offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]
            case 2: ["offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000001", "--later-flag"]
            case 3: ["offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000002"]
            case 4: ["offsider", "hid-broker"]
            case 5: ["offsider", "android-session", "serve", "--device", "emulator-5554"]
            case 6: ["offsider", "session", "stop", "--device", "emulator-5554"]
            default: nil
            }
        }
        #expect(BrokerProcess.find(serving: Self.serving, pids: { [1, 2, 3, 4, 5, 6, 7] }, argv: argv) == [1, 2])
        #expect(BrokerProcess.find(serving: ["hid-broker"], pids: { [1, 2, 3, 4, 5] }, argv: argv) == [1, 2, 3, 4])
        #expect(BrokerProcess.find(serving: Self.serving.dropLast() + ["00000000-0000-0000-0000-000000000001".lowercased()], pids: { [1] }, argv: argv) == [1])
        #expect(BrokerProcess.find(serving: ["android-session", "serve", "--device", "emulator-5554"], pids: { [1, 5, 6] }, argv: argv) == [5])
        #expect(BrokerProcess.find(serving: [], pids: { [1] }, argv: argv).isEmpty)
        let holds: (pid_t, String) -> Bool = { pid, path in pid == 2 && path == "/tmp/a.sock" }
        #expect(BrokerProcess.find(serving: ["hid-broker"], boundTo: "/tmp/a.sock", pids: { [1, 2, 3] }, argv: argv, holds: holds) == [2])
        #expect(BrokerProcess.find(serving: ["hid-broker"], boundTo: "/tmp/b.sock", pids: { [1, 2, 3] }, argv: argv, holds: holds).isEmpty)
    }

    @Test("only a process of another build is stopped; this build's and an unidentified one are left, and this process is never a candidate")
    func stopping() throws {
        let requirement = try PeerCodeIdentity.ownRequirement()
        var stopped: [pid_t] = []
        let outcome = BrokerProcess.stopOtherBuilds(
            serving: Self.serving,
            requirement: requirement,
            find: { _, _ in [11, 12, 13, getpid()] },
            verdict: { pid, _ in
                switch pid {
                case 11: PeerCodeIdentity.Verdict(pid: pid, cdhash: nil, accepted: false, identified: true, detail: "another build")
                case 12: PeerCodeIdentity.Verdict(pid: pid, cdhash: nil, accepted: true, identified: true, detail: nil)
                default: PeerCodeIdentity.Verdict(pid: pid, cdhash: nil, accepted: false, identified: false, detail: "gone")
                }
            },
            stop: { stopped.append($0) }
        )
        #expect(stopped == [11])
        #expect(outcome.stopped == [11])
        #expect(outcome.ownBuild == [12])
    }

    @Test("a live process's arguments and the socket it holds are read, matched and its code checked; another build's is stopped, and only an offsider executable passes the pid filter")
    func liveLookup() throws {
        // A stand-in for a broker of another build: this user's process holding a bound socket, with a broker's arguments and code that is not this binary.
        let udid = UUID().uuidString
        let serving = ["hid-broker", "--udid", udid]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("obp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("b.sock").path
        let standIn = Process()
        standIn.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        standIn.arguments = [
            "-I", "-c", "import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(60)",
            socket, "hid-broker", "--udid", udid,
        ]
        standIn.standardInput = FileHandle.nullDevice
        standIn.standardOutput = FileHandle.nullDevice
        standIn.standardError = FileHandle.nullDevice
        try standIn.run()
        defer { if standIn.isRunning { standIn.terminate() } }
        let pid = standIn.processIdentifier
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: socket) { usleep(25_000) }
        var found: [pid_t] = []
        for _ in 0..<400 where !found.contains(pid) {
            found = BrokerProcess.find(serving: serving, boundTo: socket, pids: { [pid] })
            if !found.contains(pid) { usleep(25_000) }
        }
        #expect(found == [pid], "\(BrokerProcess.argv(of: pid) ?? [])")
        #expect(BrokerProcess.find(serving: serving, boundTo: socket + ".other", pids: { [pid] }).isEmpty)
        #expect(!BrokerProcess.offsiderPids().contains(pid))

        let requirement = try PeerCodeIdentity.ownRequirement()
        var stopped: [pid_t] = []
        let outcome = BrokerProcess.stopOtherBuilds(
            serving: serving, boundTo: socket, requirement: requirement,
            find: { BrokerProcess.find(serving: $0, boundTo: $1, pids: { [pid] }) }, stop: { stopped.append($0) }
        )
        let verdict = PeerCodeIdentity.check(pid: pid, requirement: requirement)
        #expect(stopped == [pid], "identified \(verdict.identified), accepted \(verdict.accepted): \(verdict.detail ?? "no detail")")
        #expect(outcome.ownBuild.isEmpty)
    }
}
