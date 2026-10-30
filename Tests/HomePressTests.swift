import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("Android foreground")
struct AndroidForegroundTests {
    static let launcher = "com.google.android.apps.nexuslauncher/com.google.android.apps.nexuslauncher.NexusLauncherActivity"

    @Test("the resumed activity parses from each release's line, with a leading-dot class expanded", arguments: [
        ("top=topResumedActivity=ActivityRecord{1d2e3f4 u0 com.android.settings/.Settings t12}", "com.android.settings/com.android.settings.Settings"),
        ("top=mResumedActivity: ActivityRecord{8a7b u0 com.example.app/com.example.app.MainActivity t5}", "com.example.app/com.example.app.MainActivity"),
        ("top=ResumedActivity: ActivityRecord{77 u0 com.google.android.apps.nexuslauncher/.NexusLauncherActivity t1}", launcher),
        ("top=", nil),
    ] as [(String, String?)])
    func top(line: String, expected: String?) {
        let parsed = AndroidForeground.parse(line + "\nhome=com.google.android.apps.nexuslauncher/.NexusLauncherActivity\n")
        #expect(parsed.top == expected)
        #expect(parsed.home == Self.launcher)
    }

    @Test("a missing or unresolved launcher reads as unknown")
    func unknownHome() {
        #expect(AndroidForeground.parse("top=\nhome=No activity found\n") == ForegroundActivities(top: nil, home: nil))
    }
}

@Suite("home press")
@MainActor
struct HomePressTests {
    static let app = "com.example.app/com.example.app.MainActivity"
    static let home = AndroidForegroundTests.launcher

    final class Script {
        var readings: [ForegroundActivities]
        var afterIntent: ForegroundActivities?
        var keys = 0
        var intents = 0
        var sleeps = 0

        init(_ readings: [ForegroundActivities], afterIntent: ForegroundActivities? = nil) {
            self.readings = readings
            self.afterIntent = afterIntent
        }

        func run() async throws -> HomePressOutcome {
            try await HomePress.run(
                read: {
                    if self.intents > 0, let after = self.afterIntent { return after }
                    let reading = self.readings[0]
                    if self.readings.count > 1 { self.readings.removeFirst() }
                    return reading
                },
                sendKey: { self.keys += 1 },
                sendIntent: { self.intents += 1 },
                sleep: { _ in self.sleeps += 1 }
            )
        }
    }

    static func at(_ top: String) -> ForegroundActivities { ForegroundActivities(top: top, home: home) }

    @Test("the key alone brings the launcher to the front")
    func keyWorks() async throws {
        let script = Script([Self.at(Self.app), Self.at(Self.app), Self.at(Self.home)])
        let outcome = try await script.run()
        #expect(outcome.reached && outcome.via == .key)
        #expect(script.intents == 0)
    }

    @Test("an ignored key is followed by the HOME intent, once")
    func intentOnce() async throws {
        let script = Script([Self.at(Self.app)], afterIntent: Self.at(Self.home))
        let outcome = try await script.run()
        #expect(outcome.reached && outcome.via == .intent)
        #expect(script.keys == 1 && script.intents == 1)
        #expect(script.sleeps == 8)
    }

    @Test("when neither reaches the launcher the outcome says so, after one intent")
    func neither() async throws {
        let script = Script([Self.at(Self.app)])
        let outcome = try await script.run()
        #expect(!outcome.reached && outcome.via == nil)
        #expect(script.intents == 1)
    }

    @Test("already on the launcher, the key is enough")
    func alreadyHome() async throws {
        let script = Script([Self.at(Self.home)])
        let outcome = try await script.run()
        #expect(outcome.reached && outcome.via == .key)
        #expect(script.intents == 0 && script.sleeps == 0)
    }

