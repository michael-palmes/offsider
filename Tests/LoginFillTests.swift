import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// The password step of a sign-up form: password and confirm fields, a show-password switch and a button that `--fill` never taps.
private enum SignUp {
    static let password = "s3cret-token"
    static let username = "ada@example.com"
    static let bullets = String(repeating: "•", count: password.count)

    static func field(_ role: UIRole = .secureTextField, id: String, label: String, value: String? = nil, y: Double, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(role, id: id, label: label, value: value, frame: FakeUI.frame(20, y, 300, 44), platform: platform)
    }

    static func toggle(on: Bool, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.switch, id: "signup-show-password", label: "Show password", value: on ? "1" : "0", frame: FakeUI.frame(20, 300, 300, 32), platform: platform)
    }

    static let create = FakeUI.node(.button, id: "signup-create", label: "Create account", frame: FakeUI.frame(20, 360, 300, 44))

    static func screen(password: String? = nil, confirm: String? = nil, toggleOn: Bool = false, platform: DevicePlatform = .ios, extra: [UINode] = []) -> UITree {
        FakeUI.tree(platform: platform, [
            field(id: "signup-password", label: "Password", value: password, y: 160, platform: platform),
            field(id: "signup-confirm", label: "Confirm password", value: confirm, y: 220, platform: platform),
            toggle(on: toggleOn, platform: platform),
            create,
        ] + extra)
    }

    static let emailStep = FakeUI.tree([
        field(.textField, id: "signup-email", label: "Email", y: 160),
        FakeUI.node(.button, id: "signup-next", label: "Next", frame: FakeUI.frame(20, 240, 300, 44)),
    ])
}

@Suite("login --fill field rules")
struct LoginFillFieldTests {
    private func refusal(_ body: () throws -> [UINode]) -> LoginFillRefusal? {
        #expect(throws: LoginFillRefusal.self) { try body() }
    }

    @Test("the password step's two empty password fields are chosen top to bottom, never the button or the switch")
    func passwordAndConfirm() throws {
        let fields = try LoginFill.fields(.password, in: SignUp.screen(), intoID: nil, replace: false)
        #expect(fields.map(\.id) == ["signup-password", "signup-confirm"])
    }

    @Test("a text field anyone can read is refused, named or found, so the password never shows")
    func visibleField() {
        let tree = FakeUI.tree([SignUp.field(.textField, id: "signup-password", label: "Password", y: 160)])
        let named = refusal { try LoginFill.fields(.password, in: tree, intoID: "signup-password", replace: false) }
        #expect(named?.kind == .visible)
        #expect(named?.message.contains("not a password field") == true)
        let found = refusal { try LoginFill.fields(.password, in: tree, intoID: nil, replace: false) }
        #expect(found?.kind == .visible)
    }

    @Test("a third password field in front is refused until --into-id names one")
    func thirdField() throws {
        let tree = SignUp.screen(extra: [SignUp.field(id: "signup-current", label: "Current password", y: 100)])
        let refused = refusal { try LoginFill.fields(.password, in: tree, intoID: nil, replace: false) }
        #expect(refused?.kind == .tooMany)
        #expect(refused?.message.contains("3 password fields are in front") == true)
        #expect(refused?.message.contains("Name one with --into-id.") == true)
        #expect(try LoginFill.fields(.password, in: tree, intoID: "signup-confirm", replace: false).map(\.id) == ["signup-confirm"])
    }

    @Test("a show-password switch that is on, a Hide password button, or a field the tree cache saw as a password field is a refusal")
    func revealed() throws {
        #expect(refusal { try LoginFill.fields(.password, in: SignUp.screen(toggleOn: true), intoID: nil, replace: false) }?.kind == .revealed)
        #expect(refusal { try LoginFill.fields(.password, in: SignUp.screen(toggleOn: true), intoID: "signup-confirm", replace: false) }?.kind == .revealed)

        let hide = FakeUI.node(.button, id: "eye", label: "Hide password", frame: FakeUI.frame(330, 160, 44, 44))
        #expect(refusal { try LoginFill.fields(.password, in: SignUp.screen(extra: [hide]), intoID: nil, replace: false) }?.kind == .revealed)

        let shown = FakeUI.tree([
            SignUp.field(id: "signup-password", label: "Password", y: 160),
            SignUp.field(.textField, id: "signup-confirm", label: "Confirm", y: 220),
        ])
        let record = SecureFieldRecord(platform: .ios, device: "fake-device", writtenAt: Date(), bootMarker: nil, entries: [.init(id: "signup-confirm", frame: nil)])
        let refused = refusal { try LoginFill.fields(.password, in: shown, intoID: "signup-password", replace: false, revealed: RevealedSecrets(record)) }
        #expect(refused?.kind == .revealed)
    }

