import ArgumentParser
import CoreGraphics
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// A scripted device that answers `alert`'s reads: each read takes the next answer, and the last one repeats.
@MainActor
final class PromptBackend: FakeDeviceBackend, AppPromptReading, AppPromptCapturing {
    enum Answer {
        case prompt(AppPrompt)
        case refusal(AppPromptRefusal)
    }

    var answers: [Answer] = []
    var stillThere = true
    /// The prompt a capture finds over the app a test device is held to.
    var overSelectedApp: AppPrompt?
    private(set) var promptReads = 0

    func appPrompt(for app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree) {
        let answer = answers[min(promptReads, answers.count - 1)]
        promptReads += 1
        switch answer {
        case .prompt(let prompt): return (prompt, try await accessibilityTree(for: id))
        case .refusal(let refusal): throw refusal
        }
    }

    func stillInFront(_ prompt: AppPrompt, on id: DeviceID) async throws -> Bool { stillThere }

    func promptOverSelectedApp(on id: DeviceID) async throws -> AppPrompt? { overSelectedApp }
}

@MainActor
@Suite("alert")
struct AlertCommandTests {
    static let app = AlertFixtures.android
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let phone = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)

    static let tree = AlertFixtures.androidDialog()
    static let prompt = AndroidPermissionPrompt.read(tree, app: app, token: "1a2b")!
    static let gone = PromptBackend.Answer.refusal(.notShown(front: app))

    static func backend(_ answers: [PromptBackend.Answer]) -> PromptBackend {
        let backend = PromptBackend(platform: .android, trees: [tree])
        backend.answers = answers
        return backend
    }

    static let clock = PollClock(now: { 0 }, sleep: { _ in })

    /// Runs the command's work on `backend` with `loaded` guard rules; returns the report or the failure, and what reached the device.
    static func run(
        _ choice: AppPrompt.Choice?, on backend: PromptBackend, loaded: GuardSources.Loaded = GuardSources.Loaded(),
        environment: AppGuard.Environment = AppGuard.Environment(confirm: { _ in }, signedIn: { _, _ in "tester" }, isTestDevice: { _ in nil }), clock: PollClock = clock
    ) async -> (report: AlertReport?, failure: CLIError?, sent: [RecordingInputSession.Call]) {
        var report: AlertReport?
        var failure: CLIError?
        await GuardSources.$source.withValue({ loaded }) {
            await AppGuard.$environment.withValue(environment) {
                await DispatchTracker.$current.withValue(DispatchTracker()) {
                    await DeviceActivityLedger.$current.withValue(DeviceActivityLedger()) {
                        do {
                            report = try await AlertCommand.perform(choice, app: app, on: DeviceRouter.Route(backend: backend, device: device), clock: clock)
                        } catch {
                            failure = error as? CLIError ?? CLIError(errorDescription: "\(error)")
                        }
                    }
                }
            }
        }
        return (report, failure, backend.session.calls)
    }

    static func rules(_ rules: [GuardRule], for app: String = app) -> GuardSources.Loaded {
        var loaded = GuardSources.Loaded()
        loaded.approvals = GuardApprovals().approving(GuardConfig(apps: [app], rules: rules), source: nil, now: Date(timeIntervalSince1970: 0))
        return loaded
    }

    static func centre(_ label: String) -> RecordingInputSession.Call {
        let frame = prompt.buttons.first { $0.label == label }!.frame
        return .perform(.tapAt(x: frame.center.x, y: frame.center.y))
    }

    // MARK: Arguments

    @Test("an unknown action, no --app, choose with no text and a text on another action are usage errors", arguments: [
        ["grant", "--app", app, "--device", "emulator-5554"],
        ["accept", "--device", "emulator-5554"],
        ["choose", "--app", app, "--device", "emulator-5554"],
        ["choose", " ", "--app", app, "--device", "emulator-5554"],
        ["deny", "Allow", "--app", app, "--device", "emulator-5554"],
    ])
    func usage(arguments: [String]) {
        #expect(throws: (any Error).self) { try AlertCommand.parse(arguments) }
    }

    @Test("each action parses to what it does to the prompt")
    func plans() throws {
        #expect(try AlertCommand.parse(["show", "--app", Self.app, "--device", "emulator-5554"]).plan().choice == nil)
        #expect(try AlertCommand.parse(["accept", "--app", Self.app, "--device", "emulator-5554"]).plan().choice == .accept)
        #expect(try AlertCommand.parse(["deny", "--app", Self.app, "--device", "emulator-5554"]).plan().choice == .deny)
        #expect(try AlertCommand.parse(["choose", "Only this time", "--app", Self.app, "--device", "emulator-5554"]).plan().choice == .label("Only this time"))
    }

    // MARK: Devices

    @Test("a phone in personal use is refused in one line before anything is read, and the prompt is the user's")
    func personalPhone() {
        let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, expires: nil, apps: [Self.app])
        let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry])))
        let backend = Self.backend([.prompt(Self.prompt)])
        let error = #expect(throws: CLIError.self) { try AlertCommand.requireDevice(DeviceRouter.Route(backend: backend, device: Self.phone, allowance: entry), gate: gate) }
        #expect(error?.reason == .personRequired)
        #expect(error?.userFacingDescription.contains("is in personal use, not a test device") == true)
        #expect(error?.userFacingDescription.contains("\n") == false)
        #expect(error?.ask == "Can you answer the prompt on \(PersonAsk.devicePlaceholder)?")
        #expect(backend.promptReads == 0 && backend.treeReads == 0)
    }

    @Test("a test device a person chose passes, and stops being one when managed policy turns test devices off")
    func testDevice() throws {
        let entry = DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test phone", added: PolicyFixtures.added, expires: nil, apps: [], testDevice: true)
        let route = DeviceRouter.Route(backend: Self.backend([.prompt(Self.prompt)]), device: Self.phone, allowance: entry)
        try AlertCommand.requireDevice(route, gate: .fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))))

        let managed = ManagedDevicePolicy(allowTestDevices: false)
        let error = #expect(throws: CLIError.self) {
            try AlertCommand.requireDevice(route, gate: DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: [entry]))))
        }
        #expect(error?.reason == .personRequired)
    }

    @Test("a simulator and an emulator pass; a test iPhone is not reached yet, and says what to use")
    func otherDevices() throws {
        try AlertCommand.requireDevice(DeviceRouter.Route(backend: Self.backend([.prompt(Self.prompt)]), device: Self.device))
        let entry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], team: "ABCDE12345", testDevice: true)
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: []), device: DeviceID(rawValue: PolicyFixtures.phone, platform: .ios), allowance: entry)
        let error = #expect(throws: CLIError.self) {
            try AlertCommand.requireDevice(route, gate: .fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))))
        }
        #expect(error?.reason == .notSupported)
        #expect(error?.hint == "offsider describe-ui --summary --device \(PolicyFixtures.phone)")
    }

    // MARK: Reading and answering

    @Test("show reads the prompt and sends nothing")
    func show() async {
        let result = await Self.run(nil, on: Self.backend([.prompt(Self.prompt)]))
        #expect(result.report?.prompt == Self.prompt)
        #expect(result.report?.chosen == nil)
        #expect(result.sent.isEmpty)
    }

    @Test("deny, accept and choose each tap their one button's middle, once", arguments: [
        (AppPrompt.Choice.deny, "Don’t allow"), (.accept, "While using the app"), (.label("Only this time"), "Only this time"),
    ])
    func answers(choice: AppPrompt.Choice, label: String) async {
        let result = await Self.run(choice, on: Self.backend([.prompt(Self.prompt), Self.gone]))
        #expect(result.failure == nil)
        #expect(result.sent == [Self.centre(label)])
        #expect(result.report?.chosen?.label == label)
        #expect(result.report?.action == choice.word)
        #expect(result.report?.next == nil)
    }

    @Test("a text no button has is selector_not_found with the buttons as candidates, and nothing is sent")
    func unknownLabel() async {
        let result = await Self.run(.label("Always"), on: Self.backend([.prompt(Self.prompt)]))
        #expect(result.failure?.reason == .selectorNotFound)
        #expect(result.failure?.candidates.map(\.label) == ["While using the app", "Only this time", "Don’t allow"])
        #expect(result.sent.isEmpty)
    }

    @Test("accept on a prompt with no grant Offsider can tell names the buttons and choose, and sends nothing")
    func noAcceptButton() async {
        var prompt = Self.prompt
        prompt.buttons = prompt.buttons.map { AppPrompt.Button(label: $0.label, role: $0.role == .accept ? .other : $0.role, frame: $0.frame) }
        let result = await Self.run(.accept, on: Self.backend([.prompt(prompt)]))
        #expect(result.failure?.reason == .selectorAmbiguous)
        #expect(result.failure?.hint == "offsider alert choose \"<label>\" --app \(Self.app) --device emulator-5554")
        #expect(result.sent.isEmpty)
    }

    @Test("what is in front in place of the app's prompt is named, with the exit an agent can branch on, and nothing is sent", arguments: [
        (AppPromptRefusal.notShown(front: app), FailureReason.alertNotShown, "\(app) itself is in front"),
        (.notShown(front: "com.example.launcher"), .alertNotShown, "com.example.launcher is in front"),
        (.otherApp(requester: "com.example.other", why: "com.example.other raised it"), .systemPromptInFront, "com.example.other raised it"),
        (.notPermission(what: "the system prompt \"Save Password?\" from SafariViewService"), .systemPromptInFront, "Save Password?"),
        (.unreadable(why: "none of its buttons carries a permission button id"), .notSupported, "does not know its layout"),
    ])
    func refusals(refusal: AppPromptRefusal, reason: FailureReason, names: String) async {
        let result = await Self.run(.accept, on: Self.backend([.refusal(refusal)]))
        #expect(result.failure?.reason == reason)
        #expect(result.failure?.userFacingDescription.contains(names) == true, "\(result.failure?.userFacingDescription ?? "")")
        #expect(result.failure?.userFacingDescription.contains("\n") == false)
        #expect(result.sent.isEmpty)
    }

    @Test("another app's prompt names the command that reads it for that app")
    func otherAppHint() {
        let failure = AlertCommand.failure(.otherApp(requester: "com.example.other", why: "com.example.other raised it"), app: Self.app, device: Self.device)
        #expect(failure.hint == "offsider alert show --app com.example.other --device emulator-5554")
        #expect(failure.reason.exitCode == .deviceUnavailable)
        #expect(FailureReason.alertNotShown.exitCode == .selectorNotFound)
    }

    @Test("a prompt that left before the tap is foreground_changed, and nothing is sent")
    func leftBeforeTheTap() async {
        let backend = Self.backend([.prompt(Self.prompt)])
        backend.stillThere = false
        let result = await Self.run(.deny, on: backend)
        #expect(result.failure?.reason == .foregroundChanged)
        #expect(result.sent.isEmpty)
    }

    @Test("a button whose middle lies outside the prompt's box, as on a prompt that scrolls, is not tapped")
    func clippedButton() async {
        var prompt = Self.prompt
        prompt.frame = UIFrame(x: 85, y: 266, width: 681, height: 150)
        let result = await Self.run(.accept, on: Self.backend([.prompt(prompt)]))
        #expect(result.failure?.reason == .targetOffScreen)
        #expect(result.sent.isEmpty)
    }

    @Test("with nothing readable in front, the refusal still names the app and says nothing was sent")
    func nothingReadable() {
        let failure = AlertCommand.failure(.notShown(front: nil), app: Self.app, device: Self.device)
        #expect(failure.userFacingDescription == "No permission prompt for \(Self.app) is in front on emulator-5554. Nothing was sent.")
    }

    @Test("a prompt still up after the tap is not_verified; the next prompt an app raises is reported")
    func afterTheTap() async {
        var time: TimeInterval = 0
        let ticking = PollClock(now: { time }, sleep: { _ in time += 1 })
        let stuck = await Self.run(.deny, on: Self.backend([.prompt(Self.prompt)]), clock: ticking)
        #expect(stuck.failure?.reason == .notVerified)
        #expect(stuck.sent.count == 1)

        var second = Self.prompt
        second.title = "Allow Playground to send you notifications?"
        let followed = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), .prompt(second)]))
        #expect(followed.report?.next?.title == "Allow Playground to send you notifications?")
        #expect(followed.report?.textLines.contains("Another prompt followed:") == true)
    }

    // MARK: The app guard

    static let never = GuardRule(name: "Camera access", action: .never, control: GuardMatcher(label: "While using the app"))
    static let ask = GuardRule(name: "Camera access", action: .ask, control: GuardMatcher(labelContains: "this time"))

    @Test("a never rule on the button refuses accept and choose with nothing sent, though the app has no element on screen")
    func neverRule() async {
        let accept = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.never]))
        #expect(accept.failure?.reason == .guardedControl)
        #expect(accept.failure?.userFacingDescription.contains("\"Camera access\"") == true)
        #expect(accept.sent.isEmpty)

        let choose = await Self.run(.label("While using the app"), on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.never]))
        #expect(choose.failure?.reason == .guardedControl)
        #expect(choose.sent.isEmpty)
    }

    @Test("deny passes whatever the rules say, and rules for another app do not hold this one")
    func denyPasses() async {
        let strict = GuardRule(name: "Every answer", action: .never, control: GuardMatcher(labelContains: "allow"))
        let deny = await Self.run(.deny, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([strict]))
        #expect(deny.failure == nil)
        #expect(deny.sent == [Self.centre("Don’t allow")])

        let other = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.never], for: "com.example.other"))
        #expect(other.failure == nil)
        #expect(other.sent == [Self.centre("While using the app")])
    }

    @Test("an ask rule waits for a person: approved it taps, declined or with no saved login it sends nothing")
    func askRule() async {
        let asked = Locked<[String]>([])
        let approving = AppGuard.Environment(confirm: { reason in asked.withLock { $0.append(reason) } }, signedIn: { _, _ in "tester" }, isTestDevice: { _ in nil })
        let approved = await Self.run(.label("Only this time"), on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.ask]), environment: approving)
        #expect(approved.failure == nil)
        #expect(approved.sent == [Self.centre("Only this time")])
        #expect(asked.withLock { $0 }.count == 1)

        let declining = AppGuard.Environment(confirm: { _ in throw CLIError.personRequired("declined") }, signedIn: { _, _ in "tester" }, isTestDevice: { _ in nil })
        let declined = await Self.run(.label("Only this time"), on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.ask]), environment: declining)
        #expect(declined.failure?.reason == .personRequired)
        #expect(declined.sent.isEmpty)

        let signedOut = AppGuard.Environment(confirm: { _ in }, signedIn: { _, _ in nil }, isTestDevice: { _ in nil })
        let refused = await Self.run(.label("Only this time"), on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.ask]), environment: signedOut)
        #expect(refused.failure?.reason == .guardedControl)
        #expect(refused.sent.isEmpty)
    }

    @Test("a rule for a screen holds accept, since the screen beneath a prompt cannot be read, and a whole-screen rule holds every grant")
    func screenRulesCountAsShowing() async {
        let scoped = GuardRule(name: "Camera on checkout", action: .never, control: GuardMatcher(label: "While using the app"), screen: GuardMatcher(id: "checkout-screen"))
        let onScreen = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([scoped]))
        #expect(onScreen.failure?.reason == .guardedControl)
        #expect(onScreen.sent.isEmpty)

        let lookOnly = GuardRule(name: "Statements", action: .never, screen: GuardMatcher(id: "statements-screen"))
        let whole = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([lookOnly]))
        #expect(whole.failure?.reason == .guardedControl)
        #expect(whole.sent.isEmpty)
    }

    @Test("approved rules changed outside Offsider, or a rules file that cannot be read, stop accept rather than open it")
    func brokenRulesFailClosed() async {
        var changed = Self.rules([Self.never])
        changed.sealIntact = false
        changed.sealedApps = [Self.app]
        let sealed = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: changed)
        #expect(sealed.failure?.reason == .guardedControl)
        #expect(sealed.sent.isEmpty)

        var unreadable = GuardSources.Loaded()
        unreadable.problem = "Could not read offsider.guard.json: not valid JSON."
        let broken = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: unreadable)
        #expect(broken.failure?.reason == .usage)
        #expect(broken.sent.isEmpty)
    }

    // MARK: Evidence

    @Test("an answer is one line in the run's timeline with the prompt's title and the button; show records nothing; a refused accept keeps the title and no button")
    func timeline() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        try await fixture.command(fixture.recorder("alert", arguments: ["show", "--app", Self.app])) {
            _ = await Self.run(nil, on: Self.backend([.prompt(Self.prompt)]))
        }
        #expect(fixture.manifest().isEmpty)

        try await fixture.command(fixture.recorder("alert", arguments: ["accept", "--app", Self.app])) {
            _ = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]))
        }
        let line = try #require(fixture.manifest().last)
        #expect(line.command == "alert" && line.file == nil && line.exit == 0)
        #expect(line.prompt == Self.prompt.title)
        #expect(line.button == "While using the app")
        #expect(line.device == "emulator-5554")

        try await fixture.command(fixture.recorder("alert", arguments: ["accept", "--app", Self.app])) {
            _ = await Self.run(.accept, on: Self.backend([.prompt(Self.prompt), Self.gone]), loaded: Self.rules([Self.never]))
        }
        let refused = try #require(fixture.manifest().last)
        #expect(refused.prompt == Self.prompt.title && refused.button == nil)
        #expect(EvidenceRecorder.records("alert"))
    }
}

