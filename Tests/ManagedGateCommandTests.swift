import Foundation
@testable import Offsider
@testable import OffsiderAndroid
@testable import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("Managed ceilings on commands", .serialized)
@MainActor
struct ManagedGateCommandTests {
    static func forced(_ item: ManagedCeilings.Switch) -> FakeManagedPreferences {
        FakeManagedPreferences(values: [item.key: .bool(item.restrictsWhen)])
    }

    static func open(_ item: ManagedCeilings.Switch) -> FakeManagedPreferences {
        FakeManagedPreferences(values: [item.key: .bool(!item.restrictsWhen)])
    }

    /// The error `body` throws while `source` is the managed policy; nil when it runs.
    static func refusal(under source: FakeManagedPreferences, _ body: () async throws -> Void) async -> CLIError? {
        await ManagedGate.$sourceOverride.withValue(source) {
            do {
                try await body()
                return nil
            } catch {
                return error as? CLIError ?? CLIError(errorDescription: "\(error)", reason: .internalError)
            }
        }
    }

    static func expectManaged(_ error: CLIError?, key: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(error?.reason == .managedPolicy, sourceLocation: sourceLocation)
        #expect(error?.userFacingDescription.hasPrefix("Your organisation") == true, sourceLocation: sourceLocation)
        #expect(error?.userFacingDescription.contains("(\(key))") == true, sourceLocation: sourceLocation)
        #expect(error?.userFacingDescription.hasSuffix("Ask the administrator of this Mac.") == true, sourceLocation: sourceLocation)
    }

    @Test("forceMasks refuses every way to drop a mask or redaction, for a person and an agent alike, and asks no one")
    func forceMasks() async throws {
        UnmaskedConsent.confirmed = false
        defer { UnmaskedConsent.confirmed = false }
        let unmasked = try VideoMaskOptions.parse(["--unmasked"])
        let plain = try VideoMaskOptions.parse([])
        let shot = try Screenshot.parse(["--no-mask-secure", "--device", "emulator-5554"])
        let gates: [(String, (OutputProfile) async throws -> Void)] = [
            ("screenshot --no-mask-secure", { try await UnmaskedConsent.confirm(command: "screenshot", profile: $0) }),
            ("a batch step's --no-mask-secure", { try UnmaskedConsent.require(profile: $0) }),
            ("describe-ui --raw-source", { try await DescribeUI.confirmRawSource(profile: $0) }),
            ("logs and rn logbox --no-redact", { try await Logs.confirmUnredacted(profile: $0) }),
            ("video --unmasked", { try await unmasked.confirmUnmasked(command: "record-video", profile: $0) }),
            ("OFFSIDER_MASK_SECURE=0 on video", { try await plain.confirmCheckOff(command: "stream-video", environment: ["OFFSIDER_MASK_SECURE": "0"], profile: $0) }),
        ]
        for (name, gate) in gates {
            for profile in [OutputProfile.person, .agent] {
                let presence = FakePresence()
                let error = await Self.refusal(under: Self.forced(.forceMasks)) {
                    try await PersonPresence.$terminal.withValue({ true }) {
                        try await PersonPresence.$current.withValue(presence) { try await gate(profile) }
                    }
                }
                Self.expectManaged(error, key: "forceMasks")
                #expect(presence.reasons.isEmpty, "\(name) asked a person although the organisation refuses it")
            }
            let unforced = await Self.refusal(under: Self.open(.forceMasks)) { try await gate(.person) }
            #expect(unforced == nil, "\(name) was refused with forceMasks false")
        }
        let planned = await Self.refusal(under: Self.forced(.forceMasks)) { _ = try shot.maskPlan() }
        Self.expectManaged(planned, key: "forceMasks")
        let wrong = await Self.refusal(under: FakeManagedPreferences(values: ["forceMasks": .strings(["no"])])) { try UnmaskedConsent.require(profile: .person) }
        Self.expectManaged(wrong, key: "forceMasks")
    }

    @Test("a command that keeps its masks never reads forceMasks")
    func masksKeptReadNothing() async throws {
        let source = RecordingManagedPreferences(["forceMasks": .bool(true)])
        let shot = try Screenshot.parse(["--device", "emulator-5554"])
        let video = try VideoMaskOptions.parse([])
        try await ManagedGate.$sourceOverride.withValue(source) {
            #expect(try shot.maskPlan(environment: [:]).secure)
            try await video.confirmUnmasked(command: "record-video", profile: .agent)
            try await video.confirmCheckOff(command: "record-video", environment: [:], profile: .agent)
        }
        #expect(source.keys.isEmpty)
    }

