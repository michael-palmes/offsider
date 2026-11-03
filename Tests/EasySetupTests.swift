import Foundation
@testable import OffsiderCore
@testable import OffsiderIOSDevice
@testable import Offsider
import Testing

@Suite("devices add --plan")
@MainActor
struct DeviceAddPlanTests {
    static let phone = DeviceAccessCommandTests.row
    static let pixel = DeviceAccessCommandTests.androidRow
    static let wifi = DeviceAccessCommandTests.wifiRow
    static let free = PhysicalDevicePolicy(managed: .none, list: .empty)

    static func plan(_ rows: [DeviceSummary], policy: PhysicalDevicePolicy = free, teams: [DeviceAddPlan.Team] = [.init(id: "ABCDE12345", name: "Example Team")]) -> DeviceAddPlan {
        DeviceAddPlan.make(rows: rows, policy: policy, teams: teams, now: PolicyFixtures.now, app: { $0 == .ios ? "com.example.app" : nil })
    }

    @Test("each phone gets complete commands to paste, with the project's app and nothing left to look up")
    func commands() throws {
        let built = Self.plan([Self.phone, Self.pixel])
        let phone = try #require(built.devices.first)
        #expect(phone.testDeviceCommand == "offsider devices add --device \(PolicyFixtures.phone) --test-device")
        #expect(phone.oneAppCommand == "offsider devices add --device \(PolicyFixtures.phone) --app com.example.app")
        #expect(built.devices[1].oneAppCommand == "offsider devices add --device \(PolicyFixtures.serial)", "no app known, so its menu lists them")
        #expect(built.ask == nil)
        for command in [phone.testDeviceCommand, phone.oneAppCommand].compactMap({ $0 }) {
            #expect(!command.contains("<"))
            #expect(try DeviceAccessAllow.parse(Array(command.split(separator: " ").dropFirst(3).map(String.init))).device == PolicyFixtures.phone)
        }
    }

    @Test("a phone on Wi-Fi gets a step and no command, since add refuses it")
    func wifiHasNoCommand() throws {
        let entry = try #require(Self.plan([Self.wifi]).devices.first)
        #expect(entry.ask?.hasPrefix("Can you connect") == true)
        #expect(entry.testDeviceCommand == nil && entry.oneAppCommand == nil)
    }

    @Test("managed policy that forbids test devices leaves out only that command")
    func managedOff() throws {
        let policy = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowPhysicalDevices: true), list: .empty)
        let entry = try #require(Self.plan([Self.phone], policy: policy).devices.first)
        #expect(entry.testDeviceCommand == nil)
        #expect(entry.oneAppCommand != nil)
    }

    @Test("nothing plugged in, or no team for an iPhone, says what to do; an Android phone needs no team")
    func deadEnds() {
        #expect(Self.plan([]).ask == DeviceAddPlan.noDeviceAsk)
        #expect(Self.plan([Self.phone], teams: []).ask == DeviceAddPlan.noTeamAsk)
        #expect(Self.plan([Self.pixel], teams: []).ask == nil)
    }

    @Test("a phone already allowed says so, as a test device or not")
    func alreadyAllowed() throws {
        let entry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], testDevice: true)
        let built = Self.plan([Self.phone], policy: PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry])))
        #expect(built.devices[0].allowed && built.devices[0].testDevice)
        #expect(built.text().contains("(already allowed, test device)"))
        #expect(built.json().contains(#""testDevice":true"#))
        #expect(built.json().contains(#""untrusted":["devices[0].name","teams[0].name"]"#), "a device names itself, so its name is data")
    }

    @Test("--plan reads no phone, needs no terminal and takes no other flag")
    func readsNoPhone() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var context = DeviceAccessCommandTests.context(
            home: home, seal: MemorySeal(), teams: { [SigningTeam(id: "ABCDE12345", name: "Example Team")] },
            apps: { _ in Issue.record("--plan read the phone's apps"); return [] }
        )
        context.frontApp = { _ in Issue.record("--plan read the phone's front app"); return nil }
        context.prepare = { _ in Issue.record("--plan started the runner"); return false }
        let output = try await PersonPresence.$terminal.withValue({ false }) {
            try await DeviceAccessAllow.parse(["--plan", "--json"]).planOutput(context: context)
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect((object["devices"] as? [[String: Any]])?.count == 1)
        #expect((object["teams"] as? [[String: Any]])?.first?["name"] as? String == "Example Team")
        #expect(!FileManager.default.fileExists(atPath: DeviceAccessCommandTests.file(home)))
        #expect(throws: (any Error).self) { try DeviceAccessAllow.parse(["--plan", "--test-device"]) }
    }

    @Test("a phone waiting on someone's hands asks for the step by name, never for its status", arguments: ["Untrusted", "Unauthorised", "Developer Mode off", "Unavailable"])
    func asksByName(state: String) throws {
        let row = DeviceSummary(id: PolicyFixtures.phone, platform: .ios, state: state, name: "Test iPhone", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
        let ask = try #require(DeviceSetupAsk.ask(row))
        #expect(ask.hasPrefix("Can you") && ask.contains("Test iPhone"))
    }
}

