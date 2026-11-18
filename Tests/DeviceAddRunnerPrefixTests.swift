import Foundation
@testable import OffsiderCore
@testable import OffsiderIOSDevice
@testable import Offsider
import Testing

@Suite("devices add records the runner prefix", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DeviceAddRunnerPrefixTests {
    static let prefix = "dev.offsider.abcde12345"

    static func context(home: String, seal: MemorySeal = MemorySeal(), terminal: AccessTerminal, row: DeviceSummary = DeviceAccessCommandTests.row, environment: [String: String] = [:]) -> DeviceAccessContext {
        var context = DeviceAccessCommandTests.context(home: home, seal: seal, terminal: terminal, devices: { [row] }, teams: { [EasyAddTests.team] })
        context.prepare = { _ in true }
        context.environment = { environment }
        return context
    }

    static func file(_ home: String) throws -> String {
        try String(contentsOfFile: DeviceAccessCommandTests.file(home), encoding: .utf8)
    }

    @Test("--runner-prefix is saved beside the team, and the Touch ID that saves it names the runner it builds")
    func flagRecorded() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        _ = try await DeviceAccessCommandTests.allow(["--test-device", "--runner-prefix", Self.prefix], answers: [], context: { Self.context(home: home, terminal: $0) }, presence: presence)
        let entry = try #require(try DeviceAccessCommandTests.entries(home).first)
        #expect(entry.runnerPrefix == Self.prefix && entry.team == "ABCDE12345")
        #expect(presence.reasons.count == 1 && presence.reasons[0].hasSuffix(" and build its runner as \(Self.prefix).runner"))
    }

    @Test("OFFSIDER_IOS_RUNNER_PREFIX in the person's terminal is saved as if passed")
    func environmentRecorded() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            Self.context(home: home, terminal: $0, environment: ["OFFSIDER_IOS_RUNNER_PREFIX": Self.prefix])
        })
        #expect(try DeviceAccessCommandTests.entries(home).first?.runnerPrefix == Self.prefix)
    }

    @Test("Offsider's own prefix, or none, writes no runnerPrefix key, so the file is as before")
    func defaultNotWritten() async throws {
        for arguments in [["--test-device"], ["--test-device", "--runner-prefix", XcodeRunnerBuilder.defaultPrefix]] {
            let home = try makePolicyHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            _ = try await DeviceAccessCommandTests.allow(arguments, answers: [], context: { Self.context(home: home, terminal: $0) })
            #expect(try !Self.file(home).contains("runnerPrefix"))
        }
    }

    @Test("a flag and a variable naming different prefixes exit 64 and save nothing")
    func conflictRefused() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        let error = await #expect(throws: CLIError.self) {
            _ = try await DeviceAccessCommandTests.allow(["--test-device", "--runner-prefix", Self.prefix], answers: [], context: {
                Self.context(home: home, terminal: $0, environment: ["OFFSIDER_IOS_RUNNER_PREFIX": "com.example.qa"])
            }, presence: presence)
        }
        #expect(error?.exitCode == .usage)
        #expect(error?.userFacingDescription.contains("--runner-prefix is \(Self.prefix), but OFFSIDER_IOS_RUNNER_PREFIX is com.example.qa") == true)
        #expect(presence.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DeviceAccessCommandTests.file(home)))
    }

    @Test("a prefix that is not a reverse-DNS id is refused before anything runs, and an Android phone takes none")
    func refusedInput() async throws {
        #expect(throws: (any Error).self) { try DeviceAccessAllow.parse(["--runner-prefix", "com..example"]) }
        #expect(throws: (any Error).self) { try DeviceAccessAllow.parse(["--plan", "--runner-prefix", Self.prefix]) }
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let error = await #expect(throws: CLIError.self) {
            _ = try await DeviceAccessCommandTests.allow(["--test-device", "--runner-prefix", Self.prefix], answers: [], context: {
                Self.context(home: home, terminal: $0, row: DeviceAccessCommandTests.androidRow)
            })
        }
        #expect(error?.userFacingDescription.contains("--runner-prefix is for an iPhone or iPad") == true)
    }

    @Test("re-adding a device without a prefix keeps the one it has")
    func keptOnChange() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let entry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], team: "ABCDE12345", runnerPrefix: Self.prefix, testDevice: true)
        try DeviceAccessCommandTests.seed(home, seal: seal, [entry])
        _ = try await DeviceAccessCommandTests.allow(["--device", PolicyFixtures.phone, "--test-device"], answers: [], context: { Self.context(home: home, seal: seal, terminal: $0) })
        #expect(try DeviceAccessCommandTests.entries(home).first?.runnerPrefix == Self.prefix)
    }

    @Test("the App ID fix runner build names is one command that asks nothing, keeps the test device and its expiry, and saves the prefix")
    func appIDFixIsOneCommand() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let allowed = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], team: "ABCDE12345", testDevice: true)
        try DeviceAccessCommandTests.seed(home, seal: seal, [allowed])
        let fix = DeviceAddPlan.runnerPrefixCommand(allowed, team: "ABCDE12345", prefix: DeviceAllowance.suggestedRunnerPrefix(team: "ABCDE12345"))
        let arguments = Array(fix.split(separator: " ").dropFirst(3).map(String.init))
        let presence = RecordingPresence()

        let (output, transcript) = try await DeviceAccessCommandTests.allow(arguments, answers: [], context: { terminal in
            var context = Self.context(home: home, seal: seal, terminal: terminal)
            context.signingTeams = { [EasyAddTests.team, SigningTeam(id: "ZYXWV54321", name: "Other Team")] }
            return context
        }, presence: presence)

        let entry = try #require(try DeviceAccessCommandTests.entries(home).first)
        #expect(entry.runnerPrefix == Self.prefix && entry.testDevice && entry.team == "ABCDE12345" && entry.expires == nil)
        for question in [AllowScreen.deviceQuestion, AllowScreen.useQuestion, AllowScreen.teamQuestion, AllowScreen.appQuestion, AllowScreen.expiryQuestion] {
            #expect(!transcript.contains(question))
        }
        #expect(presence.reasons.count == 1)
        #expect(output.contains("Ready: Test iPhone"))
    }
}

