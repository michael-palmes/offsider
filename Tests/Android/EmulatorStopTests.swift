import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Emulator stop")
@MainActor
struct EmulatorStopTests {
    nonisolated static let avd = "Offsider_E2E"
    nonisolated static let other = "Other_AVD"
    nonisolated static let pid: Int32 = 4242
    nonisolated static let serial = "emulator-5556"

    /// Liveness the test can end, as the emulator ends on `emu kill`.
    final class Emulator: @unchecked Sendable {
        private let lock = NSLock()
        private var live: Bool
        private var startedAt = Date(timeIntervalSince1970: 1000)
        init(live: Bool = true) { self.live = live }
        var alive: Bool { lock.withLock { live } }
        var started: Date { lock.withLock { startedAt } }
        func end() { lock.withLock { live = false } }
        func reuse() { lock.withLock { startedAt = startedAt.addingTimeInterval(60) } }
    }

    static func home() throws -> URL {
        let home = try AndroidTestHost.homeWithSDK()
        let avdHome = home.appendingPathComponent(".android/avd")
        for name in [avd, other] {
            try AndroidTestHost.write("path=\(avdHome.appendingPathComponent("\(name).avd").path)\n", to: "\(name).ini", in: avdHome)
            try AndroidTestHost.write("hw.device.name=pixel_9\n", to: "\(name).avd/config.ini", in: avdHome)
        }
        return home
    }

    nonisolated static func writeDiscovery(pid: Int32 = pid, avd: String = avd, port: Int = 5556, in home: URL) throws {
        try AndroidTestHost.write("avd.id=\(avd)\nport.serial=\(port)\n", to: "Library/Caches/TemporaryItems/avd/running/pid_\(pid).ini", in: home)
    }

