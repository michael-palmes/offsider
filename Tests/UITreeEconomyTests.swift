import Foundation
import OffsiderCore
import Testing

@Suite("Text output economy")
struct UITreeEconomyTests {
    private static let screen = UIScreenInfo(width: 400, height: 800, scale: 3)

    private static func node(
        role: UIRole, id: String? = nil, label: String? = nil, value: String? = nil, frame: UIFrame? = nil, children: [UINode] = []
    ) -> UINode {
        UINode(role: role, id: id, label: label, value: value, frame: frame, native: .android(AndroidNativeAttributes()), children: children)
    }

    private static func frame(_ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 40) -> UIFrame {
        UIFrame(x: x, y: y, width: width, height: height)
    }

    private static func tree(_ children: [UINode], platform: DevicePlatform = .android) -> UITree {
        UITree(platform: platform, device: "d", screen: screen, roots: [
            Self.node(role: .application, label: "App", frame: frame(0, 0, 400, 800), children: children),
        ])
    }

    private static func rendered(_ tree: UITree, _ options: UITreeRenderOptions = .summary) -> String {
        String(decoding: UITreeRenderer.render(tree, options), as: UTF8.self)
    }

    private static func golden(_ platform: DevicePlatform, _ screen: String) throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: platform, screen: screen))
    }

    private static func row(_ index: Int, y: Double, x: Double = 0) -> UINode {
        Self.node(role: .button, id: "row-\(index)", label: "Row \(index)", frame: frame(x, y, 400, 50))
    }

    @Test("a child label the parent shows is folded, and a child with nothing else left is dropped")
    func childLabelFolded() throws {
        let output = Self.rendered(try Self.golden(.android, "rows-test"))

        #expect(output.contains(#"button "Inbox, 3 unread""#))
        #expect(!output.contains(#"text "Inbox""#))
        #expect(!output.contains(#"text "3 unread""#))
        #expect(output.hasSuffix("# folded 8 repeated labels\n"))
    }

    @Test("a folded child with an id, a value or a control role keeps its line without the label")
    func foldedChildKeepsLine() {
        let parent = Self.node(role: .group, label: "Mail, Unread", frame: Self.frame(0, 100, 400, 200), children: [
            Self.node(role: .text, id: "mail-title", label: "Mail", frame: Self.frame(0, 100)),
            Self.node(role: .text, label: "Unread", value: "3", frame: Self.frame(0, 140)),
            Self.node(role: .checkbox, label: "Mail", frame: Self.frame(0, 180)),
            Self.node(role: .text, label: "Unread", frame: Self.frame(0, 220)),
        ])
        let lines = Self.rendered(Self.tree([parent])).split(separator: "\n").map(String.init)

        #expect(lines.contains("    text id=mail-title (0,100 100x40)"))
        #expect(lines.contains(#"    text value="3" (0,140 100x40)"#))
        #expect(lines.contains("    checkbox (0,180 100x40)"))
        #expect(!lines.contains { $0.contains("(0,220") })
        #expect(lines.last == "# folded 4 repeated labels")
    }

    @Test("a text node's value equal to its label is dropped, a field's is kept")
    func valueEqualToLabel() {
        let output = Self.rendered(Self.tree([
            Self.node(role: .text, label: "Hello", value: "Hello", frame: Self.frame(0, 100)),
            Self.node(role: .textField, label: "Name", value: "Name", frame: Self.frame(0, 200)),
        ]))

        #expect(output.contains(#"  text "Hello" (0,100 100x40)"#))
        #expect(output.contains(#"  textField "Name" value="Name" (0,200 100x40)"#))
        #expect(output.hasSuffix("# folded 1 repeated label\n"))
    }

    @Test("a secure field's masked value stays on its own line when its label is folded")
    func secureValueStaysPut() {
        let form = Self.node(role: .group, label: "Password", frame: Self.frame(0, 100, 400, 100), children: [
            Self.node(role: .secureTextField, label: "Password", value: "•••••", frame: Self.frame(0, 120)),
        ])
        let lines = Self.rendered(Self.tree([form])).split(separator: "\n").map(String.init)

        #expect(lines.contains(#"  group "Password" (0,100 400x100)"#))
        #expect(lines.contains(#"    secureTextField value="•••••" (0,120 100x40)"#))
    }

    @Test("off-screen rows below the fold become one run line naming the first and last")
    func runBelowFold() throws {
        let output = Self.rendered(try Self.golden(.ios, "rows-test"))

        #expect(output.contains("    button \"Item 8\" id=rows-test-item-8 (0,864.7 402x56)\n    [off-screen below] 34 items: id=rows-test-item-9 to id=rows-test-end\n"))
        #expect(!output.contains("rows-test-item-20"))
    }

    @Test("a parked sheet below the screen is summarised, not listed")
    func parkedSheet() throws {
        let output = Self.rendered(try Self.golden(.ios, "parked-sheet-test"))

        #expect(output.contains("[off-screen below] 4 items: id=parked-sheet-test-sheet-title to id=parked-sheet-test-close"))
        #expect(!output.contains("parked-sheet-test-sheet-body"))
    }

    @Test("runs above, below, left and right are kept apart, and a row's own texts are not counted")
    func runsBySide() {
        var below = Self.row(4, y: 900)
        below.children = [Self.node(role: .text, label: "Inside", frame: Self.frame(0, 900))]
        let output = Self.rendered(Self.tree([
            Self.row(1, y: -100), Self.row(2, y: -50),
            Self.row(3, y: 100),
            below, Self.row(5, y: 950),
            Self.row(6, y: 300, x: 500),
            Self.row(7, y: 300, x: -500),
            Self.node(role: .text, label: "Empty", frame: Self.frame(0, 0, 0, 0)),
        ]))

        #expect(output.contains("  [off-screen above] 2 items: id=row-1 to id=row-2\n  button \"Row 3\""))
        #expect(output.contains("  [off-screen below] 2 items: id=row-4 to id=row-5\n"))
        #expect(output.contains("  [off-screen right] 1 item: id=row-6\n  [off-screen left] 1 item: id=row-7\n"))
        #expect(!output.contains("Empty"))
    }

    @Test("without --on-screen nothing is summarised")
    func noRunsWithoutOnScreen() throws {
        let output = Self.rendered(try Self.golden(.ios, "rows-test"), UITreeRenderOptions(format: .text))

        #expect(!output.contains("[off-screen"))
        #expect(output.contains("id=rows-test-end"))
    }

    @Test("the byte budget keeps whole lines and the output, marker included, fits the budget", arguments: [512, 1024, 4096])
    func budgetFits(maxBytes: Int) throws {
        for golden in TreeGoldens.all() {
            let tree = try TreeGoldens.tree(of: golden)
            var options = UITreeRenderOptions.summary
            options.maxBytes = nil
            let full = Self.rendered(tree, options)
            options.maxBytes = maxBytes
            let cut = UITreeRenderer.render(tree, options)
            let lines = String(decoding: cut, as: UTF8.self).split(separator: "\n").map(String.init)
            let fullLines = Set(full.split(separator: "\n").map(String.init))

            #expect(cut.count <= maxBytes || lines.count <= 3, "\(golden.name) is \(cut.count) bytes")
            #expect(lines.allSatisfy { fullLines.contains($0) || $0.hasPrefix("# truncated: ") }, "\(golden.name)")
            #expect((full.utf8.count > maxBytes) == lines.contains { $0.hasPrefix("# truncated: ") }, "\(golden.name)")
        }
    }

    @Test("the header and first node always go out")
    func headerAndFirstNode() {
        let long = String(repeating: "x", count: 900)
        var options = UITreeRenderOptions.summary
        options.maxBytes = 512
        let lines = Self.rendered(UITree(platform: .android, device: "d", screen: Self.screen, roots: [
            Self.node(role: .application, label: long, frame: Self.frame(0, 0, 400, 800), children: [Self.row(1, y: 100)]),
        ]), options).split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("# android d"))
        #expect(lines[1].contains(long))
        #expect(lines[2] == "# truncated: 1 more node past the 512-byte budget; pass --max-bytes 0 for all, or narrow with --actionable")
    }

    @Test("the cut count includes items inside cut run lines")
    func cutCountsRunItems() {
        let label = String(repeating: "y", count: 200)
        let visible = (0..<4).map { Self.node(role: .button, label: "\(label) \($0)", frame: Self.frame(0, 100 + Double($0) * 50)) }
        let hidden = (0..<30).map { Self.row($0, y: 900 + Double($0) * 50) }
        var options = UITreeRenderOptions.summary
        options.maxBytes = 512

        let output = Self.rendered(Self.tree(visible + hidden), options)

        #expect(output.hasSuffix("# truncated: 33 more nodes past the 512-byte budget; pass --max-bytes 0 for all, or narrow with --actionable\n"))
    }

    @Test("a device-truncated tree gets the device marker, distinct from the budget marker")
    func deviceMarker() {
        var tree = Self.tree([Self.row(1, y: 100)])
        tree.sourceTruncated = true

        let output = Self.rendered(tree)

        #expect(output.hasSuffix("\n# the device stopped listing nodes at its limit; this tree is incomplete\n"))
        #expect(!output.contains("# truncated"))
        #expect(!String(decoding: UITreeRenderer.render(tree, UITreeRenderOptions()), as: UTF8.self).contains("incomplete"))
    }

    @Test("nested indentation stops at 10 levels")
    func indentCap() {
        var node = Self.node(role: .button, label: "Deep", frame: Self.frame(0, 100))
        for level in 0..<14 {
            node = Self.node(role: .group, id: "level-\(level)", frame: Self.frame(0, 100), children: [node])
        }
        let output = Self.rendered(Self.tree([node]), UITreeRenderOptions(format: .text))

        #expect(output.contains("\n" + String(repeating: "  ", count: 10) + "button \"Deep\""))
        #expect(!output.contains(String(repeating: "  ", count: 11)))
    }
}