    @Test("an Android password field that shows plain text is refused; its hint, and iOS's placeholder, count as empty")
    func plainTextInSecureField() throws {
        let plain = FakeUI.tree(platform: .android, [SignUp.field(id: "signup-password", label: "Password", value: "hunter2", y: 160, platform: .android)])
        #expect(refusal { try LoginFill.fields(.password, in: plain, intoID: nil, replace: true) }?.kind == .revealed)

        var hinted = SignUp.field(id: "signup-password", label: "Password", value: "At least 8 characters", y: 160, platform: .android)
        hinted.native = .android(AndroidNativeAttributes(resourceId: "signup-password", hint: "At least 8 characters"))
        #expect(try LoginFill.fields(.password, in: FakeUI.tree(platform: .android, [hinted]), intoID: nil, replace: false).count == 1)

        let placeholder = FakeUI.tree([SignUp.field(id: "signup-password", label: "Password", value: "Password", y: 160)])
        #expect(try LoginFill.fields(.password, in: placeholder, intoID: nil, replace: false).count == 1)
    }

    @Test("an Android field that already holds bullets is refused without --replace, and typed over with it; iOS bullets may be the placeholder")
    func holdsText() throws {
        let simulator = FakeUI.tree([SignUp.field(id: "signup-password", label: "Password", value: "••••••••", y: 160)])
        #expect(try LoginFill.fields(.password, in: simulator, intoID: nil, replace: false).count == 1)
        var runner = SignUp.screen(password: SignUp.bullets)
        runner.roots[0].native = .ios(IOSNativeAttributes(bundleID: "com.example.app"))
        #expect(refusal { try LoginFill.fields(.password, in: runner, intoID: nil, replace: false) }?.kind == .holdsText)
        let tree = SignUp.screen(password: SignUp.bullets, platform: .android)
        let refused = refusal { try LoginFill.fields(.password, in: tree, intoID: nil, replace: false) }
        #expect(refused?.kind == .holdsText)
        #expect(refused?.message.contains("Pass --replace") == true)
        #expect(try LoginFill.fields(.password, in: tree, intoID: nil, replace: true).count == 2)
    }

    @Test("--replace types over bullets only: every other refusal stands")
    func replaceNeverLoosens() {
        let visible = FakeUI.tree([SignUp.field(.textField, id: "signup-password", label: "Password", y: 160)])
        #expect(refusal { try LoginFill.fields(.password, in: visible, intoID: "signup-password", replace: true) }?.kind == .visible)
        #expect(refusal { try LoginFill.fields(.password, in: SignUp.screen(toggleOn: true), intoID: nil, replace: true) }?.kind == .revealed)
        let three = SignUp.screen(extra: [SignUp.field(id: "signup-current", label: "Current password", y: 100)])
        #expect(refusal { try LoginFill.fields(.password, in: three, intoID: nil, replace: true) }?.kind == .tooMany)
        let unnamed = FakeUI.tree(platform: .android, [FakeUI.node(.secureTextField, value: "••••", frame: FakeUI.frame(20, 160, 300, 44), platform: .android)])
        #expect(refusal { try LoginFill.fields(.password, in: unnamed, intoID: nil, replace: true) }?.kind == .unnamed)
    }