    @Test("allowFileInput false refuses --allow-path on a file --file protects, before anyone is asked, and never touches a plain file")
    func allowFileInput() async throws {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-managed-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("TOKEN=x".utf8).write(to: URL(fileURLWithPath: folder + "/.env"))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: folder + "/text.txt"))
        AllowPathConsent.confirmed = nil
        defer { AllowPathConsent.confirmed = nil }

        let presence = FakePresence()
        let error = await Self.refusal(under: Self.forced(.allowFileInput)) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(presence) { try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: true, command: "type") }
            }
        }
        Self.expectManaged(error, key: "allowFileInput")
        #expect(presence.reasons.isEmpty)
        #expect(AllowPathConsent.confirmed == nil)

        let source = RecordingManagedPreferences(["allowFileInput": .bool(false)])
        try await ManagedGate.$sourceOverride.withValue(source) {
            try await AllowPathConsent.confirm(path: folder + "/text.txt", allowPath: true, command: "type")
            try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: false, command: "type")
        }
        #expect(source.keys.isEmpty)

        let allowed = FakePresence()
        let unforced = await Self.refusal(under: Self.open(.allowFileInput)) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(allowed) { try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: true, command: "type") }
            }
        }
        #expect(unforced == nil)
        #expect(allowed.reasons.count == 1)
    }

    @Test("allowSavedLogins false refuses login and each credential action that saves, before the Keychain is opened")
    func allowSavedLogins() async throws {
        #expect(CredentialCommand.savesLogin == [.set, .describe, .join])
        let commands: [[String]] = [
            ["add", "--app", "com.example.app"],
            ["describe", "--app", "com.example.app", "--about", "a test user"],
            ["join", "--device", "emulator-5554"],
        ]
        for arguments in commands {
            let command = try CredentialCommand.parse(arguments)
            Self.expectManaged(await Self.refusal(under: Self.forced(.allowSavedLogins)) { try await command.run() }, key: "allowSavedLogins")
        }
        let login = try LoginCommand.parse(["--device", "emulator-5554", "--app", "com.example.app"])
        Self.expectManaged(await Self.refusal(under: Self.forced(.allowSavedLogins)) { try await login.run() }, key: "allowSavedLogins")
        Self.expectManaged(
            await Self.refusal(under: FakeManagedPreferences(values: ["allowSavedLogins": .integer(0)])) { try await login.run() }, key: "allowSavedLogins"
        )
    }

    @Test("allowUnlockCodes false refuses unlock-code set and wake --unlock before any device is reached")
    func allowUnlockCodes() async throws {
        let set = try UnlockCodeCommand.parse(["set", "--device", "Offsider_E2E"])
        Self.expectManaged(await Self.refusal(under: Self.forced(.allowUnlockCodes)) { try await set.run() }, key: "allowUnlockCodes")
        let wake = try Wake.parse(["--unlock", "--device", "emulator-5554"])
        Self.expectManaged(await Self.refusal(under: Self.forced(.allowUnlockCodes)) { try await wake.run() }, key: "allowUnlockCodes")
    }

    @Test("allowPhonePermissionChanges false refuses a grant, revoke or reset on a phone; show and virtual devices never read it")
    func allowPhonePermissionChanges() async throws {
        let allowance = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.app"])
        let change = PermissionCommand.Plan.change(.grant, [.service(.camera)], app: "com.example.app", device: PolicyFixtures.serial)
        let error = await Self.refusal(under: Self.forced(.allowPhonePermissionChanges)) { try PermissionCommand.requirePhoneChangesAllowed(change, allowance: allowance) }
        Self.expectManaged(error, key: "allowPhonePermissionChanges")
        #expect(error?.userFacingDescription.contains("Nothing was changed on Test iPhone (\(PolicyFixtures.serial)).") == true)

        let source = RecordingManagedPreferences(["allowPhonePermissionChanges": .bool(false)])
        try ManagedGate.$sourceOverride.withValue(source) {
            try PermissionCommand.requirePhoneChangesAllowed(change, allowance: nil)
            try PermissionCommand.requirePhoneChangesAllowed(.show(app: "com.example.app", device: PolicyFixtures.serial), allowance: allowance)
        }
        #expect(source.keys.isEmpty)
        #expect(await Self.refusal(under: Self.open(.allowPhonePermissionChanges)) { try PermissionCommand.requirePhoneChangesAllowed(change, allowance: allowance) } == nil)
    }

    @Test("allowMetroReverse false sets no adb reverse on a phone and sends adb nothing")
    func allowMetroReverse() async throws {
        let directory = try AndroidMetroReverseTests.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = AndroidMetroReverseTests.server(FakeReverses())
        let backend = AndroidBackend(host: try AndroidMetroReverseTests.host(server, directory: directory)) { _, _ in }

        let error = await ManagedGate.$sourceOverride.withValue(Self.forced(.allowMetroReverse)) {
            await #expect(throws: ExpoDevClientError.self) { try await backend.addMetroReverse(port: 8081, on: AndroidMetroReverseTests.phone) }
        }
        #expect(error?.kind == .managedPolicy)
        #expect(error?.reason == .managedPolicy)
        #expect(error?.message.contains("(allowMetroReverse)") == true)
        #expect(server.services.isEmpty)
        #expect(MetroReverseStore(directory: directory).all().isEmpty)
    }

    @Test("rn open neither sets a reverse nor uses one Offsider set while allowMetroReverse is false")
    func rnOpenHonoursMetroCeiling() async throws {
        let set = await ManagedGate.$sourceOverride.withValue(Self.forced(.allowMetroReverse)) { try? await RNOpenCommandTests.openOnPhone(ports: [8742]) }
        guard case .failure(let refused)? = set?.0 else { Issue.record("a reverse was set although the organisation turns them off"); return }
        Self.expectManaged(refused, key: "allowMetroReverse")
        #expect(set?.1.reversesSet.isEmpty == true && set?.1.openedURLs.isEmpty == true)

        let used = await ManagedGate.$sourceOverride.withValue(Self.forced(.allowMetroReverse)) { try? await RNOpenCommandTests.openWithReverse(ports: [8742], recorded: [8742]) }
        guard case .failure(let stale)? = used else { Issue.record("a reverse Offsider set was used although the organisation turns them off"); return }
        Self.expectManaged(stale, key: "allowMetroReverse")
    }

    @Test("allowRunnerRegistration false refuses --register-device and builds without xcodebuild's provisioning flags")
    func allowRunnerRegistration() async throws {
        let command = try RunnerBuildCommand.parse(["--register-device", "--device", PolicyFixtures.phone])
        let presence = FakePresence()
        let refused = await Self.refusal(under: Self.forced(.allowRunnerRegistration)) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(presence) { try await command.run() }
            }
        }
        Self.expectManaged(refused, key: "allowRunnerRegistration")
        #expect(presence.reasons.isEmpty)

        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        _ = try await ManagedGate.$sourceOverride.withValue(Self.forced(.allowRunnerRegistration)) {
            try await fixture.builder(registerDevice: true).build(for: .device(udid: "U"), deviceName: "iPhone")
        }
        let arguments = try #require(fixture.xcodebuild.calls.first)
        #expect(arguments.contains("DEVELOPMENT_TEAM=\(RunnerProvisioningTests.team)"))
        #expect(!arguments.contains("-allowProvisioningUpdates"))
        #expect(!arguments.contains("-allowProvisioningDeviceRegistration"))
    }

    @Test("with registration off, an unregistered device names Xcode and the administrator, never the command the organisation refuses")
    func unregisteredUnderCeiling() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.status = 65
        fixture.xcodebuild.output = "error: Device \"iPhone\" isn't registered in your developer account. The device must be registered in order to be included in a provisioning profile."
        let error = await ManagedGate.$sourceOverride.withValue(Self.forced(.allowRunnerRegistration)) {
            await #expect(throws: IOSDeviceError.self) { _ = try await fixture.builder().build(for: .device(udid: "U"), deviceName: "iPhone") }
        }
        #expect(error?.reason == .managedPolicy)
        #expect(error?.message.contains("(allowRunnerRegistration)") == true)
        #expect(error?.message.contains("Xcode > Window > Devices and Simulators") == true)
        #expect(error?.message.contains("--register-device") == false)
        #expect(error?.hint == nil)
    }

    @Test("allowedTeamIDs refuses a runner build for a team outside the list, whether the allowance or the variable names it")
    func allowedTeamIDs() async throws {
        let listed = FakeManagedPreferences(values: ["allowedTeamIDs": .strings(["ZYXWV98765"])])
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        for builder in [fixture.builder(), fixture.builder(environment: [:], allowance: RunnerProvisioningTests.allowance())] {
            let error = await ManagedGate.$sourceOverride.withValue(listed) {
                await #expect(throws: IOSDeviceError.self) { _ = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone") }
            }
            #expect(error?.reason == .managedPolicy)
            #expect(error?.message.contains("does not list team \(RunnerProvisioningTests.team) (allowedTeamIDs)") == true)
        }
        #expect(fixture.xcodebuild.calls.isEmpty)
        let status = ManagedGate.$sourceOverride.withValue(listed) { fixture.builder().cacheStatus(udid: "U") }
        guard case .unsettled(let message, let hint)? = status else { Issue.record("doctor's runner build fact hides the managed refusal: \(String(describing: status))"); return }
        #expect(message.contains("(allowedTeamIDs)") && hint == nil)
        _ = try await ManagedGate.$sourceOverride.withValue(listed) {
            try await fixture.builder(environment: [:], allowance: RunnerProvisioningTests.allowance(team: "zyxwv98765")).build(for: .device(udid: "U"), deviceName: "iPhone")
        }
        #expect(fixture.xcodebuild.calls.count == 1)
    }
}

