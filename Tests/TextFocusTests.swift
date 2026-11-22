import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice
import Testing
@testable import Offsider

@Suite("Text focus before typing")
@MainActor
struct TextFocusTests {
    static let simulator = DeviceID(rawValue: UUID().uuidString, platform: .ios)
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func field(_ id: String, focused: Bool = false, secure: Bool = false, platform: DevicePlatform = .ios, y: Double = 200) -> UINode {
        FakeUI.node(secure ? .secureTextField : .textField, id: id, frame: FakeUI.frame(20, y, 360, 44), state: UIState(focused: focused ? true : nil), platform: platform)
    }

    static func keyboard(y: Double = 574, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.keyboard, frame: FakeUI.frame(0, y, 402, 300), platform: platform)
    }

    /// A price field behind its wrapper's button, which keeps input focus while the app's own keypad shows.
    static let keypad = FakeUI.tree(platform: .android, [
        FakeUI.node(.button, id: "price", label: "Price, 0.00", frame: FakeUI.frame(20, 200, 360, 48), state: UIState(focused: true), platform: .android),
        FakeUI.node(.button, id: "key-5", label: "5", frame: FakeUI.frame(20, 500, 100, 52), platform: .android),
    ])

    @Test("a focused field takes text; a keyboard alone does too; a focused button or nothing does not")
    func reads() {
        #expect(TextFocus.read(FakeUI.tree([Self.field("email", focused: true)])) == .field(Self.field("email", focused: true)))
        #expect(TextFocus.read(FakeUI.tree([Self.field("email"), Self.keyboard()])) == .keyboard)
        #expect(TextFocus.read(FakeUI.tree([Self.field("email")])) == .none)
        #expect(TextFocus.read(FakeUI.tree([Self.field("email"), Self.keyboard(y: 918)])) == .none)
        guard case .notEditable(let node) = TextFocus.read(Self.keypad) else {
            Issue.record("a focused button should not take text")
            return
        }
        #expect(node.id == "price")
    }

    @Test("an Android web view holding input focus takes text, as its page's input does")
    func androidWebView() {
        let web = UINode(role: .group, id: "page", frame: FakeUI.frame(0, 100, 402, 600), state: UIState(focused: true),
                         native: .android(AndroidNativeAttributes(className: "android.webkit.WebView")))
        #expect(TextFocus.read(FakeUI.tree(platform: .android, [web])).takesText)
    }

    @Test("a text field inside the keyboard, such as its own search box, is not the app's focus")
    func keyboardFieldIgnored() {
        let gboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 0, 402, 874), platform: .android, children: [
            Self.field("handwriting", focused: true, platform: .android, y: 650),
        ])
        let tree = UITree(platform: .android, device: Self.android.rawValue, roots: [FakeUI.tree(platform: .android, [Self.field("email", platform: .android)]).roots[0], gboard])
        #expect(TextFocus.read(tree) == .unlisted)
        #expect(!TextFocus.read(tree).takesText)
        #expect(!TextFocus.read(Self.keypad).takesText)
    }

    @Test("Android reports input focus exactly, so a keyboard up for a field it does not list refuses, naming the keypad")
    func androidUnlistedField() async throws {
        let tree = UITree(platform: .android, device: Self.android.rawValue, roots: [
            FakeUI.tree(platform: .android, [FakeUI.node(.button, id: "price", label: "Price, 0.00", frame: FakeUI.frame(20, 200, 360, 48), platform: .android)]).roots[0],
            Self.keyboard(platform: .android),
        ])
        #expect(TextFocus.read(tree) == .unlisted)
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.type(["1234"], trees: [tree], device: Self.android)
        }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.userFacingDescription.contains("keyboard is up") == true)
    }

    static func type(_ arguments: [String], trees: [UITree], device: DeviceID, holding: [String: String] = [:]) async throws -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: device.platform, trees: trees)
        backend.valuesAfterKeys = holding
        let fixture = try TreeCacheFixture()
        try await fixture.run {
            try await Type.parse(arguments + ["--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
        }
        return backend
    }

    @Test("plain type with no field in focus is exit 1 no_focused_field and sends nothing", arguments: [simulator, android])
    func refusesWithoutFocus(device: DeviceID) async throws {
        let tree = FakeUI.tree(platform: device.platform, [Self.field("search", platform: device.platform)])
        var backend: FakeDeviceBackend?
        let error = await #expect(throws: CLIError.self) {
            backend = try await Self.type(["query"], trees: [tree], device: device)
        }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.exitCode == .failure)
        #expect(error?.userFacingDescription.contains("reloads on r") == true)
        #expect(backend == nil)
    }

    @Test("input focus on an app's keypad button refuses, naming the button")
    func refusesKeypadFocus() async throws {
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.type(["1234"], trees: [Self.keypad], device: Self.android)
        }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.userFacingDescription.contains("Price, 0.00") == true)
        #expect(error?.userFacingDescription.contains("keypad") == true)
    }

    @Test("plain type into a focused field, or with the keyboard up, sends the text")
    func typesWithFocus() async throws {
        for tree in [FakeUI.tree([Self.field("search", focused: true)]), FakeUI.tree([Self.field("search"), Self.keyboard()])] {
            let backend = try await Self.type(["hi"], trees: [tree], device: Self.simulator, holding: ["search": "hi"])
            #expect(backend.session.calls == [.perform(.composite(try Type.iosEvents(for: "hi", replacing: false)))])
        }
    }

    @Test("a field a tap focused a moment ago is waited for before refusing")
    func waitsForLateFocus() async throws {
        let backend = try await Self.type(
            ["hi"], trees: [FakeUI.tree([Self.field("search")]), FakeUI.tree([Self.field("search", focused: true)])], device: Self.simulator, holding: ["search": "hi"]
        )
        #expect(backend.session.calls.count == 1)
    }

    @Test("on an iOS simulator an argument aimed at a focused password field is refused")
    func simulatorSecureArgument() async throws {
        let tree = FakeUI.tree([Self.field("password", focused: true, secure: true)])
        let error = await #expect(throws: CLIError.self) {
            let backend = FakeDeviceBackend(platform: .ios, trees: [tree])
            try await Type.parse(["secret", "--device", Self.simulator.rawValue]).execute(
                on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger(), refusingSecureArgument: true
            )
        }
        #expect(error?.reason == .secureFieldArgument)
    }

    @Test("a batch type step with no field in focus fails as no_focused_field and sends nothing")
    func batchRefuses() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [FakeUI.tree([Self.field("search")])])
        let context = BatchContext(backend: backend, device: Self.simulator, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 200)
        var out = ""
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { _ in })
        await #expect(throws: ReportedFailure.self) {
            _ = try await Batch.runSteps(["type query"], context: context, session: backend.session, continueOnError: true, output: output, logger: OffsiderLogger())
        }
        #expect(out.contains("no_focused_field"))
        #expect(backend.session.calls.isEmpty)
    }

    /// A screen whose tree lists only `listed`, while a hit-test answers with `hits`' node inside its frame, as for a branch the tree leaves out.
    /// With `typed`, a hit field holds that text once keys have gone, as a field that took them does.
    static func sparse(listed: [UINode] = [], hits: [UINode], typed: String? = nil) -> HitTestingFakeBackend {
        let backend = HitTestingFakeBackend(platform: .ios, trees: [FakeUI.tree(listed)])
        backend.hits = { [unowned backend] point in
            guard var hit = hits.first(where: { $0.frame?.contains(point) == true }) else { return nil }
            if let typed, backend.session.calls.contains(where: { if case .perform(.composite) = $0 { return true } else { return false } }) { hit.value = typed }
            return hit
        }
        return backend
    }

    static func send(_ arguments: [String], through backend: FakeDeviceBackend, device: DeviceID = simulator, refusingSecureArgument: Bool = false) async throws {
        let fixture = try TreeCacheFixture()
        try await fixture.run {
            try await Type.parse(arguments + ["--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger(), refusingSecureArgument: refusingSecureArgument)
        }
    }

    @Test("a focused field the tree leaves out, with no keyboard showing, still takes the text")
    func focusedFieldOutsideTheTree() async throws {
        let backend = Self.sparse(hits: [Self.field("search", focused: true)], typed: "hi")
        try await Self.send(["hi"], through: backend)
        #expect(backend.session.calls == [.perform(.composite(try Type.iosEvents(for: "hi", replacing: false)))])
    }

    @Test("a narrow focused field off the screen's centre line the tree leaves out is found too")
    func narrowFieldOutsideTheTree() async throws {
        let narrow = FakeUI.node(.textField, id: "code", frame: FakeUI.frame(300, 500, 60, 30), state: UIState(focused: true))
        let backend = Self.sparse(hits: [narrow], typed: "hi")
        try await Self.send(["hi"], through: backend)
        #expect(backend.session.calls.count == 1)
    }

    @Test("a screen whose every point answers with no focused field is refused, as stray keys could reload a dev build")
    func sweepFindsNothing() async throws {
        let backend = Self.sparse(hits: [Self.field("search")])
        let error = await #expect(throws: CLIError.self) { try await Self.send(["r"], through: backend) }
        #expect(error?.reason == .noFocusedField)
        #expect(backend.session.calls.isEmpty)
        #expect(backend.hitTests > 0)
    }

    @Test("an app's own number pad, with focus on a button and only buttons at every point, is refused on a simulator")
    func keypadWithSweep() async throws {
        let price = FakeUI.node(.button, id: "price", label: "Price, 0.00", frame: FakeUI.frame(20, 200, 360, 48), state: UIState(focused: true))
        let key = FakeUI.node(.button, id: "key-5", label: "5", frame: FakeUI.frame(20, 500, 100, 52))
        let backend = Self.sparse(listed: [price, key], hits: [price, key])
        let error = await #expect(throws: CLIError.self) { try await Self.send(["58000"], through: backend) }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.userFacingDescription.contains("Price, 0.00") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("an argument aimed at a focused password field the tree leaves out is refused; --stdin text goes in")
    func hiddenPasswordField() async throws {
        let backend = Self.sparse(hits: [Self.field("pin", focused: true, secure: true)])
        let error = await #expect(throws: CLIError.self) { try await Self.send(["secret"], through: backend, refusingSecureArgument: true) }
        #expect(error?.reason == .secureFieldArgument)
        #expect(backend.session.calls.isEmpty)

        try await Self.send(["secret"], through: backend, refusingSecureArgument: false)
        #expect(backend.session.calls.count == 1)
    }

    @Test("--require-focus-id accepts a focused field the tree leaves out, and still refuses another")
    func requireFocusOutsideTheTree() async throws {
        let backend = Self.sparse(hits: [Self.field("search", focused: true)], typed: "hi")
        try await Self.send(["--require-focus-id", "search", "hi"], through: backend)
        #expect(backend.session.calls.count == 1)

        let other = Self.sparse(hits: [Self.field("search", focused: true)])
        let error = await #expect(throws: CLIError.self) { try await Self.send(["--require-focus-id", "email", "hi"], through: other) }
        #expect(error?.reason == .focusMismatch)
        #expect(other.session.calls.isEmpty)
    }

    @Test("a field focused late is still seen after a sweep that took the whole wait")
    func lateFocusAfterSlowSweep() async throws {
        var time: TimeInterval = 0
        let trees = [FakeUI.tree([Self.field("search")]), FakeUI.tree([Self.field("search", focused: true)])]
        var index = 0
        let hitTester = HitTestingFakeBackend(platform: .ios, trees: [])
        hitTester.hits = { _ in
            time += 2
            return nil
        }
        let check = try await Type.checkTextFocus(
            readTree: {
                defer { index += 1 }
                return trees[min(index, trees.count - 1)]
            },
            device: Self.simulator, clock: PollClock(now: { time }, sleep: { _ in }), warn: { _ in }, refusingSecureTarget: nil, hitTester: hitTester
        )
        #expect(check.tree == trees[1])
    }

    @Test("the sweep's rows meet a 30 pt field anywhere on the screen, on the centre line or to one side")
    func sweepCoversTheScreen() throws {
        let screen = FakeUI.frame(0, 0, 402, 874)
        let rounds = FocusSweep.rounds(in: screen)
        let centre = try #require(rounds.first)
        let sides = try #require(rounds.last)
        for y in stride(from: 0.0, through: 844, by: 7) {
            let wide = FakeUI.frame(16, y, 370, 30)
            let narrow = FakeUI.frame(300, y, 80, 30)
            #expect(centre.contains { wide.contains($0) }, "row at \(y)")
            #expect(sides.contains { narrow.contains($0) }, "row at \(y)")
        }
        #expect(FocusSweep.rounds(in: FakeUI.frame(0, 0, 0, 0)).isEmpty)
    }

    @Test("a point read's focused field counts only when it is a text field outside the keyboard")
    func sweepReadsOnlyTextFields() {
        #expect(FocusSweep.focusedField(in: Self.field("a", focused: true))?.id == "a")
        #expect(FocusSweep.focusedField(in: Self.field("a")) == nil)
        #expect(FocusSweep.focusedField(in: FakeUI.node(.button, id: "b", state: UIState(focused: true))) == nil)
        #expect(FocusSweep.focusedField(in: FakeUI.node(.keyboard, frame: FakeUI.frame(0, 574, 402, 300), children: [Self.field("emoji-search", focused: true)])) == nil)
        #expect(FocusSweep.focusedField(in: FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [Self.field("a", focused: true)]))?.id == "a")
    }

    /// A form whose field keeps focus beneath a full-screen page drawn in the same window.
    static func coveredForm(platform: DevicePlatform, keyboard: Bool = true) -> UITree {
        let drawn = { (order: Int) in platform == .android ? order : nil }
        let form = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: platform, drawingOrder: drawn(1), children: [
            FakeUI.node(.header, label: "Sign in", frame: FakeUI.frame(60, 60, 282, 20), platform: platform),
            Self.field("email", focused: true, platform: platform),
        ])
        let page = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: platform, drawingOrder: drawn(2), children: [
            FakeUI.node(.header, label: "Details", frame: FakeUI.frame(60, 60, 282, 20), platform: platform),
            FakeUI.node(.button, label: "Done", frame: FakeUI.frame(16, 790, 370, 49), platform: platform),
        ])
        let app = FakeUI.tree(platform: platform, [form, page]).roots[0]
        return UITree(platform: platform, device: "fake-device", roots: [app] + (keyboard ? [Self.keyboard(platform: platform)] : []))
    }

    @Test("a field focused beneath a page drawn over it takes no text, keyboard or not, on both platforms", arguments: [DevicePlatform.ios, .android])
    func coveredFieldRefuses(platform: DevicePlatform) throws {
        guard case .beneath(let node) = TextFocus.read(Self.coveredForm(platform: platform)) else {
            Issue.record("a covered field should read as beneath")
            return
        }
        #expect(node.id == "email")
        #expect(!TextFocus.read(Self.coveredForm(platform: platform, keyboard: false)).takesText)
    }

    @Test("plain type into a covered field names the field and the page, and sends nothing")
    func coveredFieldMessage() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [Self.coveredForm(platform: .ios)])
        let error = await #expect(throws: CLIError.self) { try await Self.send(["hi"], through: backend) }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.userFacingDescription.contains("email") == true)
        #expect(error?.userFacingDescription.contains("covers") == true)
        #expect(backend.session.calls.isEmpty)
    }

    static func unlistedTree() -> UITree {
        UITree(platform: .android, device: android.rawValue, roots: [
            FakeUI.tree(platform: .android, [FakeUI.node(.button, id: "price", label: "Price, 0.00", frame: FakeUI.frame(20, 200, 360, 48), platform: .android)]).roots[0],
            keyboard(platform: .android),
        ])
    }

    @Test("--unlisted-field types with the keyboard up for a field the screen does not list, and the refusal names it")
    func unlistedField() async throws {
        let refused = await #expect(throws: CLIError.self) { _ = try await Self.type(["1234"], trees: [Self.unlistedTree()], device: Self.android) }
        #expect(refused?.userFacingDescription.contains("--unlisted-field") == true)
        #expect(refused?.userFacingDescription.contains("<id>") == false)

        let backend = FakeDeviceBackend(platform: .android, trees: [Self.unlistedTree()])
        let check = try await Type.parse(["1234", "--unlisted-field", "--device", Self.android.rawValue]).ensureFocus(
            backend: backend, device: Self.android, logger: OffsiderLogger(), clock: ScriptedClock().poll, warn: { _ in }
        ) { _ in }
        #expect(check.secure == .unknown)
    }

    @Test("--unlisted-field does not reach past a focused button or an empty screen")
    func unlistedFieldOnlyWithKeyboard() async throws {
        for tree in [Self.keypad, FakeUI.tree(platform: .android, [Self.field("search", platform: .android)])] {
            let error = await #expect(throws: CLIError.self) {
                try await Type.parse(["1234", "--unlisted-field", "--device", Self.android.rawValue]).ensureFocus(
                    backend: FakeDeviceBackend(platform: .android, trees: [tree]), device: Self.android, logger: OffsiderLogger(), clock: ScriptedClock().poll, warn: { _ in }
                ) { _ in }
            }
            #expect(error?.reason == .noFocusedField)
        }
        #expect(throws: (any Error).self) { try Type.parse(["x", "--unlisted-field", "--into-id", "a", "--device", "emulator-5554"]) }
    }

    @Test("a batch type step takes --unlisted-field too")
    func unlistedFieldInBatch() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.unlistedTree()])
        let context = BatchContext(backend: backend, device: Self.android, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 200)
        let primitives = try await Type.parse(["1234", "--unlisted-field", "--device", "x"]).toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard case .run(let focus) = try #require(primitives.first) else {
            Issue.record("expected the focus check first")
            return
        }
        try await focus(backend.session)
    }

    static let iPhone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    @Test("a physical iPhone with no field focused refuses plain type, --stdin and text keys, sending nothing", arguments: [
        ["hi"], ["--stdin"], ["--replace", "new"],
    ])
    func iPhoneRefuses(arguments: [String]) async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [FakeUI.tree([Self.field("search")])])
        let error = await #expect(throws: CLIError.self) {
            try await Type.parse(arguments + ["--device", Self.iPhone.rawValue]).ensureFocus(
                backend: backend, device: Self.iPhone, logger: OffsiderLogger(), clock: ScriptedClock().poll, warn: { _ in }
            ) { _ in }
        }
        #expect(error?.reason == .noFocusedField)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a physical iPhone's key-sequence of text keys refuses with no field focused")
    func iPhoneKeySequenceRefuses() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [FakeUI.tree([Self.field("search")])])
        let error = await #expect(throws: CLIError.self) {
            try await KeySequence.parse(["--keycodes", "21", "--device", Self.iPhone.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.iPhone), logger: OffsiderLogger())
        }
        #expect(error?.reason == .noFocusedField)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a physical iPhone whose field has focus, or whose keyboard shows, passes; an unreadable screen warns and goes on")
    func iPhonePasses() async throws {
        for tree in [FakeUI.tree([Self.field("search", focused: true)]), FakeUI.tree([Self.field("search"), Self.keyboard()])] {
            let check = try await Type.checkTextFocus(
                readTree: { tree }, device: Self.iPhone, clock: ScriptedClock().poll, warn: { _ in }, refusingSecureTarget: nil
            )
            #expect(check.tree != nil)
        }
        var warnings: [String] = []
        let check = try await Type.checkTextFocus(
            readTree: { throw CLIError(errorDescription: "no screen", reason: .treeReadFailed) },
            device: Self.iPhone, clock: ScriptedClock().poll, warn: { warnings.append($0) }, refusingSecureTarget: nil
        )
        #expect(check.tree == nil)
        #expect(warnings.count == 1)
    }

    static let androidPhone = DeviceID(rawValue: "R58MFAKE01", platform: .android)

    @Test("a read refused for the app in front, a system prompt, a lock, a pulled cable or the allowance stops the text with that refusal and no warning: it is no unreadable screen")
    func refusedReadSendsNothing() async throws {
        let refusals: [(any Error, DeviceID)] = [
            (IOSDeviceError(.otherAppInFront, "com.example.app is not in front."), Self.iPhone),
            (IOSDeviceError(.appNotAllowed, "com.example.other is not among the apps allowed."), Self.iPhone),
            (IOSDeviceError(.appRequired, "No app was named."), Self.iPhone),
            (IOSDeviceError(.systemPromptOnTestDevice, "A system prompt is in front."), Self.iPhone),
            (IOSDeviceError(.locked, "The iPhone is locked."), Self.iPhone),
            (IOSDeviceError(.notWired, "The iPhone is not on USB."), Self.iPhone),
            (IOSDeviceError(.notAllowed, "The iPhone's allowance lapsed."), Self.iPhone),
            (AndroidError(.otherAppInFront, "Another app is in front."), Self.androidPhone),
            (AndroidError(.appNotAllowed, "No app was named."), Self.androidPhone),
            (AndroidError(.deviceLocked, "The phone is locked."), Self.androidPhone),
        ]
        for (refusal, device) in refusals {
            for keys in [false, true] {
                var warnings = 0
                let error = await #expect(throws: (any Error).self, "\(refusal)") {
                    try await Type.checkTextFocus(
                        readTree: { throw refusal }, device: device, clock: ScriptedClock().poll, warn: { _ in warnings += 1 }, refusingSecureTarget: nil, keys: keys
                    )
                }
                #expect((error as? any OffsiderFailure)?.failureMessage == (refusal as? any OffsiderFailure)?.failureMessage)
                #expect(warnings == 0, "\(refusal)")
            }
        }
    }

    @Test("every failure reason that says a device is unavailable is classed: a refusal that stops the text, or a device or runner not ready to be read")
    func readRefusalsClassEveryDeviceReason() {
        let notReady: Set<FailureReason> = [
            .deviceNotFound, .deviceNotBooted, .deviceNotReady, .deviceUnauthorised, .deviceAmbiguous, .avdNotFound, .deviceUntrusted,
            .developerModeOff, .devicePreparing, .uiAutomationOff, .certificateNotTrusted, .metroPortNotAllowed,
        ]
        for reason in FailureReason.allCases where reason.exitCode == .deviceUnavailable {
            #expect(Type.readRefusals.contains(reason) != notReady.contains(reason), "\(reason.rawValue) must be in one list")
        }
    }

    @Test("type on an iPhone whose named app is not in front opens no input session, where its keys would go to whatever has focus")
    func iPhoneOtherAppInFrontTypesNothing() async throws {
        final class OtherAppInFront: FakeDeviceBackend {
            override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
                throw IOSDeviceError(.otherAppInFront, "com.example.app is not in front on \(id.rawValue), so Offsider read nothing.")
            }
        }
        let backend = OtherAppInFront(platform: .ios, trees: [])

        let error = await #expect(throws: IOSDeviceError.self) { try await Self.send(["hi"], through: backend, device: Self.iPhone) }

        #expect(error?.kind == .otherAppInFront)
        #expect(backend.openedSessions.isEmpty)
    }

    @Test("key-sequence that spells text into a password field is refused, a shortcut or Return is not", arguments: [simulator, android])
    func keySequenceSecure(device: DeviceID) async throws {
        let tree = FakeUI.tree(platform: device.platform, [Self.field("password", focused: true, secure: true, platform: device.platform)])
        let backend = FakeDeviceBackend(platform: device.platform, trees: [tree])
        let route = DeviceRouter.Route(backend: backend, device: device)
        let error = await #expect(throws: CLIError.self) {
            try await KeySequence.parse(["--keycodes", "19,4,22", "--device", device.rawValue]).perform(on: route, logger: OffsiderLogger())
        }
        #expect(error?.reason == .secureFieldArgument)
        #expect(error?.userFacingDescription.contains("pressed no keys") == true)
        #expect(backend.session.calls.isEmpty)

        try await KeySequence.parse(["--keycodes", "224,4,225", "--device", device.rawValue]).perform(on: route, logger: OffsiderLogger())
        try await KeySequence.parse(["--keycodes", "40", "--device", device.rawValue]).perform(on: route, logger: OffsiderLogger())
        #expect(backend.session.calls.count == 2)
    }

    @Test("a batch key-sequence step that spells text into a password field fails and sends nothing")
    func batchKeySequenceSecure() async throws {
        let backend = FakeDeviceBackend(platform: .ios, trees: [FakeUI.tree([Self.field("password", focused: true, secure: true)])])
        let context = BatchContext(backend: backend, device: Self.simulator, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 200)
        var out = ""
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { _ in })
        await #expect(throws: ReportedFailure.self) {
            _ = try await Batch.runSteps(["key-sequence --keycodes 19,4,22"], context: context, session: backend.session, continueOnError: true, output: output, logger: OffsiderLogger())
        }
        #expect(out.contains("secure_field_argument"))
        #expect(!out.contains("19,4,22"))
        #expect(out.contains("<3 keys>"))
        #expect(backend.session.calls.isEmpty)
    }

    @Test("key-sequence with letters or digits needs a focused field; Return alone does not")
    func keySequence() async throws {
        #expect(KeySequence.typesText([34, 36, 39]))
        #expect(KeySequence.typesText([224, 4, 225]))
        #expect(KeySequence.typesText([89, 90, 91]))
        #expect(!KeySequence.typesText([40, 41, 42, 43, 79, 80, 81, 82, 88]))

        let tree = FakeUI.tree(platform: .android, [Self.field("search", platform: .android)])
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        let route = DeviceRouter.Route(backend: backend, device: Self.android)
        let error = await #expect(throws: CLIError.self) {
            try await KeySequence.parse(["--keycodes", "34,36", "--device", Self.android.rawValue]).perform(on: route, logger: OffsiderLogger())
        }
        #expect(error?.reason == .noFocusedField)
        #expect(error?.userFacingDescription.contains("pressed no keys") == true)
        #expect(backend.session.calls.isEmpty)

        try await KeySequence.parse(["--keycodes", "40", "--device", Self.android.rawValue]).perform(on: route, logger: OffsiderLogger())
        #expect(backend.session.calls.count == 1)
    }
}