    @Test("a field whose kind the screen does not say, or with no id or label, types nothing")
    func unreadableOrUnnamed() {
        let other = FakeUI.tree([FakeUI.node(.text, id: "signup-password", label: "Password", frame: FakeUI.frame(20, 160, 300, 44))])
        #expect(refusal { try LoginFill.fields(.password, in: other, intoID: "signup-password", replace: false) }?.kind == .unreadable)
        let unnamed = FakeUI.tree([FakeUI.node(.secureTextField, frame: FakeUI.frame(20, 160, 300, 44))])
        #expect(refusal { try LoginFill.fields(.password, in: unnamed, intoID: nil, replace: false) }?.kind == .unnamed)
    }

    @Test("a password field under a cover is not in front, so nothing is typed")
    func covered() {
        let sheet = FakeUI.node(.button, id: "promo-sheet", label: "Join the beta", frame: FakeUI.frame(0, 100, 402, 774))
        let tree = UITree(platform: .ios, device: "fake-device", roots: [
            FakeUI.node(.application, label: "Playground", frame: FakeUI.frame(0, 0, 402, 874), children: [SignUp.field(id: "signup-password", label: "Password", y: 160), sheet]),
        ])
        #expect(refusal { try LoginFill.fields(.password, in: tree, intoID: nil, replace: false) }?.kind == .missing)
    }

    @Test("identity fills the one email field, refuses a password field and asks for --into-id between two")
    func identity() {
        #expect((try? LoginFill.fields(.identity, in: SignUp.emailStep, intoID: nil, replace: false))?.map(\.id) == ["signup-email"])
        #expect(refusal { try LoginFill.fields(.identity, in: SignUp.screen(), intoID: "signup-password", replace: false) }?.kind == .visible)
        let two = FakeUI.tree([SignUp.field(.textField, id: "email", label: "Email", y: 100), SignUp.field(.textField, id: "backup-email", label: "Backup email", y: 160)])
        #expect(refusal { try LoginFill.fields(.identity, in: two, intoID: nil, replace: false) }?.kind == .ambiguous)
    }

    @Test("the report names the login and each field, never the secret or its length")
    func reportHidesTheSecret() {
        var report = LoginFillReport(app: "com.example.app", key: "dev", target: .password, fields: [
            LoginFillField(name: "id=signup-password", progress: .filled), LoginFillField(name: "id=signup-confirm"),
        ])
        report.savePrompt = .declined
        let json = report.jsonLine()
        #expect(json.contains(#""fill":"password""#))
        #expect(json.contains(#""fields":[{"field":"id=signup-password","state":"filled"},{"field":"id=signup-confirm","state":"not_filled"}]"#))
        #expect(json.contains(#""submitted":false"#))
        #expect(!json.contains(SignUp.password) && !json.contains("\(SignUp.password.count)"))
        #expect(report.textLine() == "com.example.app as dev: typed the saved password into id=signup-password. Nothing was submitted. Offsider declined the system's save-password prompt.")
        #expect(report.progressNote == "id=signup-password was filled.")
    }

    @Test("an evidence run's timeline shows each field's outcome")
    func timelineNote() {
        let line = RunManifestLine(command: "login", device: "fake-device", time: Date(timeIntervalSince1970: 0), ms: 900, exit: 1, reason: "foreground_changed", fields: [
            RunFieldOutcome(field: "id=signup-password", state: "filled"), RunFieldOutcome(field: "id=signup-confirm", state: "not_filled"),
        ])
        let timeline = RunTimeline(dir: "/tmp/run", state: RunState(label: nil, startedAt: Date(timeIntervalSince1970: 0)), entries: [line], unrecorded: [])
        let text = timeline.text(now: Date(timeIntervalSince1970: 1), timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.contains("login fake-device exit 1 foreground_changed (id=signup-password filled, id=signup-confirm not filled)"))
        #expect(line.jsonLine().contains(#""fields":[{"field":"id=signup-password","state":"filled"}"#))
    }
}

/// Scripted screens for `LoginFlow.fill`: each type call moves to the next tree.
@MainActor
private final class FillScript {
    var trees: [UITree]
    var index = 0
    var typed: [String] = []
    var secrecy: [Bool] = []
    var taps: [UIPoint] = []
    var foregrounds = ["com.example.app"]
    var foregroundIndex = 0
    var recordingAt: Int?
    var recordingChecks = 0
    var prompt: SavePrompt?
    var time: TimeInterval = 0
    /// How long after a type call its screen takes to show; until then the screen before it shows.
    var drawLag: TimeInterval?
    var typedAt: TimeInterval?
    var reads = 0
    var readsSinceType = 0
    /// A screen to show instead, given how many reads came since the last type call; nil keeps the script's own.
    var instead: ((_ readsSinceType: Int) -> UITree?)?

