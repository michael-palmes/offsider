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

    @Test("the touch area runs from a point above the banner's top edge to the viewport's bottom across its full width")
    func touchArea() {
        let viewport = UIFrame(x: 0, y: 0, width: 412, height: 915)
        let area = KnownOverlays.logBoxTouchArea(of: UIFrame(x: 8, y: 810, width: 396, height: 64), in: viewport)

        #expect(area == UIFrame(x: 0, y: 809, width: 412, height: 106))
    }

    @Test("only a toast has a touch area; an ordinary banner has its frame alone")
    func touchAreaOfNode() {
        let viewport = UIFrame(x: 0, y: 0, width: 402, height: 874)
        #expect(KnownOverlays.logBoxTouchArea(of: LogBoxTrees.toast(1), in: viewport) == UIFrame(x: 0, y: 805, width: 402, height: 69))
        let banner = FakeUI.node(.other, label: "Connection lost", frame: FakeUI.frame(10, 806, 382, 48))
        #expect(KnownOverlays.logBoxTouchArea(of: banner, in: viewport) == nil)
    }
}

@Suite("LogBox windows")
struct LogBoxWindowTests {
    @Test("the inspector hides the app only in its own modal window, as on Android; on iOS it is drawn over the app's nodes")
    func inspectorHidesApp() {
        func hides(_ tree: UITree) -> Bool {
            LogBoxBlock.hiding(tree, inspector: KnownOverlays.logBoxInspector(in: tree.roots, viewport: tree.viewport), subject: "--id x") != nil
        }
        #expect(hides(LogBoxTrees.androidInspector()))
        #expect(!hides(FakeUI.tree(LogBoxTrees.inspector())))
        #expect(!hides(LogBoxTrees.androidTree(LogBoxTrees.inspector(platform: .android), title: "Playground")))
        #expect(!hides(LogBoxTrees.androidTree([], title: nil)))
    }

    @Test("an untitled modal from the app with nothing labelled, named or actionable is an empty dialog, in the summary and JSON")
    func emptyDialog() throws {
        let context = LogBoxTrees.androidEmptyDialog().context
        #expect(context.window?.empty == true)
        #expect(context.headerLines == ["# window: \(LogBoxTrees.package) (modal, empty)"])

        let json = String(decoding: LogBoxTrees.androidEmptyDialog().jsonData(), as: UTF8.self)
        #expect(json.contains(#""kind": "modal","#) && json.contains(#""empty": true"#))
        let decoded = try UITree(jsonData: Data(json.utf8))
        #expect(decoded.context.window?.empty == true)
    }

    @Test("a dialog with a label, an id or a control, a titled window, the inspector or a dialog short of the screen is not empty", arguments: [
        LogBoxTrees.androidTree([FakeUI.node(.text, label: "Loading", frame: FakeUI.frame(100, 400, 200, 20), platform: .android)], title: nil),
        LogBoxTrees.androidTree([FakeUI.node(.group, id: "sheet", frame: FakeUI.frame(0, 0, 402, 874), platform: .android)], title: nil),
        LogBoxTrees.androidTree([FakeUI.node(.button, frame: FakeUI.frame(100, 400, 200, 44), platform: .android)], title: nil),
        LogBoxTrees.androidTree([], title: "Settings"),
        LogBoxTrees.androidInspector(),
    ])
    func notEmpty(tree: UITree) {
        #expect(tree.context.window?.empty == false)
    }

    @Test("a small dialog that does not span the screen is not empty")
    func smallDialog() {
        var tree = LogBoxTrees.androidTree([], title: nil)
        tree.roots[0].frame = FakeUI.frame(40, 300, 320, 200)
        #expect(tree.context.window?.kind == .modal)
        #expect(tree.context.window?.empty == false)
    }
}

@Suite("LogBox toasts and inspector")
struct LogBoxDetectionTests {
    static let viewport = UIFrame(x: 0, y: 0, width: 402, height: 874)

    static func tree(_ children: [UINode]) -> UITree {
        FakeUI.tree(children)
    }

    @Test("a 48-high toast 10 points in at the bottom is a LogBox toast, with its count and clear button")
    func bottomToast() throws {
        let toast = FakeUI.node(.other, label: "!, A props object containing a \"key\" prop", frame: FakeUI.frame(10, 806, 382, 48))
        let found = KnownOverlays.logBoxToasts(in: Self.tree([toast]).roots, viewport: Self.viewport)

        #expect(found == [LogBoxToast(count: 1, frame: FakeUI.frame(10, 806, 382, 48), message: "A props object containing a \"key\" prop", index: 1)])
        #expect(found.first?.dismissPoint == UIPoint(x: 370, y: 830))
    }

