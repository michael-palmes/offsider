import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Tree diff and node identity")
struct TreeDiffTests {
    static func text(_ label: String, id: String? = nil, value: String? = nil, y: Double, focused: Bool? = nil) -> UINode {
        FakeUI.node(.text, id: id, label: label, value: value, frame: FakeUI.frame(16, y, 370, 44), state: UIState(focused: focused))
    }

    // MARK: Identity

    @Test("an id names a node across moves and value changes")
    func idIdentity() {
        let before = FakeUI.node(.text, id: "state", label: "All", value: "All", frame: FakeUI.frame(16, 120, 370, 44))
        let after = FakeUI.node(.text, id: "state", label: "Unread", value: "Unread", frame: FakeUI.frame(16, 300, 370, 44))
        #expect(NodeIdentity.baseKey(before) == "#state")
        #expect(NodeIdentity.baseKey(before) == NodeIdentity.baseKey(after))
    }

    @Test("a node without an id is named by role, label and origin on a 4 pt grid")
    func labelIdentity() {
        let node = FakeUI.node(.button, label: "Save", frame: FakeUI.frame(17.9, 101, 80, 44))
        let nudged = FakeUI.node(.button, label: "Save", frame: FakeUI.frame(16.5, 99, 80, 44))
        let moved = FakeUI.node(.button, label: "Save", frame: FakeUI.frame(16, 140, 80, 44))
        #expect(NodeIdentity.baseKey(node) == #"button "Save" @16,100"#)
        #expect(NodeIdentity.baseKey(nudged) == NodeIdentity.baseKey(node))
        #expect(NodeIdentity.baseKey(moved) != NodeIdentity.baseKey(node))
        #expect(NodeIdentity.baseKey(FakeUI.node(.group, frame: FakeUI.frame(0, 0, 10, 10))) == nil)
    }

    @Test("duplicate keys get ordinals in document order")
    func duplicates() {
        let row = FakeUI.node(.cell, id: "row")
        #expect(NodeIdentity.keys([row, row, FakeUI.node(.group), row]) == ["#row", "#row~2", nil, "#row~3"])
    }

    @Test("UUID-shaped ids are normalised")
    func uuids() {
        let node = FakeUI.node(.cell, id: "row-3F2A9C1E-7B44-4D0A-9A1B-0123456789AB")
        let other = FakeUI.node(.cell, id: "row-00000000-1111-2222-3333-444444444444")
        #expect(NodeIdentity.baseKey(node) == "#row-<uuid>")
        #expect(NodeIdentity.baseKey(node) == NodeIdentity.baseKey(other))
    }

    @Test("the nearest copy is the one whose centre is closest")
    func nearest() {
        let low = FakeUI.node(.button, id: "apply", frame: FakeUI.frame(20, 700, 350, 44))
        let high = FakeUI.node(.button, id: "apply", frame: FakeUI.frame(20, 300, 350, 44))
        #expect(NodeIdentity.nearest([low, high], to: UIPoint(x: 195, y: 360)) == high)
    }

    // MARK: Diff

    @Test("additions and changes come in the new order and removals in the old order")
    func ordering() {
        let old = FakeUI.tree([Self.text("A", y: 100), Self.text("State", id: "state", value: "All", y: 150), Self.text("B", y: 200), Self.text("C", y: 250)])
        let new = FakeUI.tree([Self.text("New", y: 50), Self.text("State", id: "state", value: "Unread", y: 150), Self.text("A", y: 100)])
        let diff = TreeDiff.diff(old: old, new: new)
        #expect(diff.entries.map(\.kind) == [.added, .changed, .removed, .removed])
        #expect(diff.entries.map(\.key) == [#"text "New" @16,52"#, "#state", #"text "B" @16,200"#, #"text "C" @16,252"#])
        #expect(diff.entries.first?.line.text == #"text "New" (16,50 370x44)"#)
    }

