import Foundation
import OffsiderCore
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

    static func type(_ arguments: [String], trees: [UITree], device: DeviceID) async throws -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: device.platform, trees: trees)
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
            let backend = try await Self.type(["hi"], trees: [tree], device: Self.simulator)
            #expect(backend.session.calls == [.perform(.composite(try Type.iosEvents(for: "hi", replacing: false)))])
        }
    }

    @Test("a field a tap focused a moment ago is waited for before refusing")
    func waitsForLateFocus() async throws {
        let backend = try await Self.type(["hi"], trees: [FakeUI.tree([Self.field("search")]), FakeUI.tree([Self.field("search", focused: true)])], device: Self.simulator)
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

    @Test("key-sequence with letters or digits needs a focused field; Return alone does not")
    func keySequence() async throws {
        #expect(KeySequence.typesText([34, 36, 39]))
        #expect(KeySequence.typesText([224, 4, 225]))
        #expect(!KeySequence.typesText([40, 41, 42, 43, 79, 80, 81, 82]))

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
