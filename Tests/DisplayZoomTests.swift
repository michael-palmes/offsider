import OffsiderCore
import Testing

@Suite("Display Zoom")
struct DisplayZoomTests {
    private static func app(_ width: Double, _ height: Double, x: Double = 0, y: Double = 0, children: [UINode] = []) -> UINode {
        FakeUI.node(.application, label: "App", frame: FakeUI.frame(x, y, width, height), children: children)
    }

    @Test("a 320 x 693 layout on a 390 x 844 screen puts every frame, nested ones too, in screen points, and the app fills the screen")
    func smallLayoutScalesToScreen() throws {
        let field = FakeUI.node(.textField, id: "name-field", frame: FakeUI.frame(24, 200, 272, 40))
        let roots = [Self.app(320, 693.33, children: [field])]

        let zoom = try #require(DisplayZoom(in: roots, screenWidth: 390, screenHeight: 844))
        let scaled = zoom.screenRoots(roots)

        #expect(scaled[0].frame == FakeUI.frame(0, 0, 390, 844))
        #expect(scaled[0].children[0].frame == FakeUI.frame(29.25, 243.46, 331.5, 48.69))
    }

    @Test("a turned phone's wide frame scales along the screen's long side")
    func landscapeScales() throws {
        let roots = [Self.app(693, 320)]

        let zoom = try #require(DisplayZoom(in: roots, screenWidth: 390, screenHeight: 844))

        #expect(zoom.screenRoots(roots)[0].frame == FakeUI.frame(0, 0, 844, 390))
    }

    @Test("a hit-test point goes to the layout space, and the node it answers with comes back where the tree has it")
    func hitTestRoundTrip() throws {
        let row = FakeUI.node(.button, id: "row", frame: FakeUI.frame(16, 399.67, 288, 52))
        let roots = [Self.app(320, 693.33, children: [row])]
        let zoom = try #require(DisplayZoom(in: roots, screenWidth: 390, screenHeight: 844))
        let screenCentre = try #require(zoom.screenRoots(roots)[0].children[0].frame?.center)

        let layout = zoom.layoutPoint(screenCentre)

        #expect(abs(layout.x - 160) < 0.01 && abs(layout.y - 425.67) < 0.01)
        #expect(zoom.screenRoots([row]) == [zoom.screenRoots(roots)[0].children[0]])
    }

    @Test(
        "no zoom when the app fills the screen, is a window, is another shape or is larger",
        arguments: [
            (390.0, 844.0, 0.0, 0.0),
            (844.0, 390.0, 0.0, 0.0),
            (389.5, 843.5, 0.0, 0.0),
            (320.0, 693.0, 20.0, 40.0),
            (195.0, 844.0, 0.0, 0.0),
            (320.0, 480.0, 0.0, 0.0),
            (375.0, 812.0, 0.0, 0.0),
            (440.0, 952.0, 0.0, 0.0),
            (0.0, 0.0, 0.0, 0.0),
        ]
    )
    func noZoom(width: Double, height: Double, x: Double, y: Double) {
        #expect(DisplayZoom(in: [Self.app(width, height, x: x, y: y)], screenWidth: 390, screenHeight: 844) == nil)
    }

    @Test("no zoom from a tree without an application root, such as SpringBoard's own group during a restart")
    func noApplicationRoot() {
        let group = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 320, 693))
        #expect(DisplayZoom(in: [group], screenWidth: 390, screenHeight: 844) == nil)
    }
}
