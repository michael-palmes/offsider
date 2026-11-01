import OffsiderCore
import Testing
@testable import Offsider

@Suite("SpringBoard's frames on a turned screen")
struct PanelTurnTests {
    private static let panel = (width: 669.0, height: 951.0)

    private static func turn(_ orientation: OrientationCoordinateMath.Orientation) -> PanelTurn? {
        PanelTurn(orientation: orientation, panelWidth: panel.width, panelHeight: panel.height)
    }

    @Test("an alert's button on the Duo's inner panel lands where the screen shows it")
    func alertButtonOnTheInnerPanel() throws {
        let turn = try #require(Self.turn(.landscape))
        let button = turn.screenFrame(UIFrame(x: 324.7, y: 331.3, width: 48, height: 288))
        #expect(abs(button.x - 331.7) < 0.01)
        #expect(abs(button.y - 324.7) < 0.01)
        #expect(button.width == 288)
        #expect(button.height == 48)
    }

    @Test("a frame's centre and a screen point agree with the mapping input uses", arguments: [
        OrientationCoordinateMath.Orientation.landscape, .landscapeFlipped, .portraitUpsideDown,
    ])
    func framesAgreeWithInput(orientation: OrientationCoordinateMath.Orientation) throws {
        let turn = try #require(Self.turn(orientation))
        let panelFrame = UIFrame(x: 100, y: 200, width: 60, height: 300)
        let onScreen = turn.screenFrame(panelFrame)
        let centre = turn.panelPoint(UIPoint(x: onScreen.x + onScreen.width / 2, y: onScreen.y + onScreen.height / 2))
        #expect(centre.x == 130)
        #expect(centre.y == 350)
    }

    @Test("the UI upright on its panel needs no turn")
    func uprightNeedsNoTurn() {
        #expect(Self.turn(.portrait) == nil)
    }

    @Test("every element turns, and the application root is the whole screen whichever display its frame named")
    func turnsTheWholeTree() throws {
        let turn = try #require(Self.turn(.landscape))
        var root = FakeUI.node(.other, frame: FakeUI.frame(0, 0, 466, 678))
        root.role = .application
        var alert = FakeUI.node(.other, frame: FakeUI.frame(134, 315, 366, 320))
        alert.children = [FakeUI.node(.button, label: "Allow", frame: FakeUI.frame(324, 331, 48, 288))]
        root.children = [alert]

        let turned = turn.screenRoots([root])[0]

        #expect(turned.frame == UIFrame(x: 0, y: 0, width: 951, height: 669))
        #expect(turned.children[0].frame == UIFrame(x: 316, y: 134, width: 320, height: 366))
        #expect(turned.children[0].children[0].frame == UIFrame(x: 332, y: 324, width: 288, height: 48))
    }
}