    @Test("a launcher whose HOME entry is an activity-alias counts as home by its package, so no intent is sent")
    func aliasLauncher() async throws {
        let alias = ForegroundActivities(top: Self.app, home: "com.sec.android.app.launcher/com.sec.android.app.launcher.activities.LauncherActivity")
        let resumed = ForegroundActivities(top: "com.sec.android.app.launcher/com.android.launcher3.uioverrides.QuickstepLauncher", home: alias.home)
        let script = Script([alias, resumed])
        let outcome = try await script.run()
        #expect(outcome.reached && outcome.via == .key)
        #expect(script.intents == 0)
    }

    @Test("a foreground that cannot be read before the press still sends the key, unchecked")
    func unreadableBeforePress() async throws {
        var keys = 0
        let outcome = try await HomePress.run(
            read: { throw CLIError(errorDescription: "dumpsys timed out") },
            sendKey: { keys += 1 },
            sendIntent: { Issue.record("no intent without a reading") },
            sleep: { _ in }
        )
        #expect(keys == 1)
        #expect(!outcome.reached)
        #expect(outcome.unreadable == "dumpsys timed out")
    }

    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    @Test("button home with an unreadable foreground presses the key: a warning without --verify, exit 5 with it")
    func unreadableForeground() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.foregroundError = CLIError(errorDescription: "dumpsys timed out")
        var err = ""
        try await Button.pressHome(on: backend, device: Self.device, verification: try VerificationOptions.parse([]), sleep: { _ in }, writeOutput: { _ in }, writeError: { err += $0 })
        #expect(backend.session.calls == [.perform(.shortButtonPress(.home))])
        #expect(err == "Warning: the home key was sent, but Offsider could not check that the launcher came to the front (dumpsys timed out).")

        var out = ""
        let verify = try VerificationOptions.parse(["--verify", "--json"])
        await #expect(throws: ExitCode(5)) {
            try await Button.pressHome(on: backend, device: Self.device, verification: verify, sleep: { _ in }, writeOutput: { out += $0 }, writeError: { _ in })
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(object["dispatched"] as? String == "yes")
        #expect(object["verified"] as? Bool == false)
        #expect(backend.session.calls.count == 2)
    }

    @Test("button home --verify --json reports change activity and the home_intent note")
    func verifyReport() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.foregrounds = [Self.at(Self.app)]
        backend.foregroundAfterIntent = Self.at(Self.home)
        var out = ""
        var err = ""
        let options = try VerificationOptions.parse(["--verify", "--json"])
        try await Button.pressHome(on: backend, device: Self.device, verification: options, sleep: { _ in }, writeOutput: { out += $0 }, writeError: { err += $0 })

        let object = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(object["verified"] as? Bool == true)
        #expect(object["change"] as? String == "activity")
        #expect(object["note"] as? String == "home_intent")
        #expect(backend.homeIntents == 1)
        #expect(err.hasPrefix("✓ Home button verified: "))
    }

    @Test("a launcher that never comes up exits 5 with --verify and only warns without it")
    func notReached() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.foregrounds = [Self.at(Self.app)]
        var err = ""
        let verify = try VerificationOptions.parse(["--verify"])
        await #expect(throws: ExitCode(5)) {
            try await Button.pressHome(on: backend, device: Self.device, verification: verify, sleep: { _ in }, writeOutput: { _ in }, writeError: { err += $0 })
        }
        #expect(err.hasPrefix("✗ Home button not verified"))

        err = ""
        try await Button.pressHome(on: backend, device: Self.device, verification: try VerificationOptions.parse([]), sleep: { _ in }, writeOutput: { _ in }, writeError: { err += $0 })
        #expect(err.hasPrefix("Warning: the home key and the HOME intent were sent"))
    }

    @Test("--verify-timeout sets how long each check waits for the launcher; without it the window is 2 s", arguments: [
        (["--verify", "--verify-timeout", "5"], 10.0), (["--verify"], 4.0),
    ] as [([String], Double)])
    func windowFollowsVerifyTimeout(arguments: [String], waited: Double) async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.foregrounds = [Self.at(Self.app)]
        var slept = Duration.zero
        await #expect(throws: ExitCode(5)) {
            try await Button.pressHome(
                on: backend, device: Self.device, verification: try VerificationOptions.parse(arguments),
                sleep: { slept += $0 }, writeOutput: { _ in }, writeError: { _ in }
            )
        }
        #expect(slept == .seconds(waited))
    }
}