@Suite("devices add --plan fills in the runner prefix")
@MainActor
struct DeviceAddPlanPrefixTests {
    @Test("a prefix in the agent's environment goes into every iPhone command, since the person's terminal will not have it; Android's never")
    func planFillsPrefix() throws {
        let built = DeviceAddPlan.make(
            rows: [DeviceAccessCommandTests.row, DeviceAccessCommandTests.androidRow], policy: DeviceAddPlanTests.free, teams: [.init(id: "ABCDE12345", name: "Example Team")],
            now: PolicyFixtures.now, runnerPrefix: "dev.offsider.abcde12345", app: { $0 == .ios ? "com.example.app" : nil }
        )
        #expect(built.devices[0].testDeviceCommand == "offsider devices add --device \(PolicyFixtures.phone) --test-device --runner-prefix dev.offsider.abcde12345")
        #expect(built.devices[0].oneAppCommand == "offsider devices add --device \(PolicyFixtures.phone) --app com.example.app --runner-prefix dev.offsider.abcde12345")
        #expect(built.devices[1].oneAppCommand?.contains("--runner-prefix") == false)
        for command in [built.devices[0].testDeviceCommand, built.devices[0].oneAppCommand].compactMap({ $0 }) {
            #expect(try DeviceAccessAllow.parse(Array(command.split(separator: " ").dropFirst(3).map(String.init))).runnerPrefix == "dev.offsider.abcde12345")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(built.json().utf8)) as? [String: Any])
        #expect(object["runnerPrefix"] as? String == "dev.offsider.abcde12345")
        #expect(built.text().contains("Runner prefix dev.offsider.abcde12345, from OFFSIDER_IOS_RUNNER_PREFIX."))
        let plain = DeviceAddPlan.make(rows: [DeviceAccessCommandTests.row], policy: DeviceAddPlanTests.free, teams: [], now: PolicyFixtures.now, runnerPrefix: XcodeRunnerBuilder.defaultPrefix, app: { _ in nil })
        #expect(plain.runnerPrefix == nil && plain.devices[0].oneAppCommand?.contains("--runner-prefix") == false)
    }

    @Test("--plan with a prefix the builder would refuse exits 64 naming the variable, before anything is listed")
    func planRefusesBadPrefix() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal())
        context.environment = { ["OFFSIDER_IOS_RUNNER_PREFIX": "not a prefix"] }
        let error = await #expect(throws: IOSDeviceError.self) {
            try await PersonPresence.$terminal.withValue({ false }) { _ = try await DeviceAccessAllow.parse(["--plan"]).planOutput(context: context) }
        }
        #expect(error?.reason == .usage && error?.message.contains("OFFSIDER_IOS_RUNNER_PREFIX") == true)
    }
}