@Suite("Managed ceilings in devices add", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ManagedDeviceAddTests {
    static func managed(_ values: [String: ManagedPreferenceValue]) -> FakeManagedPreferences {
        FakeManagedPreferences(values: values)
    }

    /// Runs `add` under `values`; the error it stops with, and what it saved.
    static func add(
        _ arguments: [String], answers: [String] = ["\r"], values: [String: ManagedPreferenceValue], row: DeviceSummary = DeviceAccessCommandTests.row
    ) async throws -> (error: CLIError?, entries: [DeviceAllowance], reasons: [String]) {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        var failure: CLIError?
        do {
            _ = try await DeviceAccessCommandTests.allow(arguments, answers: answers, context: {
                DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: $0, devices: { [row] }, managed: Self.managed(values))
            }, presence: presence)
        } catch let error as CLIError {
            failure = error
        }
        let entries = FileManager.default.fileExists(atPath: DeviceAccessCommandTests.file(home)) ? try DeviceAccessCommandTests.entries(home) : []
        return (failure, entries, presence.reasons)
    }

    static let app = ["--device", PolicyFixtures.phone, "--app", "com.example.app"]

    @Test("maxAllowanceDays refuses a longer or endless --expires, and saves a default at the cap", arguments: ["never", "8d"])
    func expiryOverCap(expires: String) async throws {
        let result = try await Self.add(Self.app + ["--expires", expires], values: ["maxAllowanceDays": .integer(3)])
        #expect(result.error?.reason == .managedPolicy)
        #expect(result.error?.userFacingDescription.contains("Your organisation limits an allowance to 3 days (maxAllowanceDays). Nothing was saved.") == true)
        #expect(result.entries.isEmpty && result.reasons.isEmpty)
    }

    @Test("under a cap shorter than the default, a one-app allowance is saved at the cap")
    func defaultClampedToCap() async throws {
        let result = try await Self.add(Self.app, values: ["maxAllowanceDays": .integer(3)])
        #expect(result.error == nil)
        #expect(result.entries.map(\.expires) == [PolicyFixtures.now.addingTimeInterval(3 * 86_400)])
        let within = try await Self.add(Self.app + ["--expires", "2d"], values: ["maxAllowanceDays": .integer(3)])
        #expect(within.entries.map(\.expires) == [PolicyFixtures.now.addingTimeInterval(2 * 86_400)])
    }

    @Test("the length menu offers nothing past the cap and never Until removed")
    func expiryMenu() {
        #expect(DeviceAccessAllow.expiryOptions(within: nil).map(\.value) == DeviceAccessAllow.expiryOptions.map(\.value))
        #expect(DeviceAccessAllow.expiryOptions(within: 86_400).map(\.value) == ["2h", "12h", "24h", nil])
        #expect(DeviceAccessAllow.expiryOptions(within: 90 * 86_400).map(\.value) == ["2h", "12h", "24h", "7d", nil])
    }

    @Test("allowedTeamIDs refuses --team outside the list and saves one inside it")
    func teamCeiling() async throws {
        let values: [String: ManagedPreferenceValue] = ["allowedTeamIDs": .strings(["ZYXWV98765"])]
        let refused = try await Self.add(Self.app + ["--team", "ABCDE12345"], values: values)
        #expect(refused.error?.reason == .managedPolicy)
        #expect(refused.error?.userFacingDescription.contains("does not list team ABCDE12345 (allowedTeamIDs)") == true)
        #expect(refused.entries.isEmpty && refused.reasons.isEmpty)
        let saved = try await Self.add(Self.app + ["--team", "ZYXWV98765"], values: values)
        #expect(saved.entries.map(\.team) == ["ZYXWV98765"])
    }

    @Test("allowRunnerRegistration false saves the team but the Touch ID prompt no longer says it registers the device")
    func registrationCeiling() async throws {
        let off = try await Self.add(Self.app + ["--team", "ABCDE12345"], values: ["allowRunnerRegistration": .bool(false)])
        #expect(off.entries.map(\.team) == ["ABCDE12345"])
        #expect(off.reasons.allSatisfy { !$0.contains("register") })
        let on = try await Self.add(Self.app + ["--team", "ABCDE12345"], values: [:])
        #expect(on.reasons.contains { $0.contains("and register it with your Apple team") })
    }

    @Test("allowMetroReverse false refuses --metro-port with a port, and saves none by default")
    func metroCeiling() async throws {
        let phone = ["--device", PolicyFixtures.serial, "--app", "com.example.app"]
        let values: [String: ManagedPreferenceValue] = ["allowMetroReverse": .bool(false)]
        let refused = try await Self.add(phone + ["--metro-port", "8081"], values: values, row: DeviceAccessCommandTests.androidRow)
        #expect(refused.error?.reason == .managedPolicy)
        #expect(refused.error?.userFacingDescription.contains("(allowMetroReverse)") == true)
        #expect(refused.entries.isEmpty)
        let saved = try await Self.add(phone + ["--metro-port", "none"], values: values, row: DeviceAccessCommandTests.androidRow)
        #expect(saved.error == nil && saved.entries.map(\.metroPorts) == [[]])
    }

    @Test("requirePinnedApps refuses a test device, offers no broad row in the app menu and saves a named app")
    func pinsCeiling() async throws {
        let values: [String: ManagedPreferenceValue] = ["requirePinnedApps": .bool(true), "allowTestDevices": .bool(true)]
        let whole = try await Self.add(["--device", PolicyFixtures.phone, "--test-device"], values: values)
        #expect(whole.error?.userFacingDescription.contains("(requirePinnedApps)") == true)
        #expect(whole.entries.isEmpty)

        let policy = PhysicalDevicePolicy(managed: ManagedDevicePolicy.read(from: Self.managed(values)), list: .empty)
        let apps = [InstalledApp(id: "com.example.app", name: "Example")]
        #expect(DeviceAccessAllow.appMenu(apps, platform: .android, policy: policy, profile: nil, front: nil).choices == [.app(apps[0]), .type])
        let open = PhysicalDevicePolicy(managed: .none, list: .empty)
        #expect(DeviceAccessAllow.appMenu(apps, platform: .android, policy: open, profile: nil, front: nil).choices == [.app(apps[0]), .any, .wholeDevice, .type])

        let named = try await Self.add(Self.app, values: values)
        #expect(named.error == nil && named.entries.map(\.apps) == [["com.example.app"]])
    }

    @Test("--plan offers only the teams the organisation lists")
    func planTeams() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let teams = [SigningTeam(id: "ABCDE12345", name: "First"), SigningTeam(id: "ZYXWV98765", name: "Second")]
        let context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), teams: { teams }, managed: Self.managed(["allowedTeamIDs": .strings(["ZYXWV98765"])]))
        let output = try await DeviceAccessAllow.parse(["--plan", "--json"]).planOutput(context: context)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect((json["teams"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["ZYXWV98765"])
    }
}
