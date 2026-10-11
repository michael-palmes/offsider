import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("rn open")
@MainActor
struct RNOpenCommandTests {
    static let device = DeviceID(rawValue: UUID().uuidString, platform: .ios)
    static let running = MetroStatus(fetch: { _, _ in (200, Data("packager-status:running".utf8)) })

    static let launcher = FakeUI.tree([
        FakeUI.node(.text, label: "Development Build", frame: FakeUI.frame(20, 100, 300, 30)),
        FakeUI.node(.text, label: "Searching for development servers...", frame: FakeUI.frame(20, 140, 300, 30)),
    ])
    static let bundling = FakeUI.tree([FakeUI.node(.text, label: "Bundling 42%", frame: FakeUI.frame(20, 800, 300, 30))])
    static let app = FakeUI.tree([FakeUI.node(.other, id: "menu-title", label: "Offsider Playground", frame: FakeUI.frame(20, 100, 300, 30))])

    static func open(_ arguments: [String], trees: [UITree], metro: MetroStatus = running) async throws -> (RNOpen.Report, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(trees: trees)
        let command = try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + arguments + ["--device", device.rawValue])
        let report = try await command.open(on: DeviceRouter.Route(backend: backend, device: device), metro: metro, clock: ScriptedClock().poll)
        return (report, backend)
    }

    @Test("a launcher still showing 10 s after the link gets it once more, then the app's --wait-id ends the wait")
    func launcherResends() async throws {
        let (report, backend) = try await Self.open(["--wait-id", "menu-title"], trees: Array(repeating: Self.launcher, count: 22) + [Self.bundling, Self.app])

        #expect(report.sends == 2 && report.launcherSeen)
        #expect(backend.openedURLs == Array(repeating: "exp+playground://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8742", count: 2))
        #expect(report.jsonLine().hasPrefix(#"{"version":1,"bundleId":"com.example.app","url":"exp+playground://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8742","host":"127.0.0.1","port":8742,"metro":"running","sends":2,"launcherSeen":true,"waitId":"menu-title","elapsedMs":"#))
    }

    @Test("the simulator's Open in prompt for the link is answered with Open, then the app loads")
    func acceptsOpenPrompt() async throws {
        let prompt = FakeUI.tree([
            FakeUI.node(.other, label: "Open in “OffsiderPlaygroundRN”?", frame: FakeUI.frame(41, 388, 320, 126)),
            FakeUI.node(.button, label: "Cancel", frame: FakeUI.frame(57, 450, 140, 48)),
            FakeUI.node(.button, label: "Open", frame: FakeUI.frame(205, 450, 140, 48)),
        ])
        let (report, backend) = try await Self.open(["--wait-id", "menu-title"], trees: [prompt, Self.bundling, Self.app])

        #expect(report.sends == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 275, y: 474))])
        #expect(ExpoDevLauncher.openLinkPrompt(in: Self.app) == nil)
    }

    @Test("without --wait-id the app is up once the screen is still for a second")
    func quietScreen() async throws {
        let (report, _) = try await Self.open([], trees: [Self.bundling, Self.app])
        #expect(report.sends == 1 && !report.launcherSeen)
        #expect(report.elapsedMs >= 1000)
    }

    @Test("an app that never shows --wait-id times out with exit 5")
    func timeout() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.open(["--wait-id", "never-there", "--timeout", "10"], trees: [Self.app])
        }
        #expect(error?.exitCode == .unverified)
    }

    @Test("Metro not answering is exit 9 metro_not_running, before any link is sent")
    func metroDown() async throws {
        let backend = FakeDeviceBackend(trees: [Self.app])
        let command = try RNOpen.parse(["--port", "8743", "--bundle-id", "com.example.app", "--device", Self.device.rawValue])
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.open(on: DeviceRouter.Route(backend: backend, device: Self.device), metro: MetroStatus(fetch: { _, _ in throw URLError(.cannotConnectToHost) }), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .metroNotRunning && error?.exitCode == .toolMissing)
        #expect(backend.openedURLs.isEmpty)
    }

    @Test("a load error on screen is exit 1 rn_load_failed")
    func loadError() async throws {
        let failed = FakeUI.tree([FakeUI.node(.text, label: "There was a problem loading the project.", frame: FakeUI.frame(20, 100, 300, 30))])
        let error = await #expect(throws: CLIError.self) { _ = try await Self.open([], trees: [failed]) }
        #expect(error?.reason == .rnLoadFailed && error?.exitCode == .failure)
    }

    static let playground = AppProcess(pid: 4100, started: 1)

    /// Runs `rn open` with scripted liveness reads, returning the outcome and the backend.
    static func watch(
        _ arguments: [String], trees: [UITree], liveness: [AppLiveness], report: AppCrashReport? = nil
    ) async throws -> (Result<RNOpen.Report, CLIError>, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(trees: trees)
        backend.livenessReadings = liveness
        backend.crashReportAnswer = report
        let command = try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + arguments + ["--device", device.rawValue])
        do {
            return (.success(try await command.open(on: DeviceRouter.Route(backend: backend, device: device), metro: running, clock: ScriptedClock().poll)), backend)
        } catch let error as CLIError {
            return (.failure(error), backend)
        }
    }

    @Test("one liveness read that misses the app is not a crash; the next read finding it again keeps waiting")
    func oneMissIsNotACrash() async throws {
        let (result, backend) = try await Self.watch(
            ["--wait-id", "menu-title"], trees: Array(repeating: Self.bundling, count: 8) + [Self.app],
            liveness: [.running(Self.playground), .notRunning, .running(Self.playground)]
        )
        #expect(try result.get().sends == 1)
        #expect(backend.livenessReads.count == 3)
        #expect(backend.crashReportRequests.isEmpty)
    }

    @Test("the app gone on two reads a second apart is app_crashed (exit 1), naming the crash report")
    func twoMissesAreACrash() async throws {
        let (result, backend) = try await Self.watch(
            ["--wait-id", "menu-title"], trees: [Self.bundling],
            liveness: [.running(Self.playground), .notRunning, .notRunning], report: .file("/Users/me/Library/Logs/DiagnosticReports/Playground.ips")
        )
        guard case .failure(let error) = result else { Issue.record("expected app_crashed"); return }
        #expect(error.reason == .appCrashed && error.exitCode == .failure)
        #expect(error.userFacingDescription == "com.example.app crashed while loading from Metro on 127.0.0.1:8742: its process 4100 stopped. Crash report: /Users/me/Library/Logs/DiagnosticReports/Playground.ips")
        #expect(backend.livenessReads.map(\.seen) == [nil, Self.playground, Self.playground])
        #expect(backend.crashReportRequests == [Self.playground])
    }

    @Test("a process replaced by another with the same bundle is a crash, and the Android cause is named")
    func replacedProcessIsACrash() async throws {
        let restarted = AppProcess(pid: 4200, started: 2)
        let (result, _) = try await Self.watch(
            [], trees: [Self.bundling], liveness: [.running(Self.playground), .running(restarted), .running(restarted)], report: .cause("signal 11 (SIGSEGV)")
        )
        guard case .failure(let error) = result else { Issue.record("expected app_crashed"); return }
        #expect(error.reason == .appCrashed)
        #expect(error.userFacingDescription.hasSuffix("its process 4100 stopped. It stopped with signal 11 (SIGSEGV)."))
    }

    @Test("an app never seen running is never a crash: the wait ends at --timeout with exit 5")
    func neverSeenIsNotACrash() async throws {
        let (result, backend) = try await Self.watch(["--timeout", "10"], trees: [Self.bundling], liveness: [.notRunning])
        guard case .failure(let error) = result else { Issue.record("expected a timeout"); return }
        #expect(error.reason == .conditionNotMet)
        #expect(backend.crashReportRequests.isEmpty)
    }

    @Test("liveness is read about every 2 s, 6 times at most in 10 s, and a process listing is offered at most every 4 s")
    func livenessBudget() async throws {
        let (result, backend) = try await Self.watch(["--timeout", "10"], trees: [Self.bundling], liveness: [.running(Self.playground)])
        guard case .failure = result else { Issue.record("expected a timeout"); return }
        #expect(backend.livenessReads.count <= 6)
        #expect(backend.livenessReads.map(\.mayList) == [true, false, true, false, true])
    }

    @Test("without --wait-id a screen gone still just after the app stopped is not taken for the app loading")
    func noQuietSuccessAfterACrash() async throws {
        let home = FakeUI.tree([FakeUI.node(.button, label: "Playground", frame: FakeUI.frame(20, 100, 60, 60))])
        let (result, backend) = try await Self.watch(
            [], trees: [Self.bundling, Self.bundling, Self.bundling, home],
            liveness: [.running(Self.playground), .running(Self.playground), .notRunning, .notRunning]
        )
        guard case .failure(let error) = result else { Issue.record("expected app_crashed, not a quiet success"); return }
        #expect(error.reason == .appCrashed)
        #expect(backend.livenessReads.count == 4)
    }

    @Test("--port and --timeout are checked", arguments: [["--port", "0"], ["--timeout", "5"], ["--scheme", "not a scheme"]])
    func validation(extra: [String]) {
        #expect(throws: (any Error).self) { try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + extra + ["--device", Self.device.rawValue]) }
    }
}