    init(_ trees: [UITree]) {
        self.trees = trees
    }

    var services: LoginFlow.Services {
        LoginFlow.Services(
            readTree: {
                self.reads += 1
                self.readsSinceType += 1
                if let shown = self.instead?(self.readsSinceType) { return shown }
                if let lag = self.drawLag, let typedAt = self.typedAt, self.time < typedAt + lag, self.index > 0 { return self.trees[self.index - 1] }
                return self.trees[min(self.index, self.trees.count - 1)]
            },
            typeText: { text, _ in
                self.typedAt = self.time
                self.readsSinceType = 0
                self.typed.append(text)
                self.secrecy.append(InputSecrecy.isSecret)
                if self.index + 1 < self.trees.count { self.index += 1 }
            },
            tap: { point, _ in
                self.taps.append(point)
                if point == self.prompt?.decline { self.prompt = nil }
            },
            readTurnstile: { _ in .absent },
            clock: PollClock(now: { self.time }, sleep: { duration in self.time += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }),
            foregroundApp: { _ in
                let app = self.foregrounds[min(self.foregroundIndex, self.foregrounds.count - 1)]
                self.foregroundIndex += 1
                return app
            },
            savePrompt: { _ in self.typed.count == 2 ? self.prompt : nil },
            refuseRecording: {
                self.recordingChecks += 1
                if let at = self.recordingAt, self.recordingChecks >= at {
                    try RecordingMarker.refuseTyping("a password", command: "login", on: DeviceID(rawValue: "fake-device", platform: .ios), recordingLive: { _ in true }, recorders: { _ in [] })
                }
            }
        )
    }

    func fill(_ target: LoginFillTarget = .password, intoID: String? = nil, replace: Bool = false, profile: LoginProfile? = nil, webLogin: Bool = false) async throws -> LoginFillReport {
        let credential = try #require(LoginCredential(username: SignUp.username, password: SignUp.password))
        return try await LoginFlow.fill(
            target, app: "com.example.app", key: "dev", credential: credential, profile: profile, webLogin: webLogin, intoID: intoID, replace: replace, services: services
        )
    }
}

