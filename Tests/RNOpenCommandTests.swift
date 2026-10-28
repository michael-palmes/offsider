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

    @Test("without --wait-id an empty app window never ends the wait, and the timeout says it stayed empty", arguments: [
        FakeUI.tree([]), ExpoDevClientOpeningTests.devMenuOnly(),
    ])
    func bareNeverUp(bare: UITree) async throws {
        let (result, _) = try await Self.watch(["--timeout", "10"], trees: [bare], liveness: [])
        guard case .failure(let error) = result else { Issue.record("an empty window counted as up"); return }
        #expect(error.reason == .conditionNotMet && error.exitCode == .unverified)
        #expect(error.userFacingDescription.hasSuffix("within 10 s: the app's window stayed empty, as it does while its bundle loads. Try a longer --timeout, or pass --wait-id with an element of its first screen; if it never loads, run rn open again with --restart."))
    }

    @Test("an empty window that then shows the app is up once the app holds still for a second")
    func bareThenApp() async throws {
        let (report, _) = try await Self.open([], trees: Array(repeating: FakeUI.tree([]), count: 5) + [Self.app])
        #expect(report.elapsedMs >= 4000)
    }

    @Test("a timeout while the Bundling banner shows says the bundle is still loading")
    func bundlingAtTimeout() async throws {
        let (result, _) = try await Self.watch(["--wait-id", "menu-title", "--timeout", "10"], trees: [Self.bundling], liveness: [])
        guard case .failure(let error) = result else { Issue.record("expected a timeout"); return }
        #expect(error.userFacingDescription.hasSuffix("the Bundling banner was still showing, so the bundle is still loading. Try a longer --timeout."))
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

    @Test("an iOS crash report not written yet is named by its folder and the pid to look for")
    func pendingCrashReport() async throws {
        let (result, _) = try await Self.watch(
            [], trees: [Self.bundling], liveness: [.running(Self.playground), .notRunning, .notRunning], report: .pending(directory: "/Users/me/Library/Logs/DiagnosticReports")
        )
        guard case .failure(let error) = result else { Issue.record("expected app_crashed"); return }
        #expect(error.userFacingDescription.hasSuffix("Its crash report is not written yet; look in /Users/me/Library/Logs/DiagnosticReports for the newest one from pid 4100."))
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

    @Test("with --restart, the stopped process still exiting when the first read runs is not taken for the app, so its exit is no crash")
    func restartIgnoresStoppedProcess() async throws {
        let fresh = AppProcess(pid: 4200, started: 2)
        let (result, backend) = try await Self.watch(
            ["--restart", "--wait-id", "menu-title"], trees: Array(repeating: Self.bundling, count: 8) + [Self.app],
            liveness: [.running(Self.playground), .running(Self.playground), .running(fresh)]
        )
        #expect(try result.get().sends == 1)
        #expect(backend.crashReportRequests.isEmpty)
        #expect(!backend.livenessReads.contains { $0.seen == Self.playground })
    }

    @Test("--restart stops the app before the first link, and without it nothing is stopped")
    func restartStopsFirst() async throws {
        let url = "open exp+playground://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8742"
        let (_, restarted) = try await Self.open(["--restart", "--wait-id", "menu-title"], trees: [Self.bundling, Self.app])
        #expect(restarted.devClientCalls == ["stop com.example.app", url])

        let (_, plain) = try await Self.open(["--wait-id", "menu-title"], trees: [Self.bundling, Self.app])
        #expect(plain.devClientCalls == [url])
    }

    @Test("a timeout on a blank screen says so and hints --restart, never restarting by itself")
    func blankScreenHint() async throws {
        let blank = FakeUI.tree([FakeUI.node(.other, frame: FakeUI.frame(0, 0, 402, 874), children: [FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874))])])
        let (result, backend) = try await Self.watch(["--wait-id", "menu title", "--timeout", "10"], trees: [blank], liveness: [])
        guard case .failure(let error) = result else { Issue.record("expected a timeout"); return }
        #expect(error.reason == .conditionNotMet)
        #expect(error.userFacingDescription.contains("blank screen") && error.userFacingDescription.contains("--restart"))
        #expect(error.hint == "offsider rn open --port 8742 --bundle-id com.example.app --wait-id 'menu title' --restart --device \(Self.device.rawValue)")
        #expect(!backend.devClientCalls.contains { $0.hasPrefix("stop") })

        let (labelled, _) = try await Self.watch(["--wait-id", "never-there", "--timeout", "10"], trees: [Self.app], liveness: [])
        guard case .failure(let other) = labelled else { Issue.record("expected a timeout"); return }
        #expect(!other.userFacingDescription.contains("blank screen"))

        let (bare, _) = try await Self.watch(["--wait-id", "never-there", "--timeout", "10"], trees: [FakeUI.tree([])], liveness: [])
        guard case .failure(let launching) = bare else { Issue.record("expected a timeout"); return }
        #expect(!launching.userFacingDescription.contains("blank screen"))
    }

    // MARK: Dead waits

    static let phone = DeviceID(rawValue: "R58MFAKE01", platform: .android)
    static let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)

    /// A phone allowed for any app: each tree read is refused until the command names its app.
    final class AnyAppPhone: FakeDeviceBackend, AppTargetSelecting {
        private(set) var selected: String?

        func selectApp(_ appID: String, on id: DeviceID) -> Bool {
            defer { selected = appID }
            return selected != appID
        }

        override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
            guard selected != nil else {
                throw CLIError(errorDescription: "\(id.rawValue) is allowed for any app, so each command names the app it drives, and none was named.", reason: .appNotAllowed)
            }
            return try await super.accessibilityTree(for: id, point: point)
        }
    }

    /// Fails the first `failures` tree reads with `error`, then serves its trees.
    final class FailingReads: FakeDeviceBackend {
        var error: any Error = CLIError(errorDescription: "The tree read failed.", reason: .treeReadFailed)
        var failures = Int.max
        private(set) var failed = 0

        override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
            guard failed >= failures else {
                failed += 1
                throw error
            }
            return try await super.accessibilityTree(for: id, point: point)
        }
    }

    /// Runs `rn open` on `backend`, returning the outcome and the seconds it took on the scripted clock.
    static func run(_ arguments: [String], on backend: FakeDeviceBackend, device: DeviceID = device) async throws -> (Result<RNOpen.Report, CLIError>, TimeInterval) {
        let clock = ScriptedClock()
        let command = try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + arguments + ["--device", device.rawValue])
        do {
            return (.success(try await command.open(on: DeviceRouter.Route(backend: backend, device: device), metro: running, clock: clock.poll)), clock.now)
        } catch let error as CLIError {
            return (.failure(error), clock.now)
        }
    }

    @Test("on a phone allowed for any app the wait reads --bundle-id's tree, so the wait id ends it")
    func anyAppPhoneReadsTheBundle() async throws {
        let phone = AnyAppPhone(platform: .android, trees: [Self.bundling, Self.app])
        let (result, _) = try await Self.run(["--wait-id", "menu-title", "--timeout", "600"], on: phone, device: Self.phone)
        #expect(try result.get().waitID == "menu-title")
        #expect(phone.selected == "com.example.app")
    }

    @Test("tree reads failing for 10 s end the wait with the read's own error, not a Metro timeout")
    func failingReadsStopWithTheirError() async throws {
        let backend = FailingReads(platform: .android, trees: [Self.app])
        backend.error = CLIError(errorDescription: "R58MFAKE01 is allowed for any app, so each command names the app it drives, and none was named.", reason: .appNotAllowed)
        let (result, seconds) = try await Self.run(["--wait-id", "menu-title", "--timeout", "600"], on: backend, device: Self.phone)
        guard case .failure(let error) = result else { Issue.record("expected the read's error"); return }
        #expect(error.reason == .appNotAllowed)
        #expect(!error.userFacingDescription.contains("did not finish loading"))
        #expect(seconds <= 11)
    }

    @Test("a few failed reads while the app starts are not the end of the wait")
    func briefFailuresKeepWaiting() async throws {
        let backend = FailingReads(platform: .android, trees: [Self.bundling, Self.app])
        backend.failures = 6
        let (result, _) = try await Self.run(["--wait-id", "menu-title"], on: backend, device: Self.emulator)
        #expect(try result.get().waitID == "menu-title")
    }

    static let hung = ForegroundActivities(top: "com.example.app/com.example.app.MainActivity", home: "com.example.launcher/com.example.launcher.Home")
    static let noWindow = CLIError(errorDescription: "Offsider found no window on emulator-5554. Unlock the emulator and bring an app to the front.", reason: .noWindow)

    @Test("no window for the app in front on an unlocked Android screen is app_not_responding after 10 s, with --restart as the fix")
    func hungAppIsNotResponding() async throws {
        let backend = FailingReads(platform: .android, trees: [])
        backend.error = Self.noWindow
        backend.foregrounds = [Self.hung]
        let (result, seconds) = try await Self.run(["--scheme", "exp+playground", "--timeout", "600"], on: backend, device: Self.emulator)
        guard case .failure(let error) = result else { Issue.record("expected app_not_responding"); return }
        #expect(error.reason == .appNotResponding && error.exitCode == .failure)
        #expect(error.userFacingDescription.hasPrefix("com.example.app is in front on emulator-5554, but Android has listed no window for it for 10 s"))
        #expect(!error.userFacingDescription.contains("Unlock"))
        #expect(error.hint == "offsider rn open --port 8742 --bundle-id com.example.app --scheme exp+playground --restart --device emulator-5554")
        #expect(seconds <= 11)
    }

    @Test("no window on a locked screen, or with the home screen in front, stays no_window")
    func noWindowWithoutAHungApp() async throws {
        let locked = FailingReads(platform: .android, trees: [])
        locked.error = Self.noWindow
        locked.foregrounds = [Self.hung]
        locked.awake = AwakeReading(screen: .on, lockScreen: .secure)
        let (lockedResult, _) = try await Self.run(["--timeout", "600"], on: locked, device: Self.emulator)
        #expect(lockedResult.failure?.reason == .noWindow)

        let home = FailingReads(platform: .android, trees: [])
        home.error = Self.noWindow
        home.foregrounds = [ForegroundActivities(top: Self.hung.home, home: Self.hung.home)]
        let (homeResult, _) = try await Self.run(["--timeout", "600"], on: home, device: Self.emulator)
        #expect(homeResult.failure?.reason == .noWindow)
    }

    static let settings = FakeUI.tree([FakeUI.node(.other, id: "settings-screen", label: "Settings", frame: FakeUI.frame(0, 0, 402, 874))])

    @Test("a loaded screen without --wait-id ends the wait after 15 s, naming the screen's first id")
    func otherScreenStopsEarly() async throws {
        let (result, seconds) = try await Self.run(["--wait-id", "home-screen", "--timeout", "600"], on: FakeDeviceBackend(trees: [Self.bundling, Self.app]))
        guard case .failure(let error) = result else { Issue.record("expected the other screen"); return }
        #expect(error.reason == .conditionNotMet && error.exitCode == .unverified)
        #expect(error.userFacingDescription == #"com.example.app shows the screen with id="menu-title", and --wait-id home-screen is not on it: it has shown it for 15 s, so rn open stopped waiting. Pass --wait-id with an element of the screen the app opens on, or bring the app to that screen first."#)
        #expect(seconds < 20)
    }

    @Test("a screen that keeps changing waits for --timeout, then names the last screen instead of blaming Metro")
    func changingScreensTimeOut() async throws {
        let (result, seconds) = try await Self.run(["--wait-id", "home-screen", "--timeout", "30"], on: FakeDeviceBackend(trees: Array(repeating: [Self.app, Self.settings], count: 40).flatMap { $0 }))
        guard case .failure(let error) = result else { Issue.record("expected a timeout"); return }
        #expect(error.userFacingDescription.contains("and --wait-id home-screen is not on it: it did not appear within 30 s."))
        #expect(seconds >= 30)
    }

    /// Serves its trees, then fails every read after `goodReads`.
    final class LastReadFails: FakeDeviceBackend {
        var goodReads = 0

        override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
            guard treeReads < goodReads else { throw CLIError(errorDescription: "The tree read failed.", reason: .treeReadFailed) }
            return try await super.accessibilityTree(for: id, point: point)
        }
    }

    @Test("one failed read just before --timeout does not hide what the wait saw")
    func lastFailedReadKeepsTheTimeoutReason() async throws {
        let backend = LastReadFails(trees: [Self.app, Self.settings])
        backend.goodReads = 19
        let (result, _) = try await Self.run(["--wait-id", "home-screen", "--timeout", "10"], on: backend)
        #expect(result.failure?.userFacingDescription.contains("--wait-id home-screen is not on it: it did not appear within 10 s.") == true)
    }

    static let appPID = 4100
    static let springBoardPID = 4300

    /// SpringBoard's tree while its permission alert covers the app: its own application, the alert's title and two buttons.
    static func permissionAlert() -> UITree {
        let alert = FakeUI.node(.other, label: "“Playground” Would Like to Send You Notifications", frame: FakeUI.frame(41, 300, 320, 240), pid: springBoardPID, children: [
            FakeUI.node(.text, label: "Notifications may include alerts, sounds and icon badges.", frame: FakeUI.frame(61, 360, 280, 60), pid: springBoardPID),
            FakeUI.node(.button, label: "Don’t Allow", frame: FakeUI.frame(41, 440, 160, 48), pid: springBoardPID),
            FakeUI.node(.button, label: "Allow", frame: FakeUI.frame(201, 440, 160, 48), pid: springBoardPID),
        ])
        let root = FakeUI.node(.application, label: " ", frame: FakeUI.frame(0, 0, 402, 874), pid: springBoardPID, children: [alert])
        return UITree(platform: .ios, device: device.rawValue, roots: [root])
    }

    @Test("a system alert over the running app ends the wait as person_required, naming it and its buttons, and taps nothing", arguments: [
        ["--wait-id", "menu-title", "--timeout", "600"], ["--timeout", "600"],
    ])
    func systemPromptIsReported(arguments: [String]) async throws {
        let backend = HitTestingFakeBackend(trees: [Self.permissionAlert()])
        backend.processNames = [Self.springBoardPID: "SpringBoard"]
        backend.livenessReadings = [.running(AppProcess(pid: Self.appPID, started: 1))]
        let (result, seconds) = try await Self.run(arguments, on: backend)
        guard case .failure(let error) = result else { Issue.record("expected person_required"); return }
        #expect(error.reason == .personRequired)
        #expect(error.userFacingDescription == #"com.example.app is behind the system prompt "“Playground” Would Like to Send You Notifications" from SpringBoard ("Don’t Allow", "Allow"), so rn open stopped waiting. It never answers a system prompt: ask the user which to choose, answer it, then run rn open again."#)
        #expect(backend.session.calls.isEmpty)
        #expect(seconds < 5)
    }

    @Test("an Open in prompt long after the last link is reported as a system prompt and never tapped")
    func lateOpenPromptIsNotAnswered() async throws {
        let pid = Self.springBoardPID
        let prompt = FakeUI.node(.other, label: "Open in “Maps”?", frame: FakeUI.frame(41, 388, 320, 126), pid: pid, children: [
            FakeUI.node(.button, label: "Cancel", frame: FakeUI.frame(57, 450, 140, 48), pid: pid),
            FakeUI.node(.button, label: "Open", frame: FakeUI.frame(205, 450, 140, 48), pid: pid),
        ])
        let late = UITree(platform: .ios, device: Self.device.rawValue, roots: [
            FakeUI.node(.application, label: " ", frame: FakeUI.frame(0, 0, 402, 874), pid: pid, children: [prompt]),
        ])
        let backend = HitTestingFakeBackend(trees: Array(repeating: Self.bundling, count: 24) + [late])
        backend.livenessReadings = [.running(AppProcess(pid: Self.appPID, started: 1))]
        let (result, _) = try await Self.run(["--wait-id", "menu-title", "--timeout", "600"], on: backend)
        #expect(result.failure?.reason == .personRequired)
        #expect(result.failure?.userFacingDescription.contains(#""Open in “Maps”?""#) == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("Expo's dev menu intro over the app ends the wait with rn prepare as the fix")
    func devMenuIntroNamesPrepare() async throws {
        let intro = FakeUI.tree([
            FakeUI.node(.text, label: "This is the developer menu. It gives you access to useful tools in your development builds.", frame: FakeUI.frame(40, 700, 330, 34)),
            FakeUI.node(.button, label: "Continue", frame: FakeUI.frame(40, 790, 330, 48)),
        ])
        let (result, seconds) = try await Self.run(["--wait-id", "menu-title", "--timeout", "600"], on: FakeDeviceBackend(trees: [Self.bundling, intro]))
        guard case .failure(let error) = result else { Issue.record("expected the intro"); return }
        #expect(error.reason == .conditionNotMet)
        #expect(error.hint == "offsider rn prepare --bundle-id com.example.app --device \(Self.device.rawValue)")
        #expect(seconds < 5)
    }

    @Test("--port and --timeout are checked", arguments: [["--port", "0"], ["--timeout", "5"], ["--scheme", "not a scheme"]])
    func validation(extra: [String]) {
        #expect(throws: (any Error).self) { try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + extra + ["--device", Self.device.rawValue]) }
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
