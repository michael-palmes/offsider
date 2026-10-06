import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing
@testable import Offsider

@Suite("type --into-id and --require-focus-id")
@MainActor
struct TypeIntoTests {
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let simulator = DeviceID(rawValue: UUID().uuidString, platform: .ios)

    static func form(focused: String?, keyboard: Bool = false, platform: DevicePlatform = .android) -> UITree {
        func field(_ id: String, y: Double) -> UINode {
            FakeUI.node(.textField, id: id, label: id, frame: FakeUI.frame(20, y, 360, 44), state: UIState(focused: focused == id ? true : nil), platform: platform)
        }
        var children = [field("first-field", y: 200), field("second-field", y: 300)]
        if keyboard { children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 574, 402, 300), platform: platform)) }
        return FakeUI.tree(platform: platform, children)
    }

    /// Runs `body` with its own tree cache in which the test devices saw no recent input, so the transition guard acts at once.
    static func quiet<T>(_ body: () async throws -> T) async throws -> T {
        let fixture = try TreeCacheFixture()
        for device in [android, simulator, iPhone] {
            try fixture.write(TreeCacheRecord(platform: device.platform, device: device.rawValue, command: "tap", writtenAt: fixture.now - 5))
        }
        return try await fixture.run(body)
    }

    static func focus(_ arguments: [String], trees: [UITree], device: DeviceID = android, warnings: Box<[String]> = Box([])) async throws -> [InputEvent] {
        let backend = FakeDeviceBackend(platform: device.platform, trees: trees)
        var sent: [InputEvent] = []
        try await quiet {
            try await Type.parse(arguments + ["text", "--device", device.rawValue]).ensureFocus(
                backend: backend, device: device, logger: OffsiderLogger(), clock: ScriptedClock().poll, warn: { warnings.value.append($0) }
            ) { sent.append($0) }
        }
        return sent
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test("--into-id taps the field and returns once it has focus")
    func confirmedTapsOnce() async throws {
        let sent = try await Self.focus(["--into-id", "second-field"], trees: [Self.form(focused: "first-field"), Self.form(focused: "first-field"), Self.form(focused: "second-field")])
        #expect(sent == [.tapAt(x: 200, y: 322)])
    }

    @Test("on an iOS simulator a keyboard that appears after the tap, with the field still on screen, confirms focus with no warning")
    func simulatorKeyboard() async throws {
        let warnings = Box<[String]>([])
        let sent = try await Self.focus(
            ["--into-id", "second-field"], trees: [Self.form(focused: nil, platform: .ios), Self.form(focused: nil, keyboard: true, platform: .ios)],
            device: Self.simulator, warnings: warnings
        )
        #expect(sent.count == 1)
        #expect(warnings.value.isEmpty)
    }

    @Test("on an iOS simulator a keyboard already up before the tap cannot prove focus: it warns, then types into the tapped field")
    func simulatorKeyboardAlreadyUp() async throws {
        let warnings = Box<[String]>([])
        let sent = try await Self.focus(
            ["--into-id", "second-field"], trees: [Self.form(focused: nil, keyboard: true, platform: .ios)], device: Self.simulator, warnings: warnings
        )
        #expect(sent == [.tapAt(x: 200, y: 322)])
        #expect(warnings.value == ["the keyboard was already up, so the iOS simulator cannot confirm which field has focus; check with assert --has-value."])

        let backend = FakeDeviceBackend(platform: .ios, trees: [Self.form(focused: nil, keyboard: true, platform: .ios)])
        try await Self.quiet { try await Type.parse(["--into-id", "second-field", "hi", "--device", Self.simulator.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger()) }
        #expect(backend.session.calls.count == 2)
        #expect(backend.session.calls.first == .perform(.tapAt(x: 200, y: 322)))
    }

    @Test("on an iOS simulator a keyboard that never appears is exit 5 focus_not_confirmed, and nothing is typed")
    func simulatorNoKeyboard() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [Self.form(focused: nil, platform: .ios)])
        let error = await #expect(throws: CLIError.self) {
            try await Self.quiet { try await Type.parse(["--into-id", "second-field", "hi", "--device", Self.simulator.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger()) }
        }
        #expect(error?.reason == .focusNotConfirmed)
        #expect(error?.exitCode == .unverified)
        #expect(backend.session.calls == [.perform(.tapAt(x: 200, y: 322))])
    }

    @Test("a field that never takes focus is exit 5 focus_not_confirmed, and the command types nothing")
    func neverConfirmed() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.form(focused: "first-field")])
        let error = await #expect(throws: CLIError.self) {
            try await Self.quiet { try await Type.parse(["--into-id", "second-field", "--replace", "secret", "--device", Self.android.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.android), progress: nil, logger: OffsiderLogger()) }
        }
        #expect(error?.reason == .focusNotConfirmed)
        #expect(error?.exitCode == .unverified)
        #expect(backend.session.calls == [.perform(.tapAt(x: 200, y: 322))])
    }

    @Test("--require-focus-id with another field focused is exit 2 focus_mismatch naming that field, and sends nothing")
    func mismatch() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.focus(["--require-focus-id", "second-field"], trees: [Self.form(focused: "first-field")])
        }
        #expect(error?.reason == .focusMismatch)
        #expect(error?.exitCode == .selectorNotFound)
        #expect(error?.candidates.first?.id == "first-field")
        #expect(try await Self.focus(["--require-focus-id", "first-field"], trees: [Self.form(focused: "first-field")]).isEmpty)
    }

    @Test("--require-focus-id on an iOS simulator is not supported and points to --into-id")
    func requireFocusOnSimulator() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.focus(["--require-focus-id", "first-field"], trees: [Self.form(focused: nil, platform: .ios)], device: Self.simulator)
        }
        #expect(error?.reason == .notSupported)
        #expect(error?.userFacingDescription.contains("--into-id first-field") == true)
    }

    static let iPhone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    /// The device runner's snapshot, whose password field holds keyboard focus.
    static func runnerTree() throws -> UITree {
        let snapshot = try IOSAccessibilityMapping.tree(fromJSON: try IOSDeviceFixtures.data("runner-snapshot.json"))
        return UITree(platform: .ios, device: iPhone.rawValue, roots: snapshot.roots)
    }

    @Test("on a physical iPhone the runner's keyboard focus satisfies --require-focus-id and confirms --into-id")
    func physicalDeviceFocus() async throws {
        let tree = try Self.runnerTree()

        #expect(try await Self.focus(["--require-focus-id", "password"], trees: [tree], device: Self.iPhone).isEmpty)
        #expect(try await Self.focus(["--into-id", "password"], trees: [tree], device: Self.iPhone) == [.tapAt(x: 215, y: 382)])
    }

    static let playground = "com.mpalmes.offsider.playground"

    /// An iPhone on an Xcode 26 host, so the tree, the focus tap and the text all reach the scripted runner.
    static func runnerBackend() throws -> (IOSDeviceBackend, FakeRunnerTransport) {
        let transport = FakeRunnerTransport(snapshot: try IOSDeviceFixtures.data("runner-snapshot.json"))
        return (try RunnerClientTests.backend(transport).0, transport)
    }

    /// The runner calls after its connection ping, as `path app` lines.
    static func appCalls(_ transport: FakeRunnerTransport) -> [String] {
        transport.calls.filter { $0.path != "/ping" }.map { "\($0.path) \($0.body["app"].map { "\($0)" } ?? "-")" }
    }

    static func quietOutput() -> BatchOutput {
        BatchOutput(json: true, write: { _ in }, writeError: { _ in })
    }

    @Test("type --app on a physical iPhone reads that app's tree for the field and sends the tap and the text to it", arguments: [
        ["--into-id", "password"], ["--require-focus-id", "password"],
    ])
    func physicalDeviceApp(focus: [String]) async throws {
        let (backend, transport) = try Self.runnerBackend()

        try await Self.quiet { try await Type.parse(focus + ["--replace", "new", "--app", Self.playground, "--device", Self.iPhone.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.iPhone), progress: nil, logger: OffsiderLogger()) }

        let calls = Self.appCalls(transport)
        #expect(calls.first == "/snapshot \(Self.playground)" && calls.last == "/type \(Self.playground)", "\(calls)")
        #expect(calls.allSatisfy { $0.hasSuffix(" \(Self.playground)") }, "\(calls)")
        #expect(calls.contains("/tap-point \(Self.playground)") == (focus[0] == "--into-id"))
    }

    @Test("a batch type step's --app reaches its focus read, its tap and its text, through a session opened before the step")
    func batchStepApp() async throws {
        let (backend, transport) = try Self.runnerBackend()
        let context = BatchContext(backend: backend, device: Self.iPhone, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        let session = try await backend.openInputSession(for: Self.iPhone)

        try await Self.quiet { try await Batch.runSteps(
            ["type --into-id password --replace new --app \(Self.playground)"],
            context: context, session: session, continueOnError: false, output: Self.quietOutput(), logger: OffsiderLogger()
        ) }

        let calls = Self.appCalls(transport)
        #expect(calls.contains("/tap-point \(Self.playground)") && calls.last == "/type \(Self.playground)", "\(calls)")
        #expect(calls.allSatisfy { $0.hasSuffix(" \(Self.playground)") }, "\(calls)")
    }

    @Test("a batch step's --app reads that app afresh instead of the front app's cached tree, and later steps keep it")
    func batchStepAppDropsCache() async throws {
        let (backend, transport) = try Self.runnerBackend()
        let context = BatchContext(backend: backend, device: Self.iPhone, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        let session = try await backend.openInputSession(for: Self.iPhone)

        try await Self.quiet { try await Batch.runSteps(
            ["describe-ui", "describe-ui --app \(Self.playground)", "assert --id password"],
            context: context, session: session, continueOnError: false, output: Self.quietOutput(), logger: OffsiderLogger()
        ) }

        #expect(Self.appCalls(transport) == ["/snapshot -", "/snapshot \(Self.playground)"])
    }

    @Test("text the simulator keyboard cannot type fails before the focus tap, so nothing is sent")
    func unsupportedTextSendsNoTap() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [Self.form(focused: nil, keyboard: false, platform: .ios)])

        await #expect(throws: (any Error).self) {
            try await Self.quiet { try await Type.parse(["--into-id", "second-field", "price €5", "--device", Self.simulator.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger()) }
        }

        #expect(backend.session.calls.isEmpty)
    }

    /// Runs `type` with `--verify-id done --json` as the CLI does and returns the refusal and the JSON report.
    static func verifyIDRefusal(trees: [UITree], tracker: DispatchTracker) async throws -> (message: String?, report: [String: Any], backend: FakeDeviceBackend) {
        let backend = FakeDeviceBackend(platform: .android, trees: trees)
        let command = try Type.parse(["--into-id", "second-field", "hi", "--verify-id", "done", "--json", "--device", Self.android.rawValue])
        var written = Data()
        let thrown = await #expect(throws: ReportedFailure.self) {
            try await DispatchTracker.$current.withValue(tracker) {
                try await VerifyOutput.reportingFailures(command: "type", target: "text", options: command.verification, scope: CommandScope(), write: { written.append($0) }) { progress in
                    try await Self.quiet { try await command.execute(on: DeviceRouter.Route(backend: backend, device: Self.android), progress: progress, logger: OffsiderLogger()) }
                }
            }
        }
        let report = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        return ((thrown?.underlying as? CLIError)?.userFacingDescription, report, backend)
    }

    static func done() -> UINode {
        FakeUI.node(.text, id: "done", label: "Done", frame: FakeUI.frame(20, 500, 360, 44), platform: .android)
    }

    @Test("--verify-id already on screen with --into-id is refused before the focus tap, and the JSON says nothing was dispatched")
    func verifyIDPresentBeforeFocus() async throws {
        var form = Self.form(focused: nil)
        form.roots[0].children.append(Self.done())

        let (message, report, backend) = try await Self.verifyIDRefusal(trees: [form], tracker: DispatchTracker())

        #expect(message?.hasSuffix("cannot show the input worked. Nothing was sent.") == true)
        #expect(report["dispatched"] as? String == "no")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--verify-id the focus tap brought on screen is refused with only that tap sent, and the JSON agrees")
    func verifyIDPresentAfterFocus() async throws {
        var focused = Self.form(focused: "second-field")
        focused.roots[0].children.append(Self.done())

        let (message, report, backend) = try await Self.verifyIDRefusal(trees: [Self.form(focused: nil), focused], tracker: DispatchTracker())

        #expect(message?.hasSuffix("Only earlier input, such as the tap that focused the field, was sent.") == true)
        #expect(report["dispatched"] as? String == "yes")
        #expect(backend.session.calls == [.perform(.tapAt(x: 200, y: 322))])
    }

    @Test("the focus options exclude each other")
    func exclusive() {
        #expect(throws: (any Error).self) { try Type.parse(["--into-id", "a", "--require-focus-id", "a", "x", "--device", "emulator-5554"]) }
        #expect(throws: (any Error).self) { try Type.parse(["--into-id", "a", "--into-label", "b", "x", "--device", "emulator-5554"]) }
    }

    @Test("a batch type step focuses the field before its text")
    func batchStep() async throws {
        let context = BatchContext(
            backend: FakeDeviceBackend(platform: .android, trees: [Self.form(focused: "second-field")]), device: Self.android,
            axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 2
        )
        let primitives = try await Type.parse(["--into-id", "second-field", "hi", "--device", "x"]).toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard primitives.count == 2, case .run = primitives[0], case .text("hi", replace: false) = primitives[1] else {
            Issue.record("expected focus then text, got \(primitives)")
            return
        }
    }
}