    @Test("focus alone is not a change")
    func focusIgnored() {
        let old = FakeUI.tree([Self.text("Name", id: "name", y: 100, focused: false)])
        let new = FakeUI.tree([Self.text("Name", id: "name", y: 100, focused: true)])
        #expect(TreeDiff.diff(old: old, new: new).isUnchanged)
        #expect(TreeDiff.hash(old) == TreeDiff.hash(new))
    }

    @Test("identical trees are unchanged and keep the same hash; a value change moves the hash")
    func identical() {
        let tree = FakeUI.tree([Self.text("State", id: "state", value: "All", y: 150)])
        let changed = FakeUI.tree([Self.text("State", id: "state", value: "Unread", y: 150)])
        #expect(TreeDiff.diff(old: tree, new: tree).isUnchanged)
        #expect(TreeDiff.hash(tree) == TreeDiff.hash(tree))
        #expect(TreeDiff.hash(tree).count == 16)
        #expect(TreeDiff.hash(tree) != TreeDiff.hash(changed))
    }

    @Test("a truncated read reports no removals and is never unchanged")
    func truncated() {
        let old = FakeUI.tree([Self.text("A", y: 100), Self.text("B", y: 200)])
        var new = FakeUI.tree([Self.text("A", y: 100)])
        new.sourceTruncated = true
        let diff = TreeDiff.diff(old: old, new: new)
        #expect(diff.entries.isEmpty)
        #expect(!diff.isUnchanged)
        var same = old
        same.sourceTruncated = true
        #expect(!TreeDiff.diff(old: old, new: same).isUnchanged)
    }

    @Test("60 changed lines, or more than half the lines, falls back to the full output")
    func fallback() {
        func rows(_ count: Int, value: String) -> UITree {
            FakeUI.tree((0..<count).map { Self.text("Row \($0)", id: "row-\($0)", value: value, y: Double($0) * 44) })
        }
        #expect(TreeDiff.diff(old: rows(200, value: "a"), new: rows(200, value: "b")).shouldFallBack)
        let fiftyNine = TreeDiff.diff(old: rows(200, value: "a"), new: FakeUI.tree((0..<200).map { Self.text("Row \($0)", id: "row-\($0)", value: $0 < 59 ? "b" : "a", y: Double($0) * 44) }))
        #expect(fiftyNine.entries.count == 59 && !fiftyNine.shouldFallBack)
        let sixty = TreeDiff.diff(old: rows(200, value: "a"), new: FakeUI.tree((0..<200).map { Self.text("Row \($0)", id: "row-\($0)", value: $0 < 60 ? "b" : "a", y: Double($0) * 44) }))
        #expect(sixty.shouldFallBack)
        let small = TreeDiff.diff(old: rows(4, value: "a"), new: FakeUI.tree((0..<4).map { Self.text("Row \($0)", id: "row-\($0)", value: $0 < 3 ? "b" : "a", y: Double($0) * 44) }))
        #expect(small.shouldFallBack)
        let half = TreeDiff.diff(old: rows(3, value: "a"), new: FakeUI.tree((0..<3).map { Self.text("Row \($0)", id: "row-\($0)", value: $0 < 1 ? "b" : "a", y: Double($0) * 44) }))
        #expect(!half.shouldFallBack)
    }

    // MARK: Goldens

    @Test("the toolbar picker golden pair changes the readout and the radio states, nothing else")
    func toolbarGolden() throws {
        let before = try TreeGoldens.tree(of: .init(platform: .ios, screen: "toolbar-picker-test"))
        let after = try TreeGoldens.tree(of: .init(platform: .ios, screen: "toolbar-picker-test@unread"))
        let diff = TreeDiff.diff(old: before, new: after, filter: UITreeRenderOptions.summary.filter)
        let changed = diff.entries.filter { $0.kind == .changed }
        #expect(!diff.entries.isEmpty && !diff.shouldFallBack)
        #expect(changed.contains { $0.key == "#toolbar-picker-test-state" })
        #expect(diff.entries.allSatisfy { $0.line.node.role == .radioButton || $0.key == "#toolbar-picker-test-state" })
    }

