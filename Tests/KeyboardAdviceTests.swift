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
