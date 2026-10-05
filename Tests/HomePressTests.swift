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

    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

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
}