    @Test("a count label mid-screen and a full-width call to action with 16-point margins are not toasts")
    func lookAlikes() {
        let amount = FakeUI.node(.button, id: "overlay-test-amount", label: "10, pcs", frame: FakeUI.frame(16, 400, 370, 56))
        let cta = FakeUI.node(.button, label: "3, Continue", frame: FakeUI.frame(16, 790, 370, 56))
        #expect(KnownOverlays.logBoxToasts(in: Self.tree([amount, cta]).roots, viewport: Self.viewport).isEmpty)
        #expect(KnownOverlays.logBox(in: Self.tree([amount, cta])) == nil)
    }

    @Test("stacked warning and error toasts sum their logs, bottom first")
    func stackedToasts() {
        let warnings = FakeUI.node(.other, label: "3, Possible unhandled promise", frame: FakeUI.frame(10, 754, 382, 48))
        let errors = FakeUI.node(.other, label: "2, Request failed", frame: FakeUI.frame(10, 806, 382, 48))
        let tree = Self.tree([warnings, errors])

        #expect(KnownOverlays.logBoxToasts(in: tree.roots, viewport: Self.viewport).map(\.count) == [2, 3])
        #expect(KnownOverlays.logBoxToasts(in: tree.roots, viewport: Self.viewport).map(\.index) == [1, 2])
        #expect(KnownOverlays.logBox(in: tree) == UITreeContext.LogBox(logs: 5, inspector: false))
    }

    @Test("a toast's message drops its count and joins its lines, as the banner shows it")
    func messages() {
        #expect(KnownOverlays.logBoxMessage("!, Request failed") == "Request failed")
        #expect(KnownOverlays.logBoxMessage("12, Warning: Each child\n  in a list   should have a key") == "Warning: Each child in a list should have a key")
        #expect(KnownOverlays.logBoxMessage("3 unread, 2 new") == nil)
    }

    @Test("a toast under the largest Display Zoom, in screen points, is still a toast, and a full-width button there is not")
    func toastUnderDisplayZoom() {
        let viewport = FakeUI.frame(0, 0, 393, 852)
        let toast = FakeUI.node(.other, label: "2, OffsiderFixture error", frame: FakeUI.frame(12.28, 790, 368.44, 59))
        let button = FakeUI.node(.button, label: "10, pcs", frame: FakeUI.frame(19.65, 790, 353.7, 59))

        #expect(KnownOverlays.logBoxToast(toast, viewport: viewport)?.count == 2)
        #expect(KnownOverlays.logBoxToast(button, viewport: viewport) == nil)
    }

    @Test("a selector's text is found in a toast whatever its spacing and case, and short or absent text is not")
    func containing() {
        let warning = FakeUI.node(.other, label: "!, OffsiderFixture\nwarn from live ticker", frame: FakeUI.frame(10, 754, 382, 48))
        let error = FakeUI.node(.other, label: "!, OffsiderFixture error from live ticker", frame: FakeUI.frame(10, 806, 382, 48))
        let roots = Self.tree([warning, error]).roots

        #expect(KnownOverlays.logBoxToast(containing: "offsiderfixture warn", in: roots, viewport: Self.viewport)?.index == 2)
        #expect(KnownOverlays.logBoxToast(containing: "OffsiderFixture error", in: roots, viewport: Self.viewport)?.index == 1)
        #expect(KnownOverlays.logBoxToast(containing: "Buy", in: roots, viewport: Self.viewport) == nil)
        #expect(KnownOverlays.logBoxToast(containing: "er", in: roots, viewport: Self.viewport) == nil)
    }

    @Test("the inspector is its Log n of m header, or Dismiss and Minimize at the bottom")
    func inspector() {
        let header = FakeUI.node(.text, label: "Log 1 of 2", frame: FakeUI.frame(150, 60, 100, 20))
        let dismiss = FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 820, 200, 54))
        let minimize = FakeUI.node(.button, label: "Minimize", frame: FakeUI.frame(202, 820, 200, 54))

        let open = KnownOverlays.logBoxInspector(in: Self.tree([header, dismiss, minimize]).roots, viewport: Self.viewport)
        #expect(open?.log == 1 && open?.of == 2 && open?.dismiss == dismiss.frame)
        #expect(KnownOverlays.logBox(in: Self.tree([header, dismiss, minimize])) == UITreeContext.LogBox(logs: 2, inspector: true))
        #expect(KnownOverlays.logBoxInspector(in: Self.tree([dismiss, minimize]).roots, viewport: Self.viewport) != nil)
        let topDismiss = FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 100, 200, 54))
        #expect(KnownOverlays.logBoxInspector(in: Self.tree([topDismiss, minimize]).roots, viewport: Self.viewport) == nil)
    }
}
