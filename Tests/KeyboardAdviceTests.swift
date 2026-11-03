import Foundation
@testable import OffsiderAndroid
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Android keyboard frame and advice")
@MainActor
struct KeyboardAdviceTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func golden(_ screen: String) throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: .android, screen: screen))
    }

    static func keyboard(in tree: UITree) throws -> UINode {
        try #require(tree.roots.first { $0.role == .keyboard })
    }

    @Test("a floating Gboard toolbar is framed by its buttons, not by its window over the whole screen")
    func floatingToolbarFrame() throws {
        let tree = try Self.golden("batch-login-flow")
        let toolbar = try Self.keyboard(in: tree)
        let frame = try #require(toolbar.frame)
        let viewport = try #require(tree.viewport)
        #expect(frame.width < 0.2 * viewport.width)
        let buttons = toolbar.flattened().filter { $0.role == .button }.compactMap(\.frame)
        #expect(!buttons.isEmpty)
        #expect(buttons.allSatisfy { frame.encloses($0, tolerance: 0.5) })
        let field = try #require(tree.roots[0].flattened().first { $0.id == "batch-login-email-field" }?.frame)
        #expect(!KeyboardDismiss.covers(field.center, in: tree))
    }

    /// A floating toolbar as the plain read gives it, and as a read of every view does: its invisible views spanning most of the screen.
    private func toolbar(everyView: Bool) -> UINode {
        let button = FakeUI.node(.button, label: "More keyboard options", frame: FakeUI.frame(12, 456, 48, 48), platform: .android)
        let keys = everyView ? [button, FakeUI.node(.group, frame: FakeUI.frame(0, 290, 411, 500), platform: .android)] : [button]
        return FakeUI.node(.keyboard, label: "Gboard", frame: everyView ? FakeUI.frame(0, 54, 411, 869) : FakeUI.frame(12, 456, 48, 48), platform: .android, children: keys)
    }

    @Test("filling the tree's gaps keeps the plain read's keyboard, framed by its keys, so a field beside the toolbar stays clear")
    func gapFillKeepsTheFittedKeyboard() throws {
        let field = FakeUI.node(.secureTextField, id: "password-field", label: "Password", frame: FakeUI.frame(16, 306, 379, 44), platform: .android, drawingOrder: 1)
        let hidden = FakeUI.node(.text, label: "Shown under a sheet", frame: FakeUI.frame(16, 600, 200, 30), platform: .android, drawingOrder: 2)
        let plain = UITree(platform: .android, device: "emulator-5554", roots: [
            FakeUI.node(.application, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, children: [field]), toolbar(everyView: false),
        ])
        let everyView = UITree(platform: .android, device: "emulator-5554", roots: [
            FakeUI.node(.application, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, children: [field, hidden]), toolbar(everyView: true),
        ])

        let filled = TreeGapFill.filling(plain, from: everyView)

        #expect(filled.filledFromGaps == 1)
        let keyboard = try Self.keyboard(in: filled)
        #expect(keyboard.frame == FakeUI.frame(12, 456, 48, 48))
        #expect(keyboard.children.map(\.label) == ["More keyboard options"])
        #expect(!KeyboardDismiss.covers(field.frame!.center, in: filled))
    }

    @Test("a screen-spanning Android keyboard window with no keys listed covers nothing, and shows no keys")
    func emptyWindowCoversNothing() {
        let keyboard = FakeUI.node(.keyboard, label: "Gboard", frame: FakeUI.frame(0, 54, 411, 869), platform: .android)
        let tree = UITree(platform: .android, device: "emulator-5554", roots: [FakeUI.node(.application, frame: FakeUI.frame(0, 0, 411, 923), platform: .android), keyboard])
        #expect(!KeyboardDismiss.covers(UIPoint(x: 200, y: 330), in: tree))
        #expect(!KeyboardDismiss.showsKeys(in: tree))
    }

    @Test("a docked keyboard keeps a frame around its keys at the bottom of the screen")
    func dockedFrame() throws {
        let tree = try Self.golden("text-input@keyboard")
        let frame = try #require(try Self.keyboard(in: tree).frame)
        let viewport = try #require(tree.viewport)
        #expect(frame.width > 0.9 * viewport.width)
        #expect(frame.y > viewport.height / 2)
    }

    @Test("Back is offered over docked keys, and never while only a toolbar shows, where it would go to the app")
    func backAdvice() throws {
        let docked = Tap.keyboardCoverError(selector: "id=field", at: (x: 200, y: 700), device: Self.device, tree: try Self.golden("text-input@keyboard"))
        #expect(docked.hint == "offsider button back --device emulator-5554")
        #expect(docked.userFacingDescription.contains("`offsider button back`"))

        let toolbar = Tap.keyboardCoverError(selector: "id=field", at: (x: 30, y: 400), device: Self.device, tree: try Self.golden("batch-login-flow"))
        #expect(toolbar.reason == .targetUnderKeyboard)
        #expect(toolbar.hint == "offsider describe-ui --summary --device emulator-5554")
        #expect(!toolbar.userFacingDescription.contains("`offsider button back`"))
        #expect(toolbar.userFacingDescription.contains("toolbar"))
    }
}