@Suite("devices add asks only what it cannot work out", .serialized)
@MainActor
struct EasyAddTests {
    static let team = SigningTeam(id: "ABCDE12345", name: "Example Team")

    /// A context with one phone and one team, whose fake `prepare` records what ran.
    static func context(home: String, terminal: AccessTerminal, row: DeviceSummary = DeviceAccessCommandTests.row, prepare: @escaping @Sendable @MainActor (DeviceSummary) async throws -> Bool = { _ in true }) -> DeviceAccessContext {
        var context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { [row] }, teams: { [Self.team] })
        context.prepare = prepare
        return context
    }

    @Test("--test-device on the only phone with one team shows no menu at all, lasts until removed, names the reach in Touch ID and proves it")
    func oneCommandOneTouch() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        let (output, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: { Self.context(home: home, terminal: $0) }, presence: presence)
        let entry = try #require(try DeviceAccessCommandTests.entries(home).first)
        #expect(entry.testDevice && entry.expires == nil && entry.team == "ABCDE12345")
        #expect(presence.reasons == ["allow Offsider to drive Test iPhone (\(PolicyFixtures.phone)) as a test device, whole device with nothing personal on it and register it with your Apple team"])
        for question in [AllowScreen.deviceQuestion, AllowScreen.useQuestion, AllowScreen.teamQuestion, AllowScreen.appQuestion, AllowScreen.expiryQuestion] {
            #expect(!transcript.contains(question))
        }
        #expect(output.contains("Ready: Test iPhone until you remove it, test device, whole device."))
        #expect(!output.contains("Next "), "nothing is left to run")
    }

    @Test("--app settles the rest: 7 days and no Metro, with no question on a phone")
    func appFlagSettles() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (_, transcript) = try await DeviceAccessCommandTests.allow(["--app", "com.example.app"], answers: [], context: {
            Self.context(home: home, terminal: $0, row: DeviceAccessCommandTests.androidRow)
        })
        let entry = try #require(try DeviceAccessCommandTests.entries(home).first)
        #expect(entry.apps == ["com.example.app"] && entry.metroPorts.isEmpty)
        #expect(entry.expires == PolicyFixtures.now.addingTimeInterval(7 * 86_400))
        #expect(!transcript.contains(AllowScreen.metroQuestion) && !transcript.contains(AllowScreen.expiryQuestion))
    }

    @Test("two teams still ask, naming neither silently")
    func twoTeamsAsk() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (_, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: ["2"], context: { terminal in
            var context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal, teams: { [Self.team, SigningTeam(id: "ZYXWV54321", name: "Other Team")] })
            context.prepare = { _ in true }
            return context
        })
        #expect(transcript.contains(AllowScreen.teamQuestion))
        #expect(try DeviceAccessCommandTests.entries(home).first?.team == "ZYXWV54321")
    }

    @Test("the use question starts on One app, and Return on 'Anything personal?' saves nothing and asks no Touch ID")
    func useStartsSafe() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        await #expect(throws: (any Error).self) {
            _ = try await DeviceAccessCommandTests.allow([], answers: ["2", "\r"], context: { Self.context(home: home, terminal: $0) }, presence: presence)
        }
        #expect(presence.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DeviceAccessCommandTests.file(home)))
    }

    @Test("a phone that needs its Trust tapped gets the ask, then add carries on by itself once its row clears, asking nothing before")
    func watchesTheRow() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let scans = CallCounter()
        let waiting = DeviceSummary(id: PolicyFixtures.phone, platform: .ios, state: "Untrusted", name: "Test iPhone", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
        let (_, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: { terminal in
            var context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal, devices: { scans.tick() < 2 ? [waiting] : [DeviceAccessCommandTests.row] }, teams: { [Self.team] })
            context.prepare = { _ in true }
            return context
        })
        #expect(transcript.contains("Can you unlock Test iPhone and tap Trust?"))
        #expect(try DeviceAccessCommandTests.entries(home).count == 1)
    }

    @Test("an iPhone listed with Developer Mode off is not watched, as that row may only mean locked, so add carries on to prove it")
    func developerModeRowNotWatched() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            Self.context(home: home, terminal: $0, row: DeviceAccessCommandTests.developerModeOffRow)
        })
        #expect(!transcript.contains("Can you turn on Developer Mode"))
        #expect(output.contains("Ready: Test iPhone"))
    }

    @Test("a step only a person can clear is retried until it clears, and the failure never reaches the screen as an error")
    func retriesWhatAPersonClears() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let attempts = CallCounter()
        let (output, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            Self.context(home: home, terminal: $0) { _ in
                if attempts.tick() == 0 { throw IOSDeviceError(.certificateNotTrusted, "Test iPhone does not trust the signing certificate. Trust it in Settings > General > VPN & Device Management.") }
                return true
            }
        })
        #expect(attempts.count == 2)
        #expect(transcript.contains("VPN & Device Management"))
        #expect(output.contains("Ready: Test iPhone"))
    }

    @Test("a failure no one can clear on the phone keeps the allowance, says what stopped it, and never claims it is ready")
    func hardFailureKeepsDevice() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, _) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            Self.context(home: home, terminal: $0) { _ in throw IOSDeviceError(.runnerBuildFailed, "The runner did not build. See its log.") }
        })
        #expect(try DeviceAccessCommandTests.entries(home).count == 1)
        #expect(output.contains("Allowed Test iPhone") && !output.contains("Ready:"))
        #expect(output.contains("The runner did not build"))
    }

    @Test("--json reports whether it is ready and what it needs")
    func jsonReportsSetup() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, _) = try await DeviceAccessCommandTests.allow(["--test-device", "--json"], answers: [], context: {
            Self.context(home: home, terminal: $0) { _ in throw IOSDeviceError(.runnerBuildFailed, "The runner did not build.") }
        })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["ready"] as? Bool == false)
        #expect(object["needs"] as? String == "The runner did not build.")
    }

    @Test("Android stays honest: no proof, so it says Allowed and names doctor")
    func androidNotClaimedReady() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (output, _) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: [], context: {
            Self.context(home: home, terminal: $0, row: DeviceAccessCommandTests.androidRow) { _ in false }
        })
        #expect(output.contains("Allowed Test Pixel") && output.contains("offsider doctor --device"))
    }

    // MARK: The login offer

    @Test("Return skips the login, and the device stays")
    func loginSkippedByDefault() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = MemoryLoginCredentialStore()
        let (_, transcript) = try await DeviceAccessCommandTests.allow(["--test-device"], answers: ["\r"], context: { terminal in
            var context = Self.context(home: home, terminal: terminal)
            context.credentials = store
            return context
        })
        #expect(transcript.contains(AllowScreen.loginQuestion))
        #expect(try store.groups().isEmpty)
        #expect(try DeviceAccessCommandTests.entries(home).count == 1)
    }

    @Test("a one-app phone saves the login for that app, for phones, in the same Touch ID")
    func loginForPinnedApp() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = MemoryLoginCredentialStore()
        let presence = RecordingPresence()
        _ = try await DeviceAccessCommandTests.allow(["--app", "com.example.app"], answers: ["2", "qa@example.com\r", "pw-1234\r", "pw-1234\r", "\r"], context: { terminal in
            var context = Self.context(home: home, terminal: terminal)
            context.credentials = store
            return context
        }, presence: presence)
        let saved = try store.loadStored(app: "com.example.app", key: LoginCredential.defaultAccountKey)
        #expect(saved?.credential.username == "qa@example.com")
        #expect(saved?.devices == .any)
        #expect(presence.reasons.count == 1)
    }

    @Test("a test device saves a plain login, which works there anyway; Escape during the login keeps the device")
    func loginOnTestDevice() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = MemoryLoginCredentialStore()
        let apps = [InstalledApp(id: "com.example.app", name: "Example")]
        _ = try await DeviceAccessCommandTests.allow(["--test-device"], answers: ["2", "1", "qa@example.com\r", "pw-1234\r", "pw-1234\r", "\r"], context: { terminal in
            var context = DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal, teams: { [Self.team] }, apps: { _ in apps })
            context.credentials = store
            context.prepare = { _ in true }
            return context
        })
        #expect(try store.loadStored(app: "com.example.app", key: LoginCredential.defaultAccountKey)?.devices == .virtual)

        let other = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: other) }
        let empty = MemoryLoginCredentialStore()
        _ = try await DeviceAccessCommandTests.allow(["--test-device"], answers: ["2", "\u{1B}"], context: { terminal in
            var context = DeviceAccessCommandTests.context(home: other, seal: MemorySeal(), terminal: terminal, teams: { [Self.team] }, apps: { _ in apps })
            context.credentials = empty
            context.prepare = { _ in true }
            return context
        })
        #expect(try empty.groups().isEmpty)
        #expect(try DeviceAccessCommandTests.entries(other).count == 1)
    }
}

