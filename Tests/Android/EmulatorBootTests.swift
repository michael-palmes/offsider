import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Emulator boot")
@MainActor
struct EmulatorBootTests {
    nonisolated static let avd = "Offsider_E2E_Pixel_9"

    /// What adb reports: the emulator appears after `hiddenFor` device listings, and boots after `pendingBootChecks` queries.
    final class AdbState: @unchecked Sendable {
        private let lock = NSLock()
        private var hiddenFor: Int
        private var pendingBootChecks: Int

        init(hiddenFor: Int = 0, pendingBootChecks: Int = 0) {
            self.hiddenFor = hiddenFor
            self.pendingBootChecks = pendingBootChecks
        }

        func appear() { lock.withLock { hiddenFor = 0 } }

        func listing() -> String {
            lock.withLock {
                guard hiddenFor == 0 else {
                    hiddenFor -= 1
                    return ""
                }
                return "emulator-5556 device product:sdk_gphone16k_arm64 model:sdk_gphone16k_arm64 transport_id:7\n"
            }
        }

        func bootCompleted() -> String {
            lock.withLock {
                guard pendingBootChecks == 0 else {
                    pendingBootChecks -= 1
                    return ""
                }
                return "1"
            }
        }
    }

    static func server(_ state: AdbState, name: String = avd) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: state.listing())
                default: return .hang
                }
            },
            device: { _, _ in FakeAdbServer.shell(stdout: "\(name)\n\n\(state.bootCompleted())\n16\n36\n") }
        ))
    }

    static func home(emulatorInstalled: Bool = true) throws -> URL {
        let home = try AndroidTestHost.homeWithSDK()
        if emulatorInstalled {
            try AndroidTestHost.makeExecutable("Library/Android/sdk/emulator/emulator", in: home)
        }
        let avdHome = home.appendingPathComponent(".android/avd")
        for name in [avd, "Pixel_9a"] {
            try AndroidTestHost.write("path=\(avdHome.appendingPathComponent("\(name).avd").path)\n", to: "\(name).ini", in: avdHome)
            try AndroidTestHost.write("hw.device.name=pixel_9\n", to: "\(name).avd/config.ini", in: avdHome)
        }
        return home
    }

    nonisolated static func writeDiscovery(pid: Int32, in home: URL, grpc: Bool = true) {
        let grpcLines = grpc ? "grpc.port=8556\ngrpc.token=secret\n" : ""
        try? AndroidTestHost.write("avd.id=\(avd)\nport.serial=5556\n\(grpcLines)", to: "Library/Caches/TemporaryItems/avd/running/pid_\(pid).ini", in: home)
    }

    struct Run {
        let result: Result<EmulatorBootResult, AndroidError>
        let lines: [String]
    }

    static func boot(_ host: AndroidHost, headless: Bool = false, timeout: Duration = .seconds(240)) async -> Run {
        var lines: [String] = []
        let request = EmulatorBootRequest(avdName: avd, headless: headless, timeout: timeout)
        do {
            let result = try await EmulatorBooter(host: host) { _, _ in }.boot(request) { lines.append($0) }
            return Run(result: .success(result), lines: lines)
        } catch let error as AndroidError {
            return Run(result: .failure(error), lines: lines)
        } catch {
            return Run(result: .failure(AndroidError(.notSupported, "unexpected \(error)")), lines: lines)
        }
    }

    @Test("launch arguments are the AVD and -no-metrics, plus -no-window when headless; never -port or -grpc")
    func launchArguments() {
        #expect(EmulatorBooter.launchArguments(avdName: "X", headless: false) == ["-avd", "X", "-no-metrics"])
        #expect(EmulatorBooter.launchArguments(avdName: "X", headless: true) == ["-avd", "X", "-no-metrics", "-no-window"])
        for headless in [false, true] {
            let arguments = EmulatorBooter.launchArguments(avdName: "X", headless: headless)
            #expect(!arguments.contains { $0.hasPrefix("-port") || $0.hasPrefix("-grpc") })
        }
    }

    @Test("a cold boot launches once, takes the serial from the new discovery file and waits for Android and gRPC")
    func coldBoot() async throws {
        let home = try Self.home()
        let adb = AdbState(hiddenFor: .max, pendingBootChecks: 2)
        let launcher = FakeLauncher(pid: 4242) { _ in
            Self.writeDiscovery(pid: 4242, in: home)
            adb.appear()
        }
        let emulator = FakeEmulator(booted: [false, true])
        let host = AndroidTestHost.make(
            home: home, environment: ["TMPDIR": home.path], adb: Self.server(adb),
            emulator: FakeEmulatorConnector(.success(emulator)), liveProcesses: [4242], launcher: launcher
        )

        let run = await Self.boot(host, headless: true)

        let logPath = home.appendingPathComponent("offsider-boot-\(Self.avd).log").path
        #expect(try run.result.get() == EmulatorBootResult(serial: "emulator-5556", alreadyRunning: false, hasGRPC: true, logPath: logPath))
        #expect(launcher.launches == [FakeLauncher.Launch(
            executable: home.appendingPathComponent("Library/Android/sdk/emulator/emulator").path,
            arguments: ["-avd", Self.avd, "-no-metrics", "-no-window"],
            logPath: logPath
        )])
        #expect(emulator.calls == [.status, .status, .close])
        #expect(run.lines == ["Starting \(Self.avd)...", "Waiting for Android to finish booting on emulator-5556..."])
    }

    @Test("a launcher that hands over to a child process still finds the new discovery file for the AVD")
    func launcherHandsOver() async throws {
        let home = try Self.home()
        let adb = AdbState(hiddenFor: .max)
        let launcher = FakeLauncher(pid: 4242, exitStatus: 0) { _ in
            Self.writeDiscovery(pid: 5000, in: home)
            adb.appear()
        }
        let host = AndroidTestHost.make(home: home, adb: Self.server(adb), emulator: FakeEmulatorConnector(.success(FakeEmulator())), liveProcesses: [5000], launcher: launcher)

        #expect(try await Self.boot(host).result.get().serial == "emulator-5556")
    }

    @Test("a booted AVD is reported, not started again; --headless is ignored with a note")
    func alreadyBooted() async throws {
        let home = try Self.home()
        Self.writeDiscovery(pid: 900, in: home)
        let launcher = FakeLauncher()
        let host = AndroidTestHost.make(home: home, adb: Self.server(AdbState()), liveProcesses: [900], launcher: launcher)

        let run = await Self.boot(host, headless: true)

        #expect(try run.result.get() == EmulatorBootResult(serial: "emulator-5556", alreadyRunning: true, hasGRPC: true, logPath: nil))
        #expect(launcher.launches.isEmpty)
        #expect(run.lines == ["--headless ignored: \(Self.avd) is already running.", "\(Self.avd) is already running as emulator-5556."])
    }

    @Test("a booted AVD without a discovery file says commands will use adb")
    func alreadyBootedWithoutGrpc() async throws {
        let launcher = FakeLauncher()
        let host = AndroidTestHost.make(home: try Self.home(), adb: Self.server(AdbState()), launcher: launcher)

        let run = await Self.boot(host)

        #expect(try run.result.get().hasGRPC == false)
        #expect(launcher.launches.isEmpty)
        #expect(run.lines == ["\(Self.avd) is already running as emulator-5556 without gRPC; commands will use adb."])
    }

    @Test("an AVD that is still booting is waited for, not started again")
    func alreadyBooting() async throws {
        let home = try Self.home()
        Self.writeDiscovery(pid: 900, in: home)
        let launcher = FakeLauncher()
        let host = AndroidTestHost.make(
            home: home, adb: Self.server(AdbState(pendingBootChecks: 3)),
            emulator: FakeEmulatorConnector(.success(FakeEmulator())), liveProcesses: [900], launcher: launcher
        )

        let run = await Self.boot(host)

        #expect(try run.result.get() == EmulatorBootResult(serial: "emulator-5556", alreadyRunning: true, hasGRPC: true, logPath: nil))
        #expect(launcher.launches.isEmpty)
        #expect(run.lines.first == "\(Self.avd) is already starting as emulator-5556.")
    }

    @Test("a live emulator holding the AVD's instance lock is waited for instead of starting a second one")
    func instanceLockHeld() async throws {
        let home = try Self.home()
        try AndroidTestHost.write("777 ", to: ".android/avd/\(Self.avd).avd/hardware-qemu.ini.lock", in: home)
        Self.writeDiscovery(pid: 777, in: home)
        let launcher = FakeLauncher()
        let host = AndroidTestHost.make(
            home: home, adb: Self.server(AdbState(hiddenFor: 2)),
            emulator: FakeEmulatorConnector(.success(FakeEmulator())), liveProcesses: [777], launcher: launcher
        )

        let run = await Self.boot(host)

        #expect(try run.result.get().serial == "emulator-5556")
        #expect(launcher.launches.isEmpty)
        #expect(run.lines.first == "\(Self.avd) is already starting (pid 777); waiting for it.")
    }

    @Test("an emulator that exits during start-up reports its status and the last 20 lines of its log")
    func earlyExit() async throws {
        let home = try Self.home()
        let log = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let launcher = FakeLauncher(pid: 4242, exitStatus: 1) { launch in
            try? Data(log.utf8).write(to: URL(fileURLWithPath: launch.logPath))
        }
        let host = AndroidTestHost.make(home: home, environment: ["TMPDIR": home.path], adb: Self.server(AdbState(hiddenFor: .max)), launcher: launcher)

        guard case .failure(let error) = await Self.boot(host).result else {
            Issue.record("expected the boot to fail")
            return
        }
        #expect(error.kind == .emulatorExited)
        #expect(error.message.hasPrefix("The emulator exited during start-up (status 1). Last lines of \(home.path)/offsider-boot-\(Self.avd).log:\nline 6\n"))
        #expect(error.message.hasSuffix("\nline 25"))
    }

    @Test("a boot that does not finish in time names the serial and log, and leaves the emulator running")
    func timeout() async throws {
        let home = try Self.home()
        let adb = AdbState(hiddenFor: .max, pendingBootChecks: .max)
        let launcher = FakeLauncher(pid: 4242) { _ in
            Self.writeDiscovery(pid: 4242, in: home)
            adb.appear()
        }
        let host = AndroidTestHost.make(home: home, environment: ["TMPDIR": home.path], adb: Self.server(adb), liveProcesses: [4242], launcher: launcher)

        guard case .failure(let error) = await Self.boot(host, timeout: .seconds(20)).result else {
            Issue.record("expected the boot to time out")
            return
        }
        #expect(error.message == "\(Self.avd) (emulator-5556) did not finish booting within 20 s. It is still running; check its window or \(home.path)/offsider-boot-\(Self.avd).log, then run `offsider boot \(Self.avd)` again to keep waiting.")
        #expect(launcher.launches.count == 1)
    }

    @Test("an unknown AVD lists the AVDs on this Mac, asking adb only for its device list")
    func unknownAVD() async throws {
        let server = Self.server(AdbState())
        let host = AndroidTestHost.make(home: try Self.home(), adb: server)
        let request = EmulatorBootRequest(avdName: "Pixel_10", headless: false, timeout: .seconds(240))

        let error = await #expect(throws: AndroidError.self) { try await EmulatorBooter(host: host) { _, _ in }.boot(request) { _ in } }
        #expect(error?.message == "No AVD named Pixel_10. AVDs on this Mac: Offsider_E2E_Pixel_9, Pixel_9a. Create one in Android Studio's Device Manager.")
        #expect(server.services == ["host:devices-l"])
    }

    @Test("boot refuses a connected phone's serial without sending the phone anything")
    func phoneSerialRefused() async throws {
        let server = FakeAdbServer { request in
            request.service == "host:devices-l"
                ? FakeAdbServer.okay(payload: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n")
                : .hang
        }
        let host = AndroidTestHost.make(home: try Self.home(), adb: server)
        let request = EmulatorBootRequest(avdName: "R58M123ABC", headless: false, timeout: .seconds(240))

        let error = await #expect(throws: AndroidError.self) { try await EmulatorBooter(host: host) { _, _ in }.boot(request) { _ in } }
        #expect(error?.message == "boot starts emulators, and R58M123ABC is a connected phone. Run `offsider list-devices` to see AVD names.")
        #expect(server.requests.allSatisfy { $0.serial == nil })
    }

    @Test("a missing emulator binary says how to install it")
    func emulatorMissing() async throws {
        let home = try Self.home(emulatorInstalled: false)
        let host = AndroidTestHost.make(home: home, adb: Self.server(AdbState(hiddenFor: .max)))

        guard case .failure(let error) = await Self.boot(host).result else {
            Issue.record("expected the boot to fail")
            return
        }
        #expect(error.message == "The Android Emulator is not installed in \(home.path)/Library/Android/sdk/emulator. Install it with Android Studio's SDK Manager.")
    }
}

@Suite("boot command")
struct BootCommandTests {
    @Test("boot refuses a simulator UUID, a serial and an out-of-range timeout with usage errors", arguments: [
        ("boot \(UUID().uuidString)", "boot starts Android emulators. Boot an iOS simulator with `xcrun simctl boot <udid>`."),
        ("boot emulator-5556", "boot takes an AVD name, not a serial."),
        ("boot Pixel_9 --timeout 5", "--timeout must be between 10 and 1800 seconds."),
    ])
    func validation(command: String, message: String) async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid(command)
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains(message))
    }
}