@MainActor
@Suite("login --fill flow")
struct LoginFillFlowTests {
    @Test("the password goes into password and confirm, as a secret, with no tap and no Return")
    func fillsBoth() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets), SignUp.screen(password: SignUp.bullets, confirm: SignUp.bullets)])
        let report = try await script.fill()
        #expect(script.typed == [SignUp.password, SignUp.password])
        #expect(script.secrecy == [true, true])
        #expect(script.taps.isEmpty)
        #expect(!script.typed.contains { $0.hasSuffix("\n") })
        #expect(report.filled.map(\.name) == ["id=signup-password", "id=signup-confirm"])
    }

    @Test("another app in front before the confirm field stops with foreground_changed after one field")
    func appChangesBetweenFields() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets)])
        script.foregrounds = ["com.example.app", "com.example.app", "com.example.other"]
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .foregroundChanged)
        #expect(script.typed.count == 1)
        #expect(stopped.report.fields.map(\.progress) == [.filled, .notFilled])
        #expect(stopped.failureMessage.contains("com.example.other is in front now, not com.example.app, so id=signup-confirm was not filled."))
        #expect(stopped.failureMessage.hasSuffix("id=signup-password was filled."))
    }

    @Test("a recording that starts after the first field stops the confirm field with device_busy")
    func recordingStartsMidCommand() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets)])
        script.recordingAt = 2
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .deviceBusy)
        #expect(script.typed.count == 1)
    }

    @Test("a show-password switch turned on after the first field stops before the confirm field")
    func revealedBetweenFields() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets, toggleOn: true)])
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .secretWouldShow)
        #expect(script.typed.count == 1)
    }

    @Test("a field still drawing its bullets gets a clocked wait, then one verdict")
    func stillDrawing() async throws {
        let filled = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets), SignUp.screen(password: SignUp.bullets, confirm: SignUp.bullets)])
        filled.drawLag = 1
        _ = try await filled.fill()
        #expect(filled.typed.count == 2)

        let slow = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets)])
        slow.drawLag = 5
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await slow.fill() })
        #expect(stopped.reason == .textNotAccepted)
        #expect(slow.time >= LoginFlow.keyboardSettle && slow.time < LoginFlow.keyboardSettle + 0.5)
        #expect(slow.typed.count == 1)
    }

    @Test("a filled field that now shows its text stops the fill before the next field")
    func filledFieldRevealed() async throws {
        let shown = FakeUI.tree([
            SignUp.field(.textField, id: "signup-password", label: "Password", value: SignUp.password, y: 160),
            SignUp.field(id: "signup-confirm", label: "Confirm password", y: 220),
            SignUp.create,
        ])
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets)])
        script.instead = { reads in script.typed.count == 1 && reads > 1 ? shown : nil }
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .secretWouldShow)
        #expect(stopped.failureMessage.contains("id=signup-password, already filled, now shows its text"))
        #expect(script.typed.count == 1)
        #expect(stopped.report.fields.map(\.progress) == [.filled, .notFilled])
    }

    @Test("a field that does not show one bullet per character stops with text_not_accepted; the value is never compared")
    func bulletCount() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: "•••")])
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .textNotAccepted)
        #expect(stopped.report.filled.isEmpty)
        #expect(!stopped.failureMessage.contains("\(SignUp.password.count)"))
    }

    @Test("a password field inside a web view types nothing unless the project file and the saved login both opt in")
    func webView() async throws {
        var web = FakeUI.node(.other, frame: FakeUI.frame(0, 100, 402, 400), children: [SignUp.field(id: "signup-password", label: "Password", y: 160)])
        web.native = .ios(IOSNativeAttributes(type: "WebView"))
        let tree = FakeUI.tree([web])
        let refused = FillScript([tree])
        let error = try #require(await #expect(throws: CLIError.self) { try await refused.fill(webLogin: true) })
        #expect(error.reason == .appNotAllowed)
        #expect(refused.typed.isEmpty)

        var filled = tree
        filled.roots[0].children[0].children[0].value = SignUp.bullets
        let allowed = FillScript([tree, filled])
        let profile = try LoginProfile.parse(Data(#"{"bundleId":"com.example.app","webLogin":true}"#.utf8))
        _ = try await allowed.fill(profile: profile, webLogin: true)
        #expect(allowed.typed == [SignUp.password])
    }

    @Test("a save-password prompt after the fields is declined by its Not Now control and nothing else")
    func savePromptDeclined() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets), SignUp.screen(password: SignUp.bullets, confirm: SignUp.bullets)])
        script.prompt = SavePrompt(title: "Save Password?", declineLabel: "Not Now", decline: UIPoint(x: 120, y: 600))
        let report = try await script.fill()
        #expect(script.taps == [UIPoint(x: 120, y: 600)])
        #expect(report.savePrompt == .declined)
    }

    @Test("a prompt with no decline control is left for a person, with nothing submitted")
    func promptWithoutDecline() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets), SignUp.screen(password: SignUp.bullets, confirm: SignUp.bullets)])
        script.prompt = SavePrompt(title: "Save Password?")
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        #expect(stopped.reason == .systemPromptInFront)
        #expect(script.taps.isEmpty)
        #expect(stopped.report.filled.count == 2)
    }

    @Test("identity types the saved email into the one email field, as plain text, and reads it back")
    func identity() async throws {
        var typed = SignUp.emailStep
        typed.roots[0].children[0].value = SignUp.username
        let script = FillScript([SignUp.emailStep, typed])
        let report = try await script.fill(.identity)
        #expect(script.typed == [SignUp.username])
        #expect(script.secrecy == [false])
        #expect(script.taps.isEmpty)
        #expect(report.filled.map(\.name) == ["id=signup-email"])
    }

    @Test("a stopped fill's JSON names its screen-quoting message as untrusted and says which field was filled")
    func failureJSON() async throws {
        let script = FillScript([SignUp.screen(), SignUp.screen(password: SignUp.bullets)])
        script.foregrounds = ["com.example.app", "com.example.app", "com.example.other"]
        let stopped = try #require(await #expect(throws: LoginFillFailure.self) { try await script.fill() })
        var written = ""
        _ = await LoginCommand.failure(stopped, json: true, scope: CommandScope(), write: { written = $0 })
        #expect(written.contains(#""fields":[{"field":"id=signup-password","state":"filled"},{"field":"id=signup-confirm","state":"not_filled"}]"#))
        #expect(written.contains(#""untrusted":["error.message"]"#))
        #expect(!written.contains(SignUp.password))
    }

    @Test("typing over a field clears it first, select-all then delete, so nothing is ever appended to a placeholder or an earlier fill")
    func typesOverNeverAppends() throws {
        let typing = try LoginCommand.typingCommand(text: SignUp.password, field: SignUp.field(id: "signup-confirm", label: "Confirm password", y: 220), deviceID: "DEVICE")
        #expect(typing.replace)
        #expect(typing.intoID == "signup-confirm")
        let events = try Type.iosEvents(for: SignUp.password, replacing: typing.replace)
        #expect(events.first == InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey, settle: InputEvent.iosClearSettle))
        #expect(events.dropFirst().allSatisfy { $0 != InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey, settle: InputEvent.iosClearSettle) })
    }

    @Test("repeated fills on an Android screen whose fields already hold the password type nothing more")
    func repeatedFillsDoNotSpray() async throws {
        let script = FillScript([SignUp.screen(password: SignUp.bullets, confirm: SignUp.bullets, platform: .android)])
        let error = try #require(await #expect(throws: CLIError.self) { try await script.fill() })
        #expect(error.reason == .fieldNotEmpty)
        #expect(script.typed.isEmpty)
    }
}

