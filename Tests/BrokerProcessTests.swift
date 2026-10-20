import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Broker process lookup")
struct BrokerProcessTests {
    static let serving = ["hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]

    @Test("a process matches when its arguments end with the broker's, device id in any case; the executable's name is the pid filter's job")
    func matching() {
        let argv: (pid_t) -> [String]? = { pid in
            switch pid {
            case 1: ["/opt/homebrew/bin/offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]
            case 2: ["offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000001"]
            case 3: ["offsider", "hid-broker", "--udid", "00000000-0000-0000-0000-000000000002"]
            case 4: ["offsider", "hid-broker"]
            case 5: ["offsider", "android-session", "serve", "--device", "emulator-5554"]
            case 6: ["offsider", "session", "stop", "--device", "emulator-5554"]
            default: nil
            }
        }
        #expect(BrokerProcess.find(serving: Self.serving, pids: { [1, 2, 3, 4, 5, 6, 7] }, argv: argv) == [1, 2])
        #expect(BrokerProcess.find(serving: Self.serving.dropLast() + ["00000000-0000-0000-0000-000000000001".lowercased()], pids: { [1] }, argv: argv) == [1])
        #expect(BrokerProcess.find(serving: ["android-session", "serve", "--device", "emulator-5554"], pids: { [1, 5, 6] }, argv: argv) == [5])
        #expect(BrokerProcess.find(serving: [], pids: { [1] }, argv: argv).isEmpty)
    }

    @Test("only a process of another build is stopped; this build's and an unidentified one are left, and this process is never a candidate")
    func stopping() throws {
        let requirement = try PeerCodeIdentity.ownRequirement()
        var stopped: [pid_t] = []
        let outcome = BrokerProcess.stopOtherBuilds(
            serving: Self.serving,
            requirement: requirement,
            find: { _ in [11, 12, 13, getpid()] },
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

    @Test("a live process's arguments are read, matched and its code checked; another build's is stopped, and only an offsider executable passes the pid filter")
    func liveLookup() throws {
        // A stand-in for a broker of another build: this user's process with a broker's arguments and code that is not this binary.
        let udid = UUID().uuidString
        let serving = ["hid-broker", "--udid", udid]
        let standIn = Process()
        standIn.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        standIn.arguments = ["-I", "-c", "import time; time.sleep(60)", "hid-broker", "--udid", udid]
        standIn.standardInput = FileHandle.nullDevice
        standIn.standardOutput = FileHandle.nullDevice
        standIn.standardError = FileHandle.nullDevice
        try standIn.run()
        defer { if standIn.isRunning { standIn.terminate() } }
        let pid = standIn.processIdentifier
        var found: [pid_t] = []
        for _ in 0..<400 where !found.contains(pid) {
            found = BrokerProcess.find(serving: serving, pids: { [pid] })
            if !found.contains(pid) { usleep(25_000) }
        }
        #expect(found == [pid], "\(BrokerProcess.argv(of: pid) ?? [])")
        #expect(!BrokerProcess.offsiderPids().contains(pid))

        let requirement = try PeerCodeIdentity.ownRequirement()
        var stopped: [pid_t] = []
        let outcome = BrokerProcess.stopOtherBuilds(
            serving: serving, requirement: requirement, find: { BrokerProcess.find(serving: $0, pids: { [pid] }) }, stop: { stopped.append($0) }
        )
        let verdict = PeerCodeIdentity.check(pid: pid, requirement: requirement)
        #expect(stopped == [pid], "identified \(verdict.identified), accepted \(verdict.accepted): \(verdict.detail ?? "no detail")")
        #expect(outcome.ownBuild.isEmpty)
    }
}
