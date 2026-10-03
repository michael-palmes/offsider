import Foundation
import OffsiderCore
import Testing

@Suite("Known overlays")
struct KnownOverlaysTests {
    @Test("LogBox banner labels match for one log and for several", arguments: [
        "!, OffsiderFixture error 1",
        "2, OffsiderFixture error 4",
        "  12, Request failed \n",
    ])
    func logBoxLabelsMatch(label: String) {
        #expect(KnownOverlays.isLogBoxBanner(label))
    }

    @Test("other labels, including ones with a number prefix, do not match", arguments: [
        "3 unread",
        "3 unread, 2 new",
        "!,",
        "!, ",
        "1,000 items",
        "Error, try again",
        ", message",
        "",
    ])
    func otherLabelsDoNotMatch(label: String) {
        #expect(!KnownOverlays.isLogBoxBanner(label))
    }

    @Test("a missing label does not match")
    func missingLabel() {
        #expect(!KnownOverlays.isLogBoxBanner(nil))
    }

    @Test("the touch area runs from the banner's top edge to the viewport's bottom across its full width")
    func touchArea() {
        let viewport = UIFrame(x: 0, y: 0, width: 412, height: 915)
        let area = KnownOverlays.logBoxTouchArea(of: UIFrame(x: 8, y: 810, width: 396, height: 64), in: viewport)

        #expect(area == UIFrame(x: 0, y: 810, width: 412, height: 105))
    }
}