@Suite("iOS simulator home press")
@MainActor
struct SimulatorHomePressTests {
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
    static let springBoardPID = 100
    static let appPID = 200

    /// Answers each centre read from `answers`, holding the last; a nil answer is a read that failed.
    final class Prober: FakeDeviceBackend, PresentationProbing {
        var answers: [Int?] = []
        func probe(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
            let pid = answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
            guard let pid else { throw CLIError(errorDescription: "no answer", reason: .commandFailed) }
            return FakeUI.node(.button, frame: FakeUI.frame(0, 0, 10, 10), pid: pid)
        }
    }

    private static func press(_ answers: [Int?], arguments: [String] = ["--verify", "--json"]) async throws -> (out: [String], err: [String], exit: Int32?, keys: Int, seconds: TimeInterval) {
        let backend = Prober(trees: [])
        backend.answers = answers
        var out: [String] = []
        var err: [String] = []
        var exit: Int32?
        var clock: TimeInterval = 0
        do {
            try await Button.pressSimulatorHome(
                on: backend, device: simulator, centre: UIPoint(x: 200, y: 400), verification: try VerificationOptions.parse(arguments),
                sleep: { _ in clock += 0.6 }, now: { clock }, processPath: { $0 == springBoardPID ? "/Library/Runtime/CoreServices/SpringBoard.app/SpringBoard" : "/Library/Runtime/Apps/Example.app/Example" },
                writeOutput: { out.append($0) }, writeError: { err.append($0) }
            )
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        return (out, err, exit, backend.session.calls.count, clock)
    }

    @Test("an app that leaves is verified as soon as SpringBoard answers, after one press")
    func reached() async throws {
        let result = try await Self.press([Self.appPID, Self.appPID, Self.springBoardPID])
        #expect(result.exit == nil)
        #expect(result.err == ["✓ Home button verified: SpringBoard is in front, attempt 1 of 1"])
        #expect(result.keys == 1)
        let json = result.out.joined()
        #expect(json.contains(#""verified": true"#))
        #expect(json.contains("activity"))
    }

    @Test("SpringBoard answering before the press still presses, since it also hosts alerts over an app")
    func alertOverApp() async throws {
        let result = try await Self.press([Self.springBoardPID])
        #expect(result.exit == nil)
        #expect(result.keys == 1)
    }

    @Test("an app that never leaves exits 5 after the press and its one retry, each within its window however slow the reads")
    func neverReached() async throws {
        let result = try await Self.press([Self.appPID], arguments: ["--verify"])
        #expect(result.exit == OffsiderExitCode.unverified.rawValue)
        #expect(result.keys == 2)
        #expect(result.seconds <= 2 * (SimulatorHomePress.window + 0.6))
        #expect(result.err == ["✗ Home button not verified: SpringBoard did not come to the front after 2 presses."])
    }

    @Test("no read answering says so, not that the app stayed")
    func unreadable() async throws {
        let result = try await Self.press([nil], arguments: ["--verify", "--retries", "0"])
        #expect(result.exit == OffsiderExitCode.unverified.rawValue)
        #expect(result.err.first?.contains("could not read what is in front") == true)
    }

    @Test("--retries 0 presses once")
    func noRetry() async throws {
        let result = try await Self.press([Self.appPID], arguments: ["--verify", "--retries", "0"])
        #expect(result.err == ["✗ Home button not verified: SpringBoard did not come to the front after 1 press."])
    }

    @Test("only SpringBoard's own path counts")
    func springBoardPath() {
        #expect(SimulatorHomePress.isSpringBoard(path: "/Library/CoreServices/SpringBoard.app/SpringBoard"))
        #expect(!SimulatorHomePress.isSpringBoard(path: "/Applications/SpringBoardLike.app/SpringBoardLike"))
    }
}