/// A value shared with a `@Sendable` closure.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@Suite("A capture of a permission prompt", .personOutput)
@MainActor
struct AlertCaptureTests {
    static let device = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)

    /// The dialog at (85, 266) 681 x 354 on an 852 x 883 pt screen, captured white at one pixel per point.
    static func capture(prompt: AppPrompt?, arguments: [String] = []) async throws -> (report: ScreenshotReport, image: CGImage) {
        let backend = PromptBackend(
            platform: .android, trees: [AlertCommandTests.tree],
            screenshots: [try ScreenImage.encode(TestImages.make(width: 852, height: 883, background: 255), as: .png)],
            screen: UIScreenInfo(width: 852, height: 883, scale: 1, rotation: .portrait)
        )
        backend.overSelectedApp = prompt
        let path = ScreenshotMaskTests.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let command = try Screenshot.parse(arguments + ["--output", path, "--app", AlertCommandTests.app, "--device", device.rawValue])
        let report = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: try command.maskPlan(environment: ["OFFSIDER_MASK_SECURE": "0"]))
        return (report, try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    @Test("with the named app's prompt in front, everything outside the prompt is painted and the report says maskUnproven prompt")
    func paintsOutsideThePrompt() async throws {
        let (report, image) = try await Self.capture(prompt: AlertCommandTests.prompt)
        #expect(report.maskUnproven == "prompt")
        for point in [(10, 10), (400, 200), (400, 700), (40, 400), (800, 400), (850, 880)] {
            #expect(ScreenshotMaskTests.pixel(image, point.0, point.1) == ScreenshotMaskTests.black, "\(point)")
        }
        for point in [(90, 270), (425, 430), (760, 615)] {
            #expect(ScreenshotMaskTests.pixel(image, point.0, point.1) == ScreenshotMaskTests.white, "\(point)")
        }
        let json = try #require(JSONSerialization.jsonObject(with: Data(report.jsonLine().utf8)) as? [String: Any])
        #expect(json["maskUnproven"] as? String == "prompt")
    }

    @Test("with no prompt, the capture is as it was: nothing painted, nothing unproven")
    func noPromptNoPaint() async throws {
        let (report, image) = try await Self.capture(prompt: nil)
        #expect(report.maskUnproven == nil)
        #expect(ScreenshotMaskTests.pixel(image, 10, 10) == ScreenshotMaskTests.white)
    }
}