@Suite("login on a real iPhone")
@MainActor
struct IOSLoginTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let pixel = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    static func stored(_ devices: LoginDeviceScope) -> StoredLogin {
        StoredLogin(credential: LoginCredential(username: "qa", password: "pw")!, confirm: devices == .any, devices: devices)
    }

    @Test("a login saved for simulators is refused on an added iPhone or Android phone and types nothing, naming the one command")
    func scopeRefused() {
        for device in [Self.phone, Self.pixel] {
            let error = #expect(throws: CLIError.self) { try LoginCommand.requireDeviceScope(Self.stored(.virtual), key: "qa", app: "com.example.app", device: device) }
            #expect(error?.hint == "offsider credential describe qa --devices any --app com.example.app")
        }
    }

    @Test("on a test device any saved login signs in, and on a simulator scope never applies")
    func scopeFreeOnTestDevice() throws {
        try LoginCommand.requireDeviceScope(Self.stored(.virtual), key: "qa", app: "com.example.app", device: Self.phone, wholeDevice: true)
        try LoginCommand.requireDeviceScope(Self.stored(.virtual), key: "qa", app: "com.example.app", device: Self.pixel, wholeDevice: true)
        try LoginCommand.requireDeviceScope(Self.stored(.virtual), key: "qa", app: "com.example.app", device: Self.simulator)
        try LoginCommand.requireDeviceScope(Self.stored(.any), key: "qa", app: "com.example.app", device: Self.phone)
    }

    @Test("a test device signs in with no Touch ID, even for a login saved to confirm; another added phone asks first")
    func touchIDOnlyOffTestDevices() async throws {
        let store = MemoryLoginCredentialStore()
        try store.saveStored(Self.stored(.any), app: "com.example.app", key: "dev", isDefault: true, context: nil)
        let node = UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes(package: "com.example.app")))
        func attempt(whole: Bool) async -> (reasons: [String], error: (any Error)?) {
            let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: Self.pixel.rawValue, roots: [node])])
            let presence = RecordingPresence()
            do {
                try await PersonPresence.$current.withValue(presence) {
                    _ = try await LoginCommand.perform(
                        on: DeviceRouter.Route(backend: backend, device: Self.pixel), profile: nil, key: "dev", timeout: 5, logger: OffsiderLogger(), store: store, wholeDevice: whole
                    )
                }
                return (presence.reasons, nil)
            } catch {
                return (presence.reasons, error)
            }
        }
        let test = await attempt(whole: true)
        #expect(test.reasons.isEmpty)
        #expect((test.error as? CLIError)?.reason == .selectorNotFound, "past every gate, at the form check")
        let phone = await attempt(whole: false)
        #expect(phone.reasons.count == 1)
    }

    @Test("the app in front comes from the runner's root on a device, with no process to look up")
    func frontFromRunner() throws {
        let tree = try IOSDeviceBackend.tree(fromSnapshot: Data(#"[{"type":"Application","pid":77,"bundleId":"com.example.app","children":[]}]"#.utf8), device: IOSDeviceFixtures.phone)
        #expect(try ForegroundApp.identifier(in: tree, pathForPID: { _ in Issue.record("looked up a phone's pid on the Mac"); return nil }) == "com.example.app")
    }
}

@Suite("iPhone sign-in types only as keys")
@MainActor
struct KeysOnlyTypingTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    static func session(touch: Bool, link: FakeSessionLink, text: RecordingRunnerText) -> IOSDeviceInputSession {
        IOSDeviceInputSession(
            device: phone,
            session: {
                guard touch else { throw IOSDeviceError(.sessionFailed, "No broker.") }
                let client = DeviceSessionClient(udid: IOSDeviceFixtures.phone, link: link)
                try await client.ping()
                return client
            },
            runner: { RecordingRunnerSession(device: phone) }, runnerText: text
        )
    }

    @Test("replace selects all, deletes and types through the session; the runner, whose log can hold text, sees nothing")
    func secretsAvoidRunner() async throws {
        let link = FakeSessionLink.broker(udid: IOSDeviceFixtures.phone)
        let text = RecordingRunnerText()
        let session = Self.session(touch: true, link: link, text: text)
        try await InputSecrecy.$keysOnly.withValue(true) { try await session.replaceText("pw") }
        #expect(text.calls.isEmpty)
        let keys = link.requests.compactMap { request -> [DeviceSessionStep]? in
            if case .keys(let steps) = request { return steps }
            return nil
        }
        #expect(keys.first == IOSDeviceInputSession.selectAllAndDelete)
        #expect(keys.count == 2, "the clear, then the text")
    }

    @Test("without the session it refuses and types nothing, never falling back to the runner", arguments: ["pw", "pässwörd"])
    func refusesWithoutKeys(secret: String) async throws {
        let text = RecordingRunnerText()
        let session = Self.session(touch: false, link: FakeSessionLink.broker(udid: IOSDeviceFixtures.phone), text: text)
        let error = await #expect(throws: IOSDeviceError.self) {
            try await InputSecrecy.$keysOnly.withValue(true) { try await session.replaceText(secret) }
        }
        #expect(text.calls.isEmpty)
        #expect(error?.message.contains(secret) == false, "the error never holds the text")
    }

    @Test("a character the keys cannot type is refused in plain words, even with the session up")
    func refusesOtherCharacters() async throws {
        let text = RecordingRunnerText()
        let session = Self.session(touch: true, link: FakeSessionLink.broker(udid: IOSDeviceFixtures.phone), text: text)
        let error = await #expect(throws: IOSDeviceError.self) {
            try await InputSecrecy.$keysOnly.withValue(true) { try await session.typeText("pässwörd") }
        }
        #expect(text.calls.isEmpty)
        #expect(error?.message.contains("cannot type") == true)
    }

    @Test("the runner refuses text itself during a sign-in, so no session that falls back to it can log a password")
    func runnerRefusesAtTheSource() async throws {
        let transport = FakeRunnerTransport()
        let client = RunnerClient(udid: IOSDeviceFixtures.phone, token: "t", transport: transport)
        let error = await #expect(throws: IOSDeviceError.self) {
            try await InputSecrecy.$keysOnly.withValue(true) { try await client.type("hunter2", replace: true, app: nil) }
        }
        #expect(transport.calls.isEmpty)
        #expect(error?.message.contains("hunter2") == false)
    }

    @Test("ordinary typing still takes the runner for what keys cannot send")
    func ordinaryTypingUnchanged() async throws {
        let text = RecordingRunnerText()
        let session = Self.session(touch: true, link: FakeSessionLink.broker(udid: IOSDeviceFixtures.phone), text: text)
        try await session.replaceText("ab")
        try await session.typeText("café")
        #expect(text.calls == ["replace 2", "type 4"])
    }
}