    /// `rows` is the server's device list; nil is no server running. `reported` is the AVD the device names.
    static func adb(rows: String?, reported: String = avd) -> FakeAdbServer {
        guard let rows else {
            return FakeAdbServer(connect: .refuse) { _ in .hang }
        }
        return FakeAdbServer(handler: FakeAdbServer.devices(
            [serial],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: rows)
                default: return .hang
                }
            },
            device: { _, _ in FakeAdbServer.shell(stdout: "\(reported)\n\n") }
        ))
    }

    nonisolated static let row = "\(serial) device product:sdk_gphone model:sdk_gphone transport_id:7\n"

    /// A kill that ends the emulator, unless `respond` scripts another answer.
    static func host(
        home: URL, adb: FakeAdbServer, emulator: Emulator = Emulator(), respond: (@Sendable (RecordingProcessRunner.Call) -> ProcessCaptureResult)? = nil
    ) -> (AndroidHost, RecordingProcessRunner) {
        let processes = RecordingProcessRunner { call in
            if let respond { return respond(call) }
            if call.arguments.contains("kill") { emulator.end() }
            return ProcessCaptureResult(status: 0, stdout: "OK: killing emulator, bye bye\nOK\n", stderr: "")
        }
        var host = AndroidTestHost.make(home: home, adb: adb, processes: processes, liveProcesses: [pid])
        host.isProcessAlive = { $0 == pid && emulator.alive }
        host.processStartTime = { $0 == pid ? emulator.started : nil }
        return (host, processes)
    }

    static func kills(_ processes: RecordingProcessRunner) -> [[String]] {
        processes.calls.map(\.arguments).filter { $0.contains("emu") }
    }

    static func stopper(_ host: AndroidHost) -> EmulatorStopper {
        EmulatorStopper(host: host, log: { _, _ in })
    }

    /// Finds, and stops what was found.
    static func running(_ lookup: EmulatorStopLookup) throws -> EmulatorStopTarget {
        guard case .running(let target) = lookup else { throw AndroidError(.notSupported, "expected a running emulator, got \(lookup)") }
        return target
    }

    @Test("a name stops only the emulator its discovery file names, through the serial's console, and waits for it to go")
    func stopsByName() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        try Self.writeDiscovery(pid: 77, avd: Self.other, port: 5554, in: home)
        let emulator = Emulator()
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row), emulator: emulator)
        let stopper = Self.stopper(host)

        let target = try Self.running(try await stopper.find(Self.avd))
        #expect(target.avd == Self.avd)
        #expect(target.serial == Self.serial)
        #expect(try await stopper.stop(target, timeout: .seconds(30)))

        #expect(Self.kills(processes) == [["-s", Self.serial, "emu", "kill"]])
        #expect(processes.calls.first { $0.arguments.contains("emu") }?.environment?["ADB_MDNS"] == "0")
        #expect(!emulator.alive)
    }

    @Test("a serial is read back as the AVD it serves now, whichever one that is")
    func serialResolvesToItsAVD() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(avd: Self.other, in: home)
        let (host, _) = Self.host(home: home, adb: Self.adb(rows: Self.row, reported: Self.other))

        let target = try Self.running(try await Self.stopper(host).find(Self.serial))

        #expect(target.avd == Self.other)
    }

    @Test("a mistyped name stops nothing and never starts adb")
    func mistypedName() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: nil))

        #expect(try await Self.stopper(host).find("Offsider_E2") == .unknown)
        #expect(processes.calls.isEmpty)
    }

    @Test("an AVD that is not running, and a serial nothing answers on, are off")
    func off() async throws {
        let (host, processes) = Self.host(home: try Self.home(), adb: Self.adb(rows: ""))

        #expect(try await Self.stopper(host).find(Self.avd) == .off(name: Self.avd))
        #expect(try await Self.stopper(host).find("emulator-5998") == .off(name: "emulator-5998"))
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a name that is a USB phone's serial is refused from the device list, with nothing sent to the phone")
    func phoneName() async throws {
        let server = Self.adb(rows: "R5CRFAKE01X device usb:1-1 product:p model:m transport_id:3\n")
        let (host, processes) = Self.host(home: try Self.home(), adb: server)

        await #expect { try await Self.stopper(host).find("R5CRFAKE01X") } throws: {
            ($0 as? AndroidError)?.kind == .shutdownPhone && ($0 as? AndroidError)?.reason == .deviceNotAllowed
        }
        #expect(Self.kills(processes).isEmpty)
        #expect(!server.requests.contains { $0.serial == "R5CRFAKE01X" })
    }

    @Test("a phone reporting an emulator's serial is refused, even with a live discovery file on that port")
    func phoneInDisguise() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: "\(Self.serial) device usb:1-1 product:p model:m transport_id:3\n"))

        await #expect { try await Self.stopper(host).find(Self.serial) } throws: { ($0 as? AndroidError)?.kind == .shutdownPhone }
        await #expect { try await Self.stopper(host).find(Self.avd) } throws: { ($0 as? AndroidError)?.kind == .shutdownPhone }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a name both a phone and a running AVD have is refused, naming the serial")
    func nameOnPhoneAndAVD() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: "\(Self.avd) device usb:1-1 product:p model:m transport_id:3\n\(Self.row)"))

        await #expect { try await Self.stopper(host).find(Self.avd) } throws: { "\($0)".contains(Self.serial) }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("an AVD running twice is refused, naming both serials")
    func runningTwice() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        try Self.writeDiscovery(pid: 77, port: 5558, in: home)
        var (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row))
        host.isProcessAlive = { [Self.pid, 77].contains($0) }
        host.processPath = { _ in AndroidTestHost.emulatorExecutable }

        await #expect { try await Self.stopper(host).find(Self.avd) } throws: {
            ($0 as? AndroidError)?.kind == .avdRunningTwice && "\($0)".contains("emulator-5556") && "\($0)".contains("emulator-5558")
        }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("an emulator with no discovery file gets no token: adb would send it to whatever holds that port")
    func noDiscoveryFile() async throws {
        let (host, processes) = Self.host(home: try Self.home(), adb: Self.adb(rows: Self.row))

        await #expect { try await Self.stopper(host).find(Self.serial) } throws: { ($0 as? AndroidError)?.kind == .emulatorUnconfirmed }
        await #expect { try await Self.stopper(host).find(Self.avd) } throws: { ($0 as? AndroidError)?.kind == .emulatorUnconfirmed }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a discovery file left by a program that is no emulator counts for nothing")
    func foreignPid() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        var (host, processes) = Self.host(home: home, adb: Self.adb(rows: ""))
        host.processPath = { _ in "/usr/local/bin/some-listener" }

        #expect(try await Self.stopper(host).find(Self.serial) == .off(name: Self.serial))
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a serial whose device names another AVD than its discovery file is refused, as the serial cannot be trusted")
    func namesDiffer() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row, reported: Self.other))

        await #expect { try await Self.stopper(host).find(Self.serial) } throws: {
            ($0 as? AndroidError)?.kind == .emulatorUnconfirmed && "\($0)".contains(Self.other) && "\($0)".contains(Self.avd)
        }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a serial that changed hands after it was found is not sent the kill")
    func serialChangedHands() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row))
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running/pid_\(Self.pid).ini"))
        try Self.writeDiscovery(avd: Self.other, in: home)

        await #expect { try await stopper.stop(target, timeout: .seconds(30)) } throws: { ($0 as? AndroidError)?.kind == .emulatorUnconfirmed }
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("an emulator that went while its session stopped needs no kill")
    func alreadyGone() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let emulator = Emulator()
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row), emulator: emulator)
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        emulator.end()

        #expect(try await stopper.stop(target, timeout: .seconds(30)) == false)
        #expect(Self.kills(processes).isEmpty)
    }

    @Test("a console that refuses names its KO line and the token file, and repeats nothing else it printed")
    func refused() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, _) = Self.host(home: home, adb: Self.adb(rows: Self.row), respond: { _ in
            ProcessCaptureResult(status: 0, stdout: "Android Console: banner text\nKO: unknown command\n", stderr: "")
        })
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        await #expect { try await stopper.stop(target, timeout: .seconds(30)) } throws: {
            let message = "\($0)"
            return ($0 as? AndroidError)?.reason == .shutdownFailed && message.contains("KO: unknown command")
                && message.contains(".emulator_console_auth_token") && !message.contains("banner text")
        }
    }

    @Test("an emulator that outlasts the limit is an error naming the fix, never a success")
    func timesOut() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let (host, processes) = Self.host(home: home, adb: Self.adb(rows: Self.row), respond: { _ in
            ProcessCaptureResult(status: 0, stdout: "OK: killing emulator, bye bye\n", stderr: "")
        })
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        await #expect { try await stopper.stop(target, timeout: .seconds(5)) } throws: {
            ($0 as? AndroidError)?.reason == .shutdownTimedOut && "\($0)".contains("kill \(Self.pid)") && "\($0)".contains("--timeout")
        }
        #expect(Self.kills(processes).count == 1)
    }

    @Test("a frozen emulator, whose console never answers the kill, is ended by its own process: TERM, and KILL only when TERM is not enough", arguments: [
        ([SIGTERM], [SIGTERM]), ([SIGKILL], [SIGTERM, SIGKILL]),
    ])
    func frozenConsole(endsOn: [Int32], sent: [Int32]) async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let emulator = Emulator()
        let processes = RecordingProcessRunner(failure: { call in
            call.arguments.contains("kill") ? ProcessCaptureTimeoutError(command: "adb emu kill", timeout: EmulatorStopper.killTimeout) : nil
        })
        var host = AndroidTestHost.make(home: home, adb: Self.adb(rows: Self.row), processes: processes, liveProcesses: [Self.pid])
        host.isProcessAlive = { $0 == Self.pid && emulator.alive }
        host.processStartTime = { $0 == Self.pid ? emulator.started : nil }
        let signals = Signals()
        host.signalProcess = { pid, signal in
            signals.append(pid, signal)
            if endsOn.contains(signal) { emulator.end() }
            return true
        }
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        #expect(try await stopper.stop(target, timeout: .seconds(120)))
        #expect(signals.sent == sent.map { (Self.pid, $0) }.map(Signals.Sent.init))
    }

    @Test("a console that answers is never followed by a signal, even when the emulator then outlasts the limit")
    func answeredConsoleSendsNoSignal() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        var (host, _) = Self.host(home: home, adb: Self.adb(rows: Self.row), respond: { _ in
            ProcessCaptureResult(status: 0, stdout: "OK: killing emulator, bye bye\n", stderr: "")
        })
        let signals = Signals()
        host.signalProcess = { signals.append($0, $1); return true }
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        await #expect(throws: AndroidError.self) { try await stopper.stop(target, timeout: .seconds(5)) }
        #expect(signals.sent.isEmpty)
    }

    final class Signals: @unchecked Sendable {
        struct Sent: Equatable { let pid: Int32; let signal: Int32; init(_ pair: (Int32, Int32)) { (pid, signal) = pair } }
        private let lock = NSLock()
        private var list: [Sent] = []
        var sent: [Sent] { lock.withLock { list } }
        func append(_ pid: Int32, _ signal: Int32) { lock.withLock { list.append(Sent((pid, signal))) } }
    }

    @Test("a pid reused by another emulator reads as this one gone")
    func reusedPid() async throws {
        let home = try Self.home()
        try Self.writeDiscovery(in: home)
        let emulator = Emulator()
        let (host, _) = Self.host(home: home, adb: Self.adb(rows: ""), emulator: emulator, respond: { call in
            if call.arguments.contains("kill") { emulator.reuse() }
            return ProcessCaptureResult(status: 0, stdout: "OK\n", stderr: "")
        })
        let stopper = Self.stopper(host)
        let target = try Self.running(try await stopper.find(Self.avd))

        #expect(try await stopper.stop(target, timeout: .seconds(5)))
    }
}