    @Test("the parked sheet golden pair moves the sheet's controls into view")
    func parkedSheetGolden() throws {
        let parked = try TreeGoldens.tree(of: .init(platform: .ios, screen: "parked-sheet-test"))
        let open = try TreeGoldens.tree(of: .init(platform: .ios, screen: "parked-sheet-test@open"))
        let diff = TreeDiff.diff(old: parked, new: open)
        #expect(diff.entries.contains { $0.kind == .changed && $0.key.hasPrefix("#parked-sheet-test") && $0.previous?.node.frame != $0.line.node.frame })
    }

    @Test("diffing the largest golden stays well under 20 ms")
    func largestGoldenIsFast() throws {
        let trees = try TreeGoldens.all().map(TreeGoldens.tree(of:))
        let largest = try #require(trees.max { $0.roots.flatMap { $0.flattened() }.count < $1.roots.flatMap { $0.flattened() }.count })
        var moved = largest
        moved.roots = moved.roots.map { root in var root = root; root.label = "changed"; return root }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TreeDiff.diff(old: largest, new: moved) }
        #expect(elapsed < .milliseconds(20))
    }

    // MARK: Rendering

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func base(_ tree: UITree, command: String = "tap", age: TimeInterval = 0.84) -> TreeCacheRecord {
        TreeCacheRecord(
            platform: tree.platform, device: tree.device, command: command, writtenAt: now - age,
            treeRole: .preAction, appFrame: tree.applicationFrame, hash: TreeDiff.hash(tree), roots: tree.roots
        )
    }

    @Test("--diff lists added, changed and removed lines with the command and age")
    func rendersChanges() {
        let steady = (0..<4).map { Self.text("Row \($0)", id: "row-\($0)", y: 500 + Double($0) * 44) }
        let old = FakeUI.tree([Self.text("State", id: "state", value: "All", y: 150), Self.text("Gone", y: 300)] + steady)
        let new = FakeUI.tree([Self.text("State", id: "state", value: "Unread", y: 150), Self.text("Fresh", y: 400)] + steady)
        let output = TreeDiffRenderer.render(new, base: Self.base(old), options: .summary, now: Self.now)
        #expect(output == """
        # ios fake-device
        # changes since tap 840 ms ago: 1 added, 1 changed, 1 removed
        changed text "State" id=state value="Unread" (16,150 370x44) (was: text "State" id=state value="All" (16,150 370x44))
        added text "Fresh" (16,400 370x44)
        removed text "Gone" (16,300 370x44)

        """)
    }

    @Test("--diff prints unchanged with the command, age and hash")
    func rendersUnchanged() {
        let tree = FakeUI.tree([Self.text("State", id: "state", value: "All", y: 150)])
        let output = TreeDiffRenderer.render(tree, base: Self.base(tree, command: "describe-ui", age: 4.21), options: .summary, now: Self.now)
        #expect(output == "# ios fake-device\n# unchanged since describe-ui 4210 ms ago (\(TreeDiff.hash(tree)))\n")
    }

    @Test("--diff with no earlier tree, or with most lines changed, prints the full output and says so")
    func rendersFull() {
        let tree = FakeUI.tree([Self.text("State", id: "state", value: "All", y: 150)])
        let full = String(decoding: UITreeRenderer.render(tree, .summary), as: UTF8.self).split(separator: "\n", maxSplits: 1)[1]
        #expect(TreeDiffRenderer.render(tree, base: nil, options: .summary, now: Self.now)
            == "# ios fake-device\n# no earlier tree for this device; full output follows\n\(full)")
        let other = FakeUI.tree([Self.text("Other", id: "other", y: 150)])
        #expect(TreeDiffRenderer.render(tree, base: Self.base(other), options: .summary, now: Self.now)
            .hasPrefix("# ios fake-device\n# 2 lines changed since tap 840 ms ago; full output follows\napplication"))
    }
}