@MainActor
@Suite("login --fill gates")
struct LoginFillGateTests {
    private func credential() throws -> LoginCredential {
        try #require(LoginCredential(username: SignUp.username, password: SignUp.password))
    }

    private func fill(
        _ store: MemoryLoginCredentialStore, package: String = "com.example.app", device: String = "emulator-5554", app: String? = nil,
        presence: FakePresence = FakePresence(), recordingLive: @escaping (DeviceLockKey) -> Bool = { _ in false }
    ) async -> (any Error)? {
        let id = DeviceID(rawValue: device, platform: .android)
        let root = UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes(package: package)))
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: device, roots: [root])])
        do {
            try await PersonPresence.$current.withValue(presence) {
                _ = try await LoginCommand.performFill(
                    LoginFillRequest(target: .password, app: app), on: DeviceRouter.Route(backend: backend, device: id), profile: nil, key: "dev",
                    logger: OffsiderLogger(), store: store, recordingLive: recordingLive
                )
            }
            return nil
        } catch {
            return error
        }
    }

    /// The field rules run only after every gate, so `selector_not_found` on an empty screen means each gate passed.
    private func expectPassedTheGates(_ error: (any Error)?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((error as? CLIError)?.reason == .selectorNotFound, "stopped by \(String(describing: error))", sourceLocation: sourceLocation)
    }

    @Test("a recording on the device refuses before the screen or the Keychain is read")
    func recording() async throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try credential(), app: "com.example.app", key: "dev", isDefault: true)
        #expect((await fill(store, recordingLive: { _ in true }) as? CLIError)?.reason == .deviceBusy)
        #expect(store.decrypts == 0)
        expectPassedTheGates(await fill(store))
    }

    @Test("--app that is not the app in front refuses before the Keychain is read")
    func otherApp() async throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try credential(), app: "com.example.app", key: "dev", isDefault: true)
        let refused = try #require(await fill(store, app: "com.example.signup") as? CLIError)
        #expect(refused.reason == .foregroundChanged)
        #expect(store.decrypts == 0)
        expectPassedTheGates(await fill(store, app: "com.example.app"))
    }

    /// The gate a fill runs, which is the one a sign-in runs; nil once every check passed.
    private func gate(_ store: MemoryLoginCredentialStore, package: String = "com.example.app", device: String = "emulator-5554", presence: FakePresence = FakePresence()) async -> (any Error)? {
        let id = DeviceID(rawValue: device, platform: .android)
        let root = UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes(package: package)))
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: device, roots: [root])])
        do {
            _ = try await PersonPresence.$current.withValue(presence) {
                try await LoginCommand.gate(
                    on: DeviceRouter.Route(backend: backend, device: id), profile: nil, key: "dev", where: [], waitTurnstile: nil, logger: OffsiderLogger(), store: store,
                    wholeDevice: false, step: { _, _ in }, ask: { _ in }, onPrepared: {}, keychainWillRead: { _ in }, keychainDidRead: {}, recordingLive: { _ in false }
                )
            }
            return nil
        } catch {
            return error
        }
    }

    @Test("a browser in front, a login saved with confirm and a phone outside the login's scope stop the shared gate")
    func sharedGates() async throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try credential(), app: "com.android.chrome", key: "dev", isDefault: true)
        #expect((await gate(store, package: "com.android.chrome") as? CLIError)?.reason == .appNotAllowed)

        try store.saveStored(StoredLogin(credential: try credential(), confirm: true), app: "com.example.app", key: "dev", isDefault: true, context: LoginContext(confirm: true))
        let person = FakePresence()
        #expect(await gate(store, presence: person) == nil)
        #expect(person.reasons == ["type the saved login dev into com.example.app on emulator-5554"])
        let declined = FakePresence(failure: PersonPresence.error(for: .userCancel))
        #expect((await gate(store, presence: declined) as? CLIError)?.reason == .personRequired)

        try store.save(try credential(), app: "com.example.app", key: "dev", isDefault: true)
        #expect((await gate(store, device: "ZY22FAKE01") as? CLIError)?.reason == .deviceNotAllowed)
        #expect(await gate(store) == nil)
    }

    @Test("a screen the fill would refuse stops it before the Keychain is read, so it costs no Touch ID")
    func refusedBeforeTheKeychain() async throws {
        let store = MemoryLoginCredentialStore()
        try store.saveStored(StoredLogin(credential: try credential(), confirm: true), app: "com.example.app", key: "dev", isDefault: true, context: LoginContext(confirm: true))
        var reads = 0
        store.onRead = { reads += 1 }
        let id = DeviceID(rawValue: "emulator-5554", platform: .android)
        var screen = SignUp.screen(toggleOn: true, platform: .android)
        screen.roots[0].native = .android(AndroidNativeAttributes(package: "com.example.app"))
        let backend = FakeDeviceBackend(platform: .android, trees: [screen])
        let person = FakePresence()
        let error = await #expect(throws: CLIError.self) {
            try await PersonPresence.$current.withValue(person) {
                _ = try await LoginCommand.performFill(
                    LoginFillRequest(target: .password), on: DeviceRouter.Route(backend: backend, device: id), profile: nil, key: "dev",
                    logger: OffsiderLogger(), store: store, recordingLive: { _ in false }
                )
            }
        }
        #expect(error?.reason == .secretWouldShow)
        #expect(reads == 0 && store.decrypts == 0)
        #expect(person.reasons.isEmpty)
    }

    @Test("the recording check the fill repeats before each field is the command's own")
    func recordingCheckIsWired() async throws {
        let store = MemoryLoginCredentialStore()
        try store.save(try credential(), app: "com.example.app", key: "dev", isDefault: true)
        let id = DeviceID(rawValue: "emulator-5554", platform: .android)
        let root = UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes(package: "com.example.app")))
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: "emulator-5554", roots: [root])])
        var live = false
        let gated = try await LoginCommand.gate(
            on: DeviceRouter.Route(backend: backend, device: id), profile: nil, key: "dev", where: [], waitTurnstile: nil, logger: OffsiderLogger(), store: store,
            wholeDevice: false, step: { _, _ in }, ask: { _ in }, onPrepared: {}, keychainWillRead: { _ in }, keychainDidRead: {}, recordingLive: { _ in live }
        )
        try gated.services.refuseRecording()
        live = true
        #expect(throws: CLIError.self) { try gated.services.refuseRecording() }
    }
}
