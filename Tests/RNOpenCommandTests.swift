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

    @Test("--port and --timeout are checked", arguments: [["--port", "0"], ["--timeout", "5"], ["--scheme", "not a scheme"]])
    func validation(extra: [String]) {
        #expect(throws: (any Error).self) { try RNOpen.parse(["--port", "8742", "--bundle-id", "com.example.app"] + extra + ["--device", Self.device.rawValue]) }
    }
}
