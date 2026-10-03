import Foundation
import OffsiderCore
import Testing

@Suite("UITree viewport")
struct UITreeViewportTests {
    private static func root(_ role: UIRole, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> UINode {
        UINode(role: role, frame: UIFrame(x: x, y: y, width: width, height: height), native: .android(AndroidNativeAttributes()))
    }

    @Test("the viewport is the union of the application and keyboard roots")
    func unionOfApplicationAndKeyboard() {
        let roots = [Self.root(.application, 0, 0, 400, 700), Self.root(.keyboard, 0, 600, 400, 300)]
        #expect(UITree.viewport(in: roots) == UIFrame(x: 0, y: 0, width: 400, height: 900))
    }

    @Test("roots of other roles and zero-size roots are ignored")
    func otherAndEmptyRootsIgnored() {
        let roots = [
            Self.root(.group, 0, 0, 2000, 2000),
            Self.root(.keyboard, 0, 0, 0, 0),
            Self.root(.application, 10, 20, 300, 400),
        ]
        #expect(UITree.viewport(in: roots) == UIFrame(x: 10, y: 20, width: 300, height: 400))
    }

    @Test("a tree with no application or keyboard root has no viewport")
    func noViewportWithoutRoots() {
        #expect(UITree.viewport(in: [Self.root(.button, 0, 0, 100, 40)]) == nil)
        #expect(UITree(platform: .ios, device: "d", roots: []).viewport == nil)
    }

    @Test("a frame is visible only when it overlaps the viewport by at least 1 pt on both axes")
    func visibilityNeedsOnePointOfOverlap() {
        let viewport = UIFrame(x: 0, y: 0, width: 393, height: 852)
        #expect(UIFrame(x: 20, y: 851, width: 100, height: 40).isVisible(in: viewport))
        #expect(!UIFrame(x: 20, y: 851.5, width: 100, height: 40).isVisible(in: viewport))
        #expect(!UIFrame(x: 393, y: 100, width: 100, height: 40).isVisible(in: viewport))
        #expect(!UIFrame(x: 20, y: 10700, width: 350, height: 44).isVisible(in: viewport))
    }

    @Test("contains is half-open: the far edges are outside")
    func containsIsHalfOpen() {
        let frame = UIFrame(x: 0, y: 0, width: 100, height: 50)
        #expect(frame.contains(UIPoint(x: 0, y: 0)))
        #expect(frame.contains(UIPoint(x: 99.9, y: 49.9)))
        #expect(!frame.contains(UIPoint(x: 100, y: 10)))
        #expect(!frame.contains(UIPoint(x: 10, y: 50)))
    }

    @Test("summaries drop whole fractions and round others to 1 decimal")
    func summaries() {
        #expect(UIFrame(x: 20, y: 10700, width: 350, height: 44).summary == "(20, 10700) 350x44")
        #expect(UIFrame(x: 20.26, y: 0, width: 350.5, height: 44).summary == "(20.3, 0) 350.5x44")
        #expect(UIFrame(x: 0, y: 0, width: 393, height: 852).sizeSummary == "393x852")
        #expect(UIFrame(x: 10, y: 20, width: 100, height: 40).center == UIPoint(x: 60, y: 40))
    }
}