@Suite("devices add names the first-run steps still owed", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DeviceFirstRunTests {
    @Test("a later failure proves the steps before it, the failing step is left to its warning, and Android or a ready device owes nothing", arguments: [
        (FailureReason?.none, false, [DeviceFirstRun.Step.uiAutomation, .trustCertificate]),
        (.none, true, [.developerMode, .uiAutomation, .trustCertificate]),
        (.developerModeOff, false, [.uiAutomation, .trustCertificate]),
        (.certificateNotTrusted, false, [.uiAutomation]),
        (.uiAutomationOff, false, []),
        (.deviceLocked, false, [.uiAutomation, .trustCertificate]),
    ])
    func owed(reason: FailureReason?, developerModeOff: Bool, steps: [DeviceFirstRun.Step]) {
        #expect(DeviceFirstRun.owed(platform: .ios, ready: false, stoppedBy: reason, developerModeOff: developerModeOff) == steps)
        #expect(DeviceFirstRun.owed(platform: .ios, ready: true, stoppedBy: reason, developerModeOff: developerModeOff).isEmpty)
        #expect(DeviceFirstRun.owed(platform: .android, ready: false, stoppedBy: reason, developerModeOff: developerModeOff).isEmpty)
    }

    @Test("each step is a row of at most five words with where to do it, and an ask naming the device")
    func stepWording() {
        for step in DeviceFirstRun.Step.allCases {
            #expect(step.title.split(separator: " ").count <= 5)
            #expect(step.detail.hasPrefix("Settings > "))
            #expect(PersonAsk.filled(step.ask, name: "Test iPhone", id: nil).hasPrefix("Can you "))
            #expect(PersonAsk.filled(step.ask, name: "Test iPhone", id: nil).contains("Test iPhone"))
        }
    }

    @Test("a setup that stops short of ready lists the steps still owed on the phone, as rows and in --json")
    func listedWhenNotReady() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            EasyAddTests.context(home: home, terminal: $0, row: DeviceAccessCommandTests.developerModeOffRow) { _ in throw IOSDeviceError(.runnerBuildFailed, "The runner did not build.") }
        })
        for step in DeviceFirstRun.Step.allCases {
            #expect(output.contains("[ ] \(step.title)") && output.contains(step.detail))
            #expect(transcript.contains(step.title))
        }

        let other = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: other) }
        let (json, _) = try await DeviceAccessCommandTests.allow(["--test-device", "--json"], answers: [], context: {
            EasyAddTests.context(home: other, terminal: $0) { _ in throw IOSDeviceError(.runnerBuildFailed, "The runner did not build.") }
        })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["firstRun"] as? [String] == DeviceFirstRun.asks([.uiAutomation, .trustCertificate], name: "Test iPhone"))
    }

    @Test("the step a person was already asked for and left is not repeated as a row, and a ready phone shows none")
    func notRepeated() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let ticks = CallCounter()
        let (output, _) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: { terminal in
            var context = EasyAddTests.context(home: home, terminal: terminal) { _ in throw IOSDeviceError(.uiAutomationOff, "XCTest could not enable UI automation on Test iPhone.") }
            // Each reading is past the last one's setup wait, so add stops waiting on the person at once.
            context.now = { PolicyFixtures.now.addingTimeInterval(Double(ticks.tick()) * (DeviceAccessAllow.setupWait + 1)) }
            return context
        })
        #expect(output.contains("Allowed Test iPhone") && !output.contains("[ ]"))
        #expect(output.contains("XCTest could not enable UI automation"), "the step it stopped on is named once, as what it needs")

        let ready = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let (done, _) = try await DeviceAccessCommandTests.allow(["--test-device", "--json"], answers: [], context: { EasyAddTests.context(home: ready, terminal: $0) })
        #expect(!done.contains("firstRun"))
    }

    @Test("--plan lists the first-run asks for an iPhone not yet added, and none for Android or a device already allowed")
    func planListsSteps() throws {
        let fresh = DeviceAddPlanTests.plan([DeviceAccessCommandTests.row, DeviceAccessCommandTests.androidRow])
        #expect(fresh.devices[0].firstRun == DeviceFirstRun.asks([.uiAutomation, .trustCertificate], name: "Test iPhone"))
        #expect(fresh.devices[1].firstRun.isEmpty)
        #expect(fresh.json().contains(#""devices[0].firstRun[]""#), "the asks hold the device's name, so they are data")
        #expect(fresh.text().contains("  Then: Can you turn on UI Automation on Test iPhone?"))
        let entry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], testDevice: true)
        let allowed = DeviceAddPlanTests.plan([DeviceAccessCommandTests.row], policy: PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry])))
        #expect(allowed.devices[0].firstRun.isEmpty)
    }
}
