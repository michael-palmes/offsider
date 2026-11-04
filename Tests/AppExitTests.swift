import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("A command says the app died")
@MainActor
struct AppExitTests {
    private static let device = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
    private static let save = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 350, 44))

    /// An application root with `pid`, as an iOS simulator's tree gives it.
    private static func app(pid: Int, label: String = "Playground", _ children: [UINode] = [FakeUI.node(.text, label: "Title", frame: FakeUI.frame(0, 0, 100, 20))]) -> UITree {
        UITree(platform: .ios, device: device.rawValue, roots: [FakeUI.node(.application, label: label, frame: FakeUI.frame(0, 0, 402, 874), pid: pid, children: children)])
    }

    private static let home = app(pid: 200, label: "Home screen", [FakeUI.node(.button, label: "Settings", frame: FakeUI.frame(20, 100, 60, 60))])

    private static func probe(_ tree: UITree) -> ElementProbe {
        tree.roots.flatMap { $0.flattened() }.first { $0.id == "save" }.map { .present($0) } ?? .absent(reason: ElementProbe.notFound)
    }

    /// Serves `trees` in order, holding the last, on a clock that moves only when the loop sleeps.
    private static func sources(_ trees: [UITree], backend: FakeDeviceBackend) -> WaitSources {
        var reads = 0
        var now: TimeInterval = 0
        var sources = WaitSources(
            tree: {
                defer { reads += 1 }
                return trees[min(reads, trees.count - 1)]
            },
            fingerprint: { throw CancellationError() },
            sleep: { now += Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 },
            now: { now }
        )
        sources.appExit = AppExitCheck(reader: backend, device: device, sleep: { _ in })
        return sources
    }

    @Test("a wait for an element whose app went to the home screen and stopped exits 1 app_stopped, not a timeout")
    func waitForElementAfterStop() async throws {
        let backend = FakeDeviceBackend(trees: [])
        backend.livenessReadings = [.notRunning]

        let error = await #expect(throws: AppExitError.self) {
            try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 1, interval: 0.25, sources: Self.sources([Self.app(pid: 100), Self.home], backend: backend))
        }

        #expect(error?.reason == .appStopped)
        #expect(error?.exitCode == .failure)
        #expect(error?.message == "The app stopped: its process is gone.")
        #expect(backend.livenessReads.count == 2)
        #expect(backend.livenessReads.first?.seen == AppProcess(pid: 100))
    }

    @Test("--gone never passes because the app stopped, and a crash report makes it app_crashed naming the file")
    func goneAfterCrash() async throws {
        let backend = FakeDeviceBackend(trees: [])
        backend.livenessReadings = [.notRunning]
        backend.crashReportAnswer = .file("/reports/Playground-2026-11-04.ips")

        let error = await #expect(throws: AppExitError.self) {
            try await WaitLoop.run(.element(probe: Self.probe, gone: true), timeout: 1, interval: 0.25, sources: Self.sources([Self.app(pid: 100, [Self.save]), Self.home], backend: backend))
        }

        #expect(error?.reason == .appCrashed)
        #expect(error?.message.hasSuffix("Crash report: /reports/Playground-2026-11-04.ips") == true)
        #expect(backend.crashReportRequests == [AppProcess(pid: 100)])
    }

    @Test("an app still running after another app came to the front keeps the wait's own result", arguments: [false, true])
    func runningAppKeepsResult(gone: Bool) async throws {
        let backend = FakeDeviceBackend(trees: [])
        backend.livenessReadings = [.running(AppProcess(pid: 100))]

        let outcome = try await WaitLoop.run(
            .element(probe: Self.probe, gone: gone), timeout: 1, interval: 0.25, sources: Self.sources([Self.app(pid: 100, gone ? [Self.save] : []), Self.home], backend: backend)
        )

        #expect(outcome.met == gone)
        #expect(backend.livenessReads.count == 1)
    }

    @Test("reads of the same app make no liveness read, met or timed out")
    func sameAppReadsNothing() async throws {
        let backend = FakeDeviceBackend(trees: [])
        backend.livenessReadings = [.notRunning]

        let timedOut = try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 1, interval: 0.25, sources: Self.sources([Self.app(pid: 100)], backend: backend))
        let gone = try await WaitLoop.run(.element(probe: Self.probe, gone: true), timeout: 1, interval: 0.25, sources: Self.sources([Self.app(pid: 100, [Self.save]), Self.app(pid: 100)], backend: backend))

        #expect(!timedOut.met && gone.met)
        #expect(backend.livenessReads.isEmpty)
    }

    @Test("assert compares its one read with the app the tree cache saw")
    func assertTakesTheCachedApp() async throws {
        let backend = FakeDeviceBackend(trees: [])
        backend.livenessReadings = [.notRunning]
        var sources = Self.sources([Self.home], backend: backend)
        sources.appBefore = { ShownApp(pid: 100, appID: "com.example.playground") }

        let error = await #expect(throws: AppExitError.self) {
            try await WaitLoop.run(.element(probe: Self.probe, gone: true), timeout: 0, interval: 0, sources: sources)
        }

        #expect(error?.message == "com.example.playground stopped: its process is gone.")
        #expect(error?.hint == "offsider app launch --restart --app com.example.playground --device \(Self.device.rawValue)")
    }

    @Test("a tap whose change was the app stopping is not verified: it exits 1; the same change with the app running verifies")
    func verifiedChangeToStoppedApp() async throws {
        for (reading, stops) in [(AppLiveness.notRunning, true), (.running(AppProcess(pid: 100)), false)] {
            let backend = FakeDeviceBackend(trees: [])
            backend.livenessReadings = [reading]
            var trees = [Self.app(pid: 100), Self.app(pid: 100), Self.home]
            var now: TimeInterval = 0
            var dependencies = Verifier.Dependencies(
                tree: { trees.count > 1 ? trees.removeFirst() : trees[0] },
                screenshot: { throw CancellationError() },
                sleep: { now += Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 },
                now: { now }
            )
            dependencies.appExit = AppExitCheck(reader: backend, device: Self.device, sleep: { _ in })
            var sent = 0

            if stops {
                await #expect(throws: AppExitError.self) {
                    try await Verifier.run(styles: [.simulator, .physical], timeout: .seconds(1), dependencies: dependencies) { _ in sent += 1 }
                }
            } else {
                let outcome = try await Verifier.run(styles: [.simulator, .physical], timeout: .seconds(1), dependencies: dependencies) { _ in sent += 1 }
                #expect(outcome.verified)
            }
            #expect(sent == 1)
        }
    }

    @Test("Android: the crash buffer names a package's newest crash by its own pid, Java or native, and nothing for another package")
    func androidCrashByPackage() {
        let buffer = """
        --------- beginning of crash
        11-04 08:00:00.100  3900  3900 E AndroidRuntime: FATAL EXCEPTION: main
        11-04 08:00:00.100  3900  3900 E AndroidRuntime: Process: com.example.other, PID: 3900
        11-04 08:00:00.100  3900  3900 E AndroidRuntime: java.lang.NullPointerException: elsewhere
        11-04 08:00:01.123  4100  4100 E AndroidRuntime: FATAL EXCEPTION: main
        11-04 08:00:01.123  4100  4100 E AndroidRuntime: Process: com.example.app, PID: 4100
        11-04 08:00:01.123  4100  4100 E AndroidRuntime: java.lang.IllegalStateException: someone@example.com
        """
        #expect(CrashBufferParser.cause(in: buffer, package: "com.example.app") == "java.lang.IllegalStateException")
        #expect(CrashBufferParser.cause(in: buffer, package: "com.example.missing") == nil)
        let native = "11-04 08:00:02.500  4200  4233 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 4233 (mqt_js), pid 4200 (com.example.app)\n"
        #expect(CrashBufferParser.cause(in: buffer + "\n" + native, package: "com.example.app") == "signal 11 (SIGSEGV)")
        #expect(CrashBufferParser.command(since: Date(timeIntervalSince1970: 1_000)) == "logcat -b crash -d -v threadtime -T 995.000")
    }

    @Test("the app the tree shows: a pid on iOS, the package in front on Android; another pid or package differs")
    func shownApp() {
        #expect(ShownApp.of(Self.app(pid: 100)) == ShownApp(pid: 100, appID: nil))
        #expect(ShownApp(pid: 100, appID: nil).differs(from: ShownApp.of(Self.home)))
        #expect(!ShownApp(pid: 100, appID: "com.example.playground").differs(from: ShownApp.of(Self.app(pid: 100))))
        let android = FakeUI.tree(platform: .android, [FakeUI.node(.button, label: "Go", frame: FakeUI.frame(100, 400, 200, 60), platform: .android)])
        var packaged = android
        packaged.roots = packaged.roots.map { root in
            var root = root
            root.native = .android(AndroidNativeAttributes(package: "com.example.app"))
            return root
        }
        #expect(ShownApp.of(packaged) == ShownApp(pid: nil, appID: "com.example.app"))
        #expect(ShownApp(pid: nil, appID: "com.example.app").differs(from: nil))
    }
}
